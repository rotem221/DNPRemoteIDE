import Foundation
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's `LocalProcessTerminalView` — a fully featured terminal emulator (xterm-256color,
/// scrollback, full ANSI handling, proper cursor, line clearing, resize, etc.). One instance per session.
@MainActor
final class TerminalSession: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var title: String = "Terminal"

    /// The actual NSView that displays the terminal. Embed this in a SwiftUI `NSViewRepresentable`.
    let terminalView: LocalProcessTerminalView

    /// Strong reference for the SwiftTerm process-delegate bridge.
    /// `LocalProcessTerminalView.processDelegate` is `weak`, so without
    /// retaining the bridge here the freshly-constructed `SessionBridge`
    /// would deallocate the moment `init` returned — Swift's compiler
    /// flags this as `instance will be immediately deallocated`. The
    /// bridge stays alive for as long as the TerminalSession does.
    private var processDelegateBridge: SessionBridge?

    init() {
        let term = LocalProcessTerminalView(frame: .zero)
        // Theming — terminal background tracks the app's window tone (same as the
        // Settings / Diagnostics pages) instead of the previous near-black
        // `(0.06, 0.07, 0.08)`. `underPageBackgroundColor` is what `MacTheme.groupedBackground`
        // resolves to and what System Settings.app uses, so the terminal pane reads
        // as part of the IDE rather than a foreign black slab.
        term.font = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        term.nativeBackgroundColor = NSColor.underPageBackgroundColor
        term.nativeForegroundColor = NSColor.white.withAlphaComponent(0.92)
        term.caretColor = NSColor(red: 0.62, green: 0.84, blue: 1.00, alpha: 1)
        term.selectedTextBackgroundColor = NSColor(red: 0.50, green: 0.78, blue: 1.00, alpha: 0.30)
        term.allowMouseReporting = true

        self.terminalView = term
        let bridge = SessionBridge(owner: self)
        self.processDelegateBridge = bridge
        term.processDelegate = bridge
    }

    /// Owning session's UUID. Threaded into the spawned env as
    /// `DNP_SESSION_ID` so hooks fired by Claude inside this terminal
    /// carry an unambiguous routing key — `claudeSid` alone is racy
    /// (the binding only exists after the transcript watcher sees the
    /// first transcript line) and `cwd` collides when two sessions
    /// share a project. Without this, hooks from session B would land
    /// on session A's feed (the user-reported "running one session
    /// also affects the other").
    var sessionId: UUID? = nil

    /// Start the user's interactive login shell.
    func startLoginShell(workingDirectory: String? = nil) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        title = (shell as NSString).lastPathComponent
        spawn(executable: shell, args: ["-l", "-i"],
              cwd: workingDirectory ?? NSHomeDirectory())
    }

    /// Start an arbitrary command (e.g., the Claude Code CLI).
    /// We invoke the user's login shell first so PATH includes Homebrew, npm, asdf, nvm — otherwise
    /// node-based binaries like `claude` fail with `env: node: No such file or directory` because
    /// GUI apps inherit a sparse `/usr/bin:/bin:/usr/sbin:/sbin` PATH.
    func startCommand(_ executable: String, args: [String], workingDirectory: String) {
        title = (executable as NSString).lastPathComponent
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let parts = ([executable] + args).map { Self.shellQuote($0) }
        let line = "exec " + parts.joined(separator: " ")
        spawn(executable: shell, args: ["-l", "-i", "-c", line], cwd: workingDirectory)
    }

    /// Minimal POSIX-shell-safe quoting for arguments containing spaces or special chars.
    private static func shellQuote(_ s: String) -> String {
        if s.range(of: #"[^A-Za-z0-9_/.\-]"#, options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Send `SIGHUP` to the running process and reset the view.
    func stop() {
        if let process = terminalView.process, process.running {
            process.terminate()
        }
        isRunning = false
    }

    /// Inject text into the PTY as if the user typed it. Used to relay iOS prompts into the
    /// running Claude / shell. SwiftTerm's `TerminalView` exposes `send(txt:)` for exactly this.
    func sendInput(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Snapshot the LAST `maxLines` rows of Claude's TUI as plain text — ANSI/colour
    /// stripped by SwiftTerm during render so what you get back is what the user sees.
    /// Empty lines are dropped to keep the snapshot dense; the cost is one pass over
    /// at most `maxLines` BufferLines, cheap enough for sub-second polling.
    func recentVisibleText(maxLines: Int = 24) -> String {
        guard let term = terminalView.terminal else { return "" }
        let dims = term.getDims()
        guard dims.rows > 0 else { return "" }
        let start = max(0, dims.rows - maxLines)
        var lines: [String] = []
        lines.reserveCapacity(dims.rows - start)
        for row in start ..< dims.rows {
            guard let line = term.getLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }

    /// True if Claude's inline approval prompt is currently visible in the terminal.
    /// Three independent signals — ANY hits → it's a prompt. Each one is specific
    /// enough to a numbered choice menu that regular chat content can't trip it:
    ///
    ///   1. **Caret glyph**: the `❯ 1.` (or `❯ 1)`) row Claude renders on the
    ///      currently-highlighted choice. The caret + leading numeral is unique
    ///      to the choice menu — chat prose never produces it.
    ///   2. **Three consecutive numbered options near the bottom** (`1.`/`1)`,
    ///      `2.`/`2)`, `3.`/`3)`). Catches stripped/ASCII variants where the
    ///      caret glyph isn't drawn and prompts that came in over a narrow
    ///      terminal width. We only scan the bottom ~12 lines because that's
    ///      where the menu always lives.
    ///   3. **Trigger headline + `1.|1) Yes`**: the previous narrow check kept
    ///      as a safety net for prompts that don't render either of the above.
    ///
    /// The previous form required (1)+(headline) AND it false-negatived on every
    /// prompt that didn't include the literal phrases `Do you want` / `Allow
    /// Claude` / `Allow this` — newer Claude builds use `Use this …`,
    /// `Continue?`, `Confirm:` and other variants we kept missing. That's the
    /// "allow didn't pop multiple times when it should have" bug.
    func isAtClaudePrompt() -> Bool {
        let snapshot = recentVisibleText()
        guard !snapshot.isEmpty else { return false }

        // Signal 1 — caret glyph next to a numbered option.
        if snapshot.contains("❯ 1.") || snapshot.contains("❯ 1)") { return true }

        // Signal 2 — three numbered options near the bottom of the buffer.
        let lines = snapshot.split(separator: "\n").map(String.init)
        var has1 = false, has2 = false, has3 = false
        for line in lines.suffix(12) {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Strip a leading caret glyph so `❯ 1. Yes` is recognised as `1. Yes`.
            let s = t.hasPrefix("❯ ") ? String(t.dropFirst(2)) : t
            if s.hasPrefix("1.") || s.hasPrefix("1)") { has1 = true; continue }
            if s.hasPrefix("2.") || s.hasPrefix("2)") { has2 = true; continue }
            if s.hasPrefix("3.") || s.hasPrefix("3)") { has3 = true; continue }
        }
        if has1 && has2 && has3 { return true }

        // Signal 3 — trigger headline + first option (the original narrow rule).
        let triggers = [
            "Do you want", "Allow Claude", "Allow this",
            "Use this", "Run this", "Apply this", "Continue?", "Confirm:",
            "Proceed?",
        ]
        let menuMarkers = ["1. Yes", "1) Yes"]
        if triggers.contains(where: { snapshot.contains($0) }) &&
           menuMarkers.contains(where: { snapshot.contains($0) }) {
            return true
        }
        return false
    }

    // MARK: - Private

    private func spawn(executable: String, args: [String], cwd: String) {
        // Always stop a previous run first.
        stop()

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["DNP_REMOTE"] = "1"
        // Per-session marker — read by `dnp-remote-hook.sh` and stamped
        // into every hook payload as `dnp_session_id`. Lets the Mac
        // route hook events to the correct local session even when
        // multiple Claude sessions share the same `cwd` (two sessions
        // in one project, the bug behind "running one session also
        // affects the other").
        if let sid = sessionId {
            env["DNP_SESSION_ID"] = sid.uuidString
        }
        env["PWD"] = cwd
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // SwiftTerm spawns the child with our current cwd. Set it briefly across the call.
        let saved = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(cwd)
        terminalView.startProcess(executable: executable, args: args, environment: envArray)
        FileManager.default.changeCurrentDirectoryPath(saved)
        isRunning = true
    }

    fileprivate func processDidExit() {
        isRunning = false
    }
    fileprivate func updateHostingTitle(_ s: String) {
        title = s
    }
}

/// Forwards SwiftTerm process callbacks back to the owning `TerminalSession`.
/// Has to be a separate object because `LocalProcessTerminalViewDelegate` requires `AnyObject`
/// and we want @MainActor isolation on the session.
private final class SessionBridge: NSObject, LocalProcessTerminalViewDelegate {
    weak var owner: TerminalSession?
    init(owner: TerminalSession) { self.owner = owner }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { /* no-op */ }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak owner] in owner?.updateHostingTitle(title) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { /* no-op */ }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak owner] in owner?.processDidExit() }
    }
}
