import SwiftUI
import AppKit

/// Cursor / VS Code-style command palette. Keyed off ⌘P; opens a centered overlay with a
/// search field and a filtered list. Two prefixes are wired and useful:
///   `>` → commands only (mirrors VS Code's "Show and Run Commands")
///   `?` → help / shortcuts cheat sheet
/// Anything else: matches recent sessions, open files, hand-curated commands, and (after
/// a short debounce) a content search across the project. Default empty-query view
/// surfaces the three things the user wants 90% of the time — recent sessions, open
/// files, and a small set of high-value actions — instead of a flat dump of every command.
struct CommandPaletteView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @Binding var isPresented: Bool

    /// When `true`, render the in-palette query field (legacy standalone
    /// usage). When `false`, the title-bar search input is the source of
    /// the query and the palette renders results-only — used by the new
    /// "trigger stays in place, dropdown opens beneath it" UX.
    var showsQueryField: Bool = true

    @State private var hits: [FileSearchHit] = []
    @State private var isSearching = false
    @State private var debounce: Task<Void, Never>?
    @State private var highlightIndex: Int = 0
    @FocusState private var fieldFocused: Bool

    /// Live query — sourced from the workspace controller so a single
    /// TextField (either the in-palette field or the title-bar trigger)
    /// drives both the dropdown filter and any debounced file search.
    private var query: String {
        get { workspace.paletteQuery }
    }
    private var queryBinding: Binding<String> {
        Binding(get: { workspace.paletteQuery },
                set: { workspace.paletteQuery = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsQueryField {
                queryField
                Divider().background(MacTheme.border.opacity(0.5))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    let items = filteredItems
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        PaletteRow(item: item, highlighted: idx == highlightIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { item.run(vm: vm, workspace: workspace); isPresented = false }
                            .onHover { inside in if inside { highlightIndex = idx } }
                    }
                    if items.isEmpty {
                        Text(emptyHint)
                            .font(.subheadline)
                            .foregroundStyle(MacTheme.textTertiary)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                    }
                }
                // Top padding only — the bottom padding used to leave a
                // visible gap between the last row and the footer band,
                // exactly the "extra space" the user flagged earlier.
                // The footer itself supplies its own vertical padding,
                // so we don't need any breathing room from this side.
                .padding(.top, 4)
            }
            // Height adapts to the number of results — 1 row when there
            // is one match, growing row-by-row up to a 5-row cap. Beyond
            // 5 the ScrollView takes over and the user scrolls inside
            // the same 5-row viewport. No more "fixed 280pt window with
            // mostly empty space when there are 1-2 results".
            .frame(height: dropdownHeight)
            footer
        }
        // No fixed width — the parent supplies a frame matched to the toolbar trigger so
        // the palette grows downward from the trigger at the same width. We cap height
        // via the inner ScrollView's .frame(maxHeight: 280).
        //
        // Sharp 4pt corners (was 8pt). The hover-row highlight at the bottom of the
        // list used to follow the popover's curve and looked like a rounded chip;
        // the smaller radius keeps the silhouette cleanly rectangular against the
        // surrounding chrome and lets the row hover read as a plain rectangle.
        .background(MacTheme.surfaceAlt.opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(MacTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        // Clip to the same rectangle the background paints so any row
        // hover near the popover edge gets clipped along straight lines
        // (with the tiny 4pt rounding only) — no curved silhouette
        // bleeding into the highlight at the bottom corners.
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .onAppear {
            if showsQueryField { fieldFocused = true }
            // Always run an initial search/filter pass so opening the
            // palette with an existing query (typed into the title-bar
            // trigger before the dropdown rendered) immediately shows
            // matching results.
            scheduleSearch()
        }
        .onChange(of: workspace.paletteQuery) { _, _ in
            highlightIndex = 0
            scheduleSearch()
        }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.return) { runHighlighted(); return .handled }
    }

    /// Query field styled to match the toolbar's collapsed search trigger so the palette
    /// looks like it physically grew out of the trigger. Same horizontal/vertical padding,
    /// same icon styling, same `⌘P` keycap on the right.
    private var queryField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(MacTheme.textTertiary)
            TextField(placeholder, text: queryBinding)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($fieldFocused)
                .onSubmit { runHighlighted() }
            if !query.isEmpty {
                Button { workspace.paletteQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 2) {
                Image(systemName: "command").font(.caption2.weight(.semibold))
                Text("P").font(.caption.weight(.semibold))
            }
            .foregroundStyle(MacTheme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(MacTheme.border, lineWidth: 0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            shortcut(label: "Run", keys: ["return"])
            shortcut(label: "Move", keys: ["chevron.up", "chevron.down"])
            shortcut(label: "Close", keys: ["escape"])
            Spacer()
            Text("\(filteredItems.count) results")
                .font(.caption2)
                .foregroundStyle(MacTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        // 5pt vertical (was 8). Tighter band so the popover ends right
        // under the keyboard hints instead of sitting on a fat strip
        // that visually duplicates the row gap above it.
        .padding(.vertical, 5)
        .background(MacTheme.surfaceAlt.opacity(0.4))
    }

    private func shortcut(label: String, keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in
                Image(systemName: k)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(MacTheme.border, lineWidth: 0.5))
            }
            Text(label).font(.caption2).foregroundStyle(MacTheme.textTertiary)
        }
    }

    /// Approximate height of one `PaletteRow` — title (.body) + subtitle
    /// (.caption) stacked, plus the row's `padding(.vertical, 8)`. Used
    /// to size the dropdown viewport so it shrinks to fit when there are
    /// fewer than 5 results and caps cleanly at 5 rows when there are
    /// more. Slight overestimate is intentional: a few extra pixels of
    /// breathing room beats clipping the descender on the subtitle.
    private static let approxRowHeight: CGFloat = 50

    /// Height of the results viewport. `min(count, 5)` keeps the cap at
    /// 5 visible rows; `max(1, …)` guarantees at least one row's worth
    /// of height for the empty-state hint. Top padding (4pt) is added
    /// so the height matches what's actually drawn inside.
    private var dropdownHeight: CGFloat {
        let visible = max(1, min(filteredItems.count, 5))
        return CGFloat(visible) * Self.approxRowHeight + 4
    }

    private var placeholder: String {
        // Reflects the wired prefixes only — `:line` / `@symbol` placeholders
        // were removed because they didn't do anything yet and trained users
        // to type tokens that no-op'd.
        "Search sessions, files, commands… (> commands, ? help)"
    }

    private var emptyHint: String {
        if query.hasPrefix(">") { return "No matching commands" }
        // Empty-query state never reaches this branch — `defaultItems`
        // always has content while a project is open — but kept as a
        // safe fallback for new/empty workspaces.
        if query.isEmpty { return "Start typing to search" }
        return "No matches"
    }

    // MARK: - Items

    /// Hand-curated commands worth a palette slot. Two rules:
    ///   1. Available from at least one other obvious surface (menu / button / shortcut)?
    ///      Keep it ONLY if typing it is materially faster than reaching that surface.
    ///   2. One-time setup (e.g. pairing) — keep but don't surface in the empty-query
    ///      default; let the user search for it explicitly.
    /// Removed deliberately: "Show Files / Sessions / Events Sidebar" — the side rail
    /// already shows these toggles one click away, the palette doesn't need to duplicate
    /// the sidebar's job. "Open Project Folder…" stays out: each workspace window is
    /// pinned to its project; opening another project happens from the Welcome window.
    private var commands: [PaletteItem] {
        var items: [PaletteItem] = [
            .command(title: "New Session", subtitle: "Spawn a new Claude Code terminal",
                     icon: "plus.rectangle.on.rectangle",
                     run: { vm, ws in Task { @MainActor in await vm.newSession(in: ws) } }),
            .command(title: "Show Terminal",
                     subtitle: "Return to the active session's terminal",
                     icon: "terminal",
                     run: { _, ws in ws.workspacePane = .terminal }),
            .command(title: "Open GitHub Pane",
                     subtitle: "Manage gh authentication and repos",
                     icon: "chevron.left.forwardslash.chevron.right",
                     run: { _, ws in ws.workspacePane = .github }),
            .command(title: "Open Settings",
                     subtitle: "App-wide preferences",
                     icon: "gearshape",
                     run: { _, ws in ws.workspacePane = .settings }),
            .command(title: "Open Diagnostics",
                     subtitle: "Bridge / Claude / hook health",
                     icon: "stethoscope",
                     run: { _, ws in ws.workspacePane = .diagnostics }),
            .command(title: "Open Pairing",
                     subtitle: "Show the QR + 6-digit code for iOS",
                     icon: "iphone.radiowaves.left.and.right",
                     run: { _, ws in ws.workspacePane = .pairing })
        ]
        // "Launch Claude in Terminal" appears only when the binary was detected
        // — surfacing a command the user can't run is worse than hiding it.
        if vm.claude.detectedPath != nil {
            items.insert(
                .command(title: "Launch Claude in Terminal",
                         subtitle: "Boot Claude Code in the current session",
                         icon: "sparkles",
                         run: { vm, _ in vm.startClaudeInTerminal() }),
                at: 1
            )
        }
        return items
    }

    /// Sessions ordered most-recent-first so the user lands on what they were
    /// just working in. Capped at 3 in the empty-query default view to keep the
    /// list scannable; full search results expand to all matching sessions.
    private var recentSessions: [Session] {
        workspace.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Open file tabs as quick-jump items — the user wants to bounce between
    /// the 2-3 files they have open without taking their hands off the keyboard.
    private var openFileItems: [PaletteItem] {
        workspace.openFiles.suffix(5).reversed().map { f in
            .file(hit: FileSearchHit(path: f.node.url.path, isDirectory: false),
                  run: { _, ws in ws.openFile(f.node) })
        }
    }

    /// Sessions show up under the same query so the user can switch with one keystroke.
    /// Scoped to THIS window's project; sorted most-recent-first so a top-N slice
    /// surfaces what the user touched last.
    private var sessionItems: [PaletteItem] {
        recentSessions.map { s in
            .session(session: s, run: { _, ws in
                // `switchToSession` collapses the split tree if the
                // picked session isn't already a leaf — same rule the
                // sidebar uses, so palette → session feels identical
                // to sidebar → session.
                ws.switchToSession(s.id)
                ws.workspacePane = .terminal
            })
        }
    }

    /// Final filtered list, prefix-aware.
    ///
    /// Empty query produces a SMART default: the top 3 most-recent sessions,
    /// then up to 3 currently-open files, then a small set of high-value
    /// commands. That ordering matches what users reach for first when they
    /// open the palette (switch session → jump back to a file → run an
    /// action), and keeps the list scannable at a glance.
    ///
    /// Typed query searches across all three categories, ordered by likely
    /// usefulness: sessions first (cheapest navigation), commands next,
    /// then file-content hits from the debounced project search.
    private var filteredItems: [PaletteItem] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return defaultItems
        }
        if raw.hasPrefix(">") {
            // Commands-only mode.
            let q = String(raw.dropFirst()).lowercased()
            return commands.filter { $0.matches(q) }
        }
        if raw.hasPrefix("?") {
            return helpItems
        }
        let q = raw.lowercased()
        let matchedSessions = sessionItems.filter { $0.matches(q) }
        let matchedCommands = commands.filter { $0.matches(q) }
        let matchedFiles = hits.map { hit -> PaletteItem in
            .file(hit: hit, run: { _, ws in
                // Directory hits are skipped — palette-from-inside-a-workspace opens
                // FILES into the editor; opening another project from here would
                // violate the "this window owns its project" rule. To open a different
                // project, close the window (⇧⌘W) and pick from Welcome.
                if !hit.isDirectory {
                    ws.openFile(FileNode(url: URL(fileURLWithPath: hit.path)))
                }
            })
        }
        return matchedSessions + matchedCommands + matchedFiles
    }

    /// Empty-query "smart default" — recent sessions + open files + key
    /// commands. Each group is capped so the dropdown never feels like a
    /// dump; the caps fit comfortably inside the 280pt scroll viewport.
    private var defaultItems: [PaletteItem] {
        let topSessions = Array(sessionItems.prefix(3))
        let topFiles    = Array(openFileItems.prefix(3))
        let topActions  = Array(commands.prefix(4))
        return topSessions + topFiles + topActions
    }

    /// The `?` help mode lists the prefix tokens themselves so the user can
    /// discover them. Only the two prefixes that are actually wired show up
    /// here — we used to list `:line` and `@symbol` placeholders that didn't
    /// do anything and just trained users to type tokens that no-op'd.
    private var helpItems: [PaletteItem] {
        [
            .command(title: "> Commands",
                     subtitle: "Filter to runnable commands only",
                     icon: "command", run: { _, _ in }),
            .command(title: "? Help",
                     subtitle: "Show this prefix list",
                     icon: "questionmark.circle", run: { _, _ in })
        ]
    }

    // MARK: - Behaviour

    private func moveHighlight(_ delta: Int) {
        let n = filteredItems.count
        guard n > 0 else { return }
        highlightIndex = (highlightIndex + delta + n) % n
    }

    private func runHighlighted() {
        let items = filteredItems
        guard items.indices.contains(highlightIndex) else { return }
        items[highlightIndex].run(vm: vm, workspace: workspace)
        isPresented = false
    }

    /// 250 ms debounce around `vm.searchFiles` so we don't shell-out on every keystroke.
    private func scheduleSearch() {
        debounce?.cancel()
        let snap = workspace.paletteQuery
        debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled || snap != workspace.paletteQuery { return }
            let q = snap
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[>?:]\\s*", with: "", options: .regularExpression)
            guard !q.isEmpty, let root = workspace.projectRoot?.url.path else {
                hits = []
                return
            }
            isSearching = true
            let resp = await vm.searchFiles(payload: FileSearchRequestPayload(
                rootPath: root, query: q, maxResults: 30, searchContent: true))
            if Task.isCancelled || snap != workspace.paletteQuery { return }
            hits = resp.hits
            isSearching = false
        }
    }
}

// MARK: - Item model

enum PaletteItem {
    /// Action closures take (vm, workspace) — vm for global state (sessions list, claude
    /// detector), workspace for per-window state (sidebar tab/expansion, workspacePane,
    /// selected session).
    case command(title: String, subtitle: String, icon: String,
                 run: (MacAppViewModel, WorkspaceController) -> Void)
    case session(session: Session,
                 run: (MacAppViewModel, WorkspaceController) -> Void)
    case file(hit: FileSearchHit,
              run: (MacAppViewModel, WorkspaceController) -> Void)

    var title: String {
        switch self {
        case .command(let t, _, _, _):     return t
        case .session(let s, _):           return s.title
        case .file(let h, _):              return (h.path as NSString).lastPathComponent
        }
    }
    var subtitle: String {
        switch self {
        case .command(_, let s, _, _):     return s
        case .session(let s, _):           return s.projectName
        case .file(let h, _):              return (h.path as NSString).deletingLastPathComponent
        }
    }
    var icon: String {
        switch self {
        case .command(_, _, let i, _):     return i
        case .session:                     return "rectangle.stack"
        case .file(let h, _):              return h.isDirectory ? "folder.fill" : "doc"
        }
    }

    func matches(_ q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q) || subtitle.lowercased().contains(q)
    }

    func run(vm: MacAppViewModel, workspace: WorkspaceController) {
        switch self {
        case .command(_, _, _, let run): run(vm, workspace)
        case .session(_, let run):       run(vm, workspace)
        case .file(_, let run):          run(vm, workspace)
        }
    }
}

// MARK: - Row

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.callout)
                .foregroundStyle(highlighted ? MacTheme.accent : MacTheme.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(MacTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(highlighted ? MacTheme.accent.opacity(0.15) : Color.clear)
    }
}
