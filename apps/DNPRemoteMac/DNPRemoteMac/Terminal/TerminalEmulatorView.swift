import SwiftUI
import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// SwiftUI representable that hosts the same `LocalProcessTerminalView` instance across pane swaps.
/// The `TerminalSession` outlives the SwiftUI view so the running shell isn't killed when the user
/// switches to Settings/Pairing/etc.
struct TerminalEmulatorView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.embed(terminal: session.terminalView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? TerminalContainerView else { return }
        // If the session was rebuilt (e.g., recreated), re-embed.
        if container.embedded !== session.terminalView {
            container.embed(terminal: session.terminalView)
            return
        }
        // Same terminal, but SwiftUI just told us to update — that usually
        // means the parent's frame just changed (sidebar collapse/expand,
        // window resize, tab switch into this pane). Re-apply the frame and
        // force a redisplay so SwiftTerm's NSView can't stay one runloop
        // tick behind its cell grid (which is what produces the blank /
        // garbled terminal until the user nudges the mouse).
        container.refreshEmbeddedDisplay()
    }
}

/// NSView that hosts the SwiftTerm view and **coalesces resize ioctls**.
///
/// Why this exists: every time `LocalProcessTerminalView.frame` changes, SwiftTerm recomputes
/// its character grid (cols × rows from font metrics) and issues `TIOCSWINSZ` (SIGWINCH) on the
/// PTY. The Claude TUI receives SIGWINCH, redraws the splash from screen-top, and the result
/// gets appended to scrollback. During a sidebar drag (or window resize) we used to fire 30+
/// SIGWINCH/sec — Claude printed its splash 30+ times and the user saw a stack of redraw
/// artifacts (the screenshot bug).
///
/// The fix: take ownership of the embedded terminal's frame instead of pinning via Auto Layout.
/// During `inLiveResize` (user-driven drag, window resize) skip syncing the terminal frame; on
/// `viewDidEndLiveResize` apply the final size in a single shot. SIGWINCH fires **once** per
/// drag, Claude redraws **once**, no stacked splashes. Non-drag size changes (chevron snap,
/// programmatic layout) still apply immediately so the terminal stays visually in sync.
final class TerminalContainerView: NSView {
    private(set) weak var embedded: LocalProcessTerminalView?

    /// Visual hint shown while a drag is hovering over the pane. Drawn as a
    /// rounded accent-coloured border via the layer; cleared the moment the
    /// drag exits or completes.
    private var dropHighlight: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Match the app's window tone (Settings / Diagnostics use the same color).
        // `underPageBackgroundColor` is the system's grouped-content tone — keeps the
        // terminal pane visually unified with the rest of the IDE chrome rather than
        // dropping into a hardcoded near-black slab.
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        // We manage the embedded terminal's frame manually — see `applyTerminalFrameIfStable`.
        // AppKit's default autoresize pass would fight us by re-applying the bounds on every
        // resize tick.
        autoresizesSubviews = false
        // Accept image and file drops so the user can drag a screenshot /
        // image file onto the terminal and have its path injected into the
        // running Claude prompt. Claude Code's TUI recognises image paths in
        // its input and attaches them as image content for the next turn.
        registerForDraggedTypes([
            .fileURL,           // Finder files, Preview windows, screenshots-on-desktop
            .png, .tiff,        // raw image data (e.g. dragged from web pages, Notes)
            .URL                // remote URLs — we ignore these but registering makes the
                                // green "+" cursor disappear instead of looking broken
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Intercept Cmd-modified key combos that need to translate into
    /// readline / line-editor escape sequences for Claude's TUI. SwiftTerm
    /// alone doesn't translate `Cmd+Delete` into the readline `Ctrl+U`
    /// (kill-to-start-of-line) sequence, which is what users expect from a
    /// Mac-native delete-line gesture — so we catch it here BEFORE it
    /// reaches the inner terminal view and emit the right control bytes.
    /// Bindings come from `ShortcutsService` so the user can rebind these
    /// via Settings → Keyboard shortcuts; defaults are the conventional
    /// Mac text-editing combos.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let term = embedded else {
            return super.performKeyEquivalent(with: event)
        }
        // Reading from the @MainActor service is safe — `performKeyEquivalent`
        // runs on the main thread.
        let svc = ShortcutsService.shared
        if svc.combo(for: .deleteLineStart).matches(event: event) {
            // Ctrl+U / NAK — readline "unix-line-discard" (delete from cursor
            // to start of line). Same bytes bash, zsh, and Claude's TUI all
            // honour for the kill-to-start gesture.
            term.send(txt: "\u{15}")
            return true
        }
        if svc.combo(for: .deleteLineEnd).matches(event: event) {
            // Ctrl+K / VT — readline "kill-line" (delete from cursor to end).
            term.send(txt: "\u{0B}")
            return true
        }
        if svc.combo(for: .moveLineStart).matches(event: event) {
            // Ctrl+A / SOH — beginning-of-line.
            term.send(txt: "\u{01}")
            return true
        }
        if svc.combo(for: .moveLineEnd).matches(event: event) {
            // Ctrl+E / ENQ — end-of-line.
            term.send(txt: "\u{05}")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func embed(terminal: LocalProcessTerminalView) {
        // Remove previous if any.
        if let prev = embedded, prev.superview === self { prev.removeFromSuperview() }
        // Manual frame — NOT constraints. Constraints would re-pin SwiftTerm on every
        // container size change, which is exactly what we're trying to coalesce.
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        terminal.frame = bounds
        addSubview(terminal)
        embedded = terminal
        // SwiftTerm's `TerminalView` registers for `.string` / `.fileURL` drag
        // types and pastes the dropped content as raw text into the PTY. That
        // collides with our image-attachment flow: a Finder file-URL drop
        // would slip past our container's handler (the deeper view sees the
        // drag first per AppKit's hit-test order) and SwiftTerm would inject
        // the path WITHOUT shell-escaping, breaking on spaces or Hebrew chars.
        // Unregister the inner view's drag types so every drop bubbles up to
        // our `performDragOperation(_:)`, where we filter for image types and
        // shell-escape the path correctly.
        terminal.unregisterDraggedTypes()
        // Mark the just-attached view for redisplay so its visible cells
        // are painted on the very next AppKit drawing pass instead of
        // waiting for a mouse-move or scroll event to invalidate them.
        // SwiftTerm sometimes leaves the NSView display stale right after
        // an attach — that's the "blank terminal until I nudge it" symptom.
        terminal.needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(terminal)
            // Force the embedded terminal to re-emit SIGWINCH so the
            // Claude TUI repaints from a known grid size — the very
            // problem the user reported (blank terminal after session
            // switch / sidebar resize until they nudged the splitter).
            // Just re-assigning `term.frame = bounds` is a no-op when the
            // bounds didn't change (and `bounds` here usually equals
            // whatever it was when the previous session was attached), so
            // no SIGWINCH is sent and Claude never redraws. The kick
            // shrinks the frame by 1pt then restores it — that ALWAYS
            // changes the grid, ALWAYS triggers SIGWINCH, and the Claude
            // TUI replies with a full redraw within a few ms.
            self.kickResizeEmbeddedTerminal(passes: .attach)
        }
    }

    /// Re-apply the embedded terminal's frame to the container's current
    /// bounds (only when they differ) and mark the view for redisplay.
    /// Called from `updateNSView` and `viewDidEndLiveResize` so SwiftTerm's
    /// visible cells are always in sync with the container's real size —
    /// no more "blank until you nudge it" lag after layout changes (session
    /// switch, sidebar collapse/expand, window resize).
    ///
    /// Critical: this used to call `kickResizeEmbeddedTerminal()` on EVERY
    /// SwiftUI `updateNSView` tick — which is fired by any parent state
    /// change (sidebar drag, sibling view re-render, even unrelated
    /// `@Published` mutations). The 3-pass kick triggers SIGWINCH bursts
    /// that force the Claude TUI to redraw from scratch, which on small
    /// windows looks like the content "jumping" around (the user's report).
    /// We now ONLY kick when the container's bounds actually changed —
    /// otherwise we just ensure the frame is in sync and force a paint
    /// pass, which is cheap and visually invisible.
    func refreshEmbeddedDisplay() {
        guard let term = embedded else { return }
        // Don't fight a live drag — the live-resize coalescing logic in
        // `applyTerminalFrameIfStable` / `viewDidEndLiveResize` owns frame
        // sync during drags.
        if inLiveResize { return }
        if !term.frame.equalTo(bounds) {
            // Real geometry change — kick once so SwiftTerm recomputes
            // its grid and the Claude TUI reflows the visible cells.
            kickResizeEmbeddedTerminal(passes: .single)
        } else {
            // Bounds didn't actually change. The SwiftUI updateNSView
            // call was triggered by a parent re-render. Force a paint
            // pass so any stale cells repaint without disturbing the
            // grid (no SIGWINCH, no Claude redraw, no jump).
            term.needsDisplay = true
        }
    }

    /// Force the embedded terminal to recompute its cell grid AND emit
    /// SIGWINCH even when the container's bounds haven't actually
    /// changed. Two problems the old "1pt nudge" version didn't solve:
    ///
    /// 1. **Sub-cell nudges don't change the column count.** SwiftTerm
    ///    derives `cols/rows` from `frame ÷ cellSize`. A 1pt frame
    ///    change at a typical 8pt mono cell width rounds to the same
    ///    column count, so SwiftTerm short-circuits — no `TIOCSWINSZ`,
    ///    no SIGWINCH, no Claude TUI redraw. Nudging by **a full
    ///    character cell** (~14pt is wider than any reasonable mono
    ///    font cell) guarantees the column count actually changes.
    /// 2. **One kick can fire before Claude's PTY is ready.** Right
    ///    after a session attaches, the Claude process may still be
    ///    starting — a SIGWINCH then lands in the void. Three full
    ///    kick passes staggered across the first ~600ms cover the boot
    ///    window so at least one SIGWINCH lands after Claude is ready.
    ///
    /// Each "pass" is a SHRINK followed by a RESTORE on the next runloop
    /// tick — both are real frame changes, so SwiftTerm issues SIGWINCH
    /// twice per pass. No frame is ever painted at the nudged size
    /// because the restore happens before any AppKit drawing pass runs.
    ///
    /// `passes` selects the cadence:
    /// - `.attach` runs three staggered passes (0 / 0.15s / 0.4s) so the
    ///   SIGWINCH storm covers Claude's PTY-ready window during initial
    ///   session attach.
    /// - `.single` runs exactly one pass — used after `viewDidEndLiveResize`
    ///   and on `refreshEmbeddedDisplay` geometry changes. The previous
    ///   3-pass cadence here was overkill (PTY is already up by definition)
    ///   and produced visible "jumps" + scrollbar twitch in small panes
    ///   because each pass briefly redraws Claude's TUI on the nudged grid.
    private enum KickCadence { case attach, single }

    private func kickResizeEmbeddedTerminal(passes: KickCadence) {
        guard embedded != nil else { return }
        let passOffsets: [Double] = passes == .attach ? [0, 0.15, 0.4] : [0]
        for offset in passOffsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                self?.performSingleKickPass()
            }
        }
    }

    private func performSingleKickPass() {
        guard let term = embedded, !inLiveResize else { return }
        let target = bounds
        guard target.width > 30 && target.height > 30 else { return }
        // Shrink HEIGHT (not width) by a full cell so SwiftTerm's
        // `rows = frame ÷ cellSize` recomputes and SIGWINCH fires.
        // Width-nudging would also work, but it briefly shrinks the
        // terminal's right edge — and the vertical scrollbar lives on
        // that right edge, so any horizontal nudge made the scrollbar
        // visibly hop left/right whenever the user resized the window
        // or toggled the sidebar (the user-reported "scrollbar shifts"
        // bug). Height-nudge changes the row count instead, which still
        // triggers TIOCSWINSZ but never moves the scrollbar position.
        // 14pt is taller than any reasonable mono cell, so the row
        // count is guaranteed to drop by at least one.
        var nudged = target
        nudged.size.height -= 14
        term.frame = nudged
        DispatchQueue.main.async { [weak self] in
            guard let self, let term = self.embedded, !self.inLiveResize else { return }
            term.frame = self.bounds
            term.needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let term = embedded { window?.makeFirstResponder(term) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyTerminalFrameIfStable()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        applyTerminalFrameIfStable()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Drag is over — apply the final size in one shot. SwiftTerm recomputes the grid +
        // sends a single SIGWINCH; the Claude TUI redraws once. Use the kick-resize so
        // even when `bounds == term.frame` (rare but possible after a no-op drag) a
        // SIGWINCH still fires and Claude can't be left with stale grid.
        guard embedded != nil else { return }
        kickResizeEmbeddedTerminal(passes: .single)
    }

    private func applyTerminalFrameIfStable() {
        guard let term = embedded else { return }
        // While the user is drag-resizing (window or splitter), AppKit sets `inLiveResize`
        // on the entire view tree. Skip syncing — `viewDidEndLiveResize` will catch up once.
        if inLiveResize { return }
        if !term.frame.equalTo(bounds) {
            term.frame = bounds
        }
        // Force a redraw whether or not the frame changed: a sidebar-snap
        // or chevron-collapse can leave the existing buffer painted at
        // stale offsets until the next AppKit invalidation cycle. Doing
        // this whenever the container resizes is cheap and closes the
        // "blank terminal until I move the mouse" gap completely.
        term.needsDisplay = true
    }

    // MARK: - Drag & drop (image attachments → Claude)
    //
    // The drop pipeline has three branches in priority order:
    //   1. File URLs that point at an image — pass the absolute path straight
    //      to the terminal. Claude Code's TUI parses image paths from its
    //      input buffer and attaches them as image content on the next turn,
    //      same as what happens when the user drags a Finder file directly
    //      onto the terminal-pane area in vanilla Claude Code.
    //   2. Raw image data with no backing file (dragged from a browser, a
    //      Notes window, etc.) — write to a temp file under the system temp
    //      dir, then route through branch 1.
    //   3. Anything else — refuse the drop so AppKit shows the "no entry"
    //      cursor instead of pretending we accepted it.
    //
    // We never auto-submit (no trailing newline). The user keeps control and
    // can add a description before pressing return — matches the affordance
    // of pasting a path manually.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = acceptableDragOperation(for: sender)
        if op != [] { showDropHighlight() }
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptableDragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDropHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptableDragOperation(for: sender) != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDropHighlight() }
        guard let term = embedded else { return false }
        let pasteboard = sender.draggingPasteboard

        // Branch 1: file URLs.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageURLs = urls.filter { Self.isImagePath($0.path) }
            if !imageURLs.isEmpty {
                let line = imageURLs.map { Self.shellEscape(path: $0.path) }
                                    .joined(separator: " ")
                term.send(txt: line + " ")
                window?.makeFirstResponder(term)
                return true
            }
        }

        // Branch 2: raw image data (no backing file).
        if let data = pasteboard.data(forType: .png),
           let path = Self.savePastedImage(data: data, fileExtension: "png") {
            term.send(txt: Self.shellEscape(path: path) + " ")
            window?.makeFirstResponder(term)
            return true
        }
        if let data = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: data)?
                        .representation(using: .png, properties: [:]),
           let path = Self.savePastedImage(data: png, fileExtension: "png") {
            term.send(txt: Self.shellEscape(path: path) + " ")
            window?.makeFirstResponder(term)
            return true
        }

        return false
    }

    /// Decide if a drag is something we want to accept. Limits to image
    /// payloads — text drops would conflict with the terminal's own paste
    /// gesture handling, and arbitrary file types don't make sense to inject
    /// as a path into the Claude prompt.
    private func acceptableDragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        // File URLs that resolve to image extensions.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           urls.contains(where: { Self.isImagePath($0.path) }) {
            return .copy
        }
        // Raw image data on the pasteboard.
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            return .copy
        }
        return []
    }

    private func showDropHighlight() {
        guard dropHighlight == nil, let layer = layer else { return }
        let h = CALayer()
        h.frame = bounds.insetBy(dx: 4, dy: 4)
        h.cornerRadius = 8
        h.borderWidth = 2
        h.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        h.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        h.zPosition = 1_000  // above the embedded terminal
        layer.addSublayer(h)
        dropHighlight = h
    }

    private func hideDropHighlight() {
        dropHighlight?.removeFromSuperlayer()
        dropHighlight = nil
    }

    /// True if the path's extension is a format Claude Code accepts as an
    /// image attachment. Anthropic supports JPEG/PNG/GIF/WebP at minimum;
    /// HEIC/HEIF are common Mac screenshot formats so include them too —
    /// Claude Code transparently transcodes via the system encoders.
    private static func isImagePath(_ path: String) -> Bool {
        let lower = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"].contains(lower)
    }

    /// Wrap a path for terminal injection so spaces / quotes / Hebrew
    /// characters don't get split by the shell. Claude Code's TUI parses
    /// the literal path string, but the underlying bash readline treats
    /// unquoted spaces as argument separators — single-quoting the whole
    /// path side-steps that without escaping each character.
    private static func shellEscape(path: String) -> String {
        if path.allSatisfy({ $0.isLetter || $0.isNumber
                              || $0 == "/" || $0 == "." || $0 == "_" || $0 == "-" }) {
            return path
        }
        // Single-quote the path; replace any embedded single quote with the
        // standard `'\''` close-reopen pattern.
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Persist drag-pasted image bytes to a temp file so we can hand the
    /// terminal a real path. Filename is timestamped under
    /// `~/Library/Caches/DNPRemote/dropped-images/` so multiple drops in the
    /// same session don't clobber each other and the cache directory is
    /// already covered by macOS's purgeable-data cleanup.
    private static func savePastedImage(data: Data, fileExtension: String) -> String? {
        let fm = FileManager.default
        guard let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cache.appendingPathComponent("DNPRemote/dropped-images", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
                        .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("drop-\(stamp).\(fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }
}
