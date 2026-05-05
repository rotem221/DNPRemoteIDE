import Foundation
import SwiftUI

/// Per-window workspace state. Each project window owns one of these — it holds the
/// **window-local** UI state (which session is selected, which sidebar tab is open,
/// which files are open in the editor, etc.) and exposes computed views over the
/// global `MacAppViewModel` filtered by this window's project path.
///
/// Why this exists: the singleton `MacAppViewModel` owns everything that's truly global
/// (the bridge listener, paired devices, the entire pool of running terminal sessions
/// across all projects, the session-event feed). Each open project window, however, is
/// its own workspace — it should only show the sessions that belong to **its** project,
/// the user's selected session within that project, the file tree rooted at its
/// project's directory, etc. Putting that state on the singleton would make all windows
/// show the same project — that's the bug we're fixing with this refactor.
///
/// Architecture invariants:
/// - All MUTATIONS to global state (creating a session, sending a prompt, deciding an
///   approval) go through methods on this controller, which forward to the coordinator
///   with the workspace's project path so the operation is scoped correctly.
/// - All READS of global state are exposed as filtered computed properties (e.g.
///   `sessions` returns only sessions whose `projectPath` matches the workspace).
/// - SwiftUI views inside a window observe THIS controller for project-scoped data and
///   the coordinator for genuinely-global data (bridge status, paired devices, etc.).
@MainActor
final class WorkspaceController: ObservableObject, Identifiable {

    // MARK: - Identity
    /// Project path is the window's identity — `WindowGroup(for: URL.self)` keys off this.
    let id: URL

    /// The global app-level VM. The controller forwards mutations through this and reads
    /// global pools (sessions, terminals, feed) for its filtered views.
    let coord: MacAppViewModel

    // MARK: - Window-local UI state

    /// The project tree root — drives the file explorer + the cwd for new sessions.
    /// Set in `init` from the URL the window was opened with; rebuilt on `refreshProject`.
    @Published var projectRoot: FileNode?

    /// GitHub backing detection — `<projectRoot>/.git/config` resolved on open.
    @Published var projectGitHub: GitHubProjectInfo?

    /// Which session inside this project is currently focused. Persists across the
    /// window's lifetime; reset to the project's first session when the active one is
    /// closed. NEVER references a session whose `projectPath` differs from this
    /// workspace's URL — `sessions` filters guarantee that.
    ///
    /// `didSet` notifies the coordinator so it can broadcast the new
    /// id to paired iOS clients — that's what makes the iPhone session
    /// capsule auto-follow whichever pane the user clicked on the Mac.
    /// Last-write-wins across multi-window setups (acceptable: the
    /// most-recent click is the user's "intended focus").
    @Published var selectedSessionId: UUID? {
        didSet {
            guard selectedSessionId != oldValue else { return }
            coord.notifyActiveSessionChanged(selectedSessionId)
        }
    }

    /// Recursive split layout for the workspace's terminal area. `nil` means
    /// "single pane = `selectedSessionId`" — i.e. the workspace is showing
    /// exactly one terminal and there's no split chrome to render. When
    /// non-nil, every visible pane is a leaf in this tree and every divider
    /// is a `.split` node; `selectedSessionId` then identifies which leaf
    /// has keyboard focus for inline operations like "Split right".
    ///
    /// Capped at 4 leaves total (matches what fits comfortably in a 2x2
    /// grid on a typical Mac display). Adding a 5th pane is a no-op.
    /// Stale leaves (sessions that ended or were removed) are pruned by
    /// `pruneTreeIfStale()` after any session-list mutation, exactly as
    /// the old `splitSessionId` was pruned.
    @Published var paneTree: PaneTree?

    @Published var openFiles: [OpenFile] = []
    @Published var activeFile: OpenFile?

    /// Center pane mode — terminal vs. settings vs. github page etc. Per-window so
    /// switching to Settings in window A doesn't blank out window B's terminal.
    @Published var workspacePane: WorkspacePane = .terminal

    @Published var sidebarTab: SidebarTab
    @Published var sidebarExpanded: Bool

    /// Whether the project-scoped command palette (search / commands / file
    /// jump) is currently open. Promoted from a per-view `@State` to a
    /// per-window controller flag because the trigger now lives in the top
    /// title-bar row (rendered by `MacAppShellView`) while the dropdown
    /// overlay still anchors off the trigger frame inside the workspace —
    /// both views need to read/write the same flag.
    @Published var paletteOpen: Bool = false

    /// Live query text shared between the title-bar search input and the
    /// palette dropdown. Lifted out of `CommandPaletteView`'s `@State` so
    /// the trigger itself is the single TextField the user types into —
    /// the dropdown reads this same value to filter its results, with no
    /// duplicate input field of its own.
    @Published var paletteQuery: String = ""

    /// Session id whose row is currently the live drop target during a
    /// drag-reorder gesture in the sidebar. Drives the per-row insertion
    /// indicator (a 2pt accent line drawn on the top edge of the target
    /// row) so the user can see exactly where the drop will land. Cleared
    /// when the drag exits the row OR when the drop completes.
    @Published var dropTargetSessionId: UUID? = nil

    // `isInTabGroup` was removed alongside the "Tabs in one window"
    // feature. Every project now opens in its own dedicated window, so
    // there's no per-window "is this in a tab group" state to track.

    /// File paths Claude has touched in this workspace's project — read-through view
    /// of `coord.editedFilesByProject[<this project root>]`. Populated from
    /// `.codeEditSummary` events; drives the orange dot + tinted-name decoration in
    /// the file explorer (the file itself AND every ancestor folder).
    var editedFilePaths: Set<String> {
        guard let root = projectRoot?.url.standardizedFileURL.path else { return [] }
        return coord.editedFilesByProject[root] ?? []
    }

    // MARK: - Init / lifecycle

    init(projectURL: URL, coord: MacAppViewModel) {
        self.id = projectURL.standardizedFileURL
        self.coord = coord
        self.projectRoot = FileNode(url: projectURL)
        // GitHub detection deliberately deferred — `GitHubProjectInfo.detect` shells
        // out to `git` (Process + waitUntilExit), and SwiftUI calls `init` from inside
        // its layout/update cycle. Running a synchronous Process spin from there spins
        // the runloop, re-enters SwiftUI's update, and crashes with
        // "AttributeGraph precondition failure: setting value during update" → SIGABRT.
        // We hydrate the GitHub info asynchronously from `WorkspaceWindow.onAppear`.
        self.projectGitHub = nil

        let raw = UserDefaults.standard.string(forKey: "dnp.mac.sidebar.tab.\(projectURL.path)")
            ?? UserDefaults.standard.string(forKey: "dnp.mac.sidebar.tab")
        self.sidebarTab = raw.flatMap { SidebarTab(rawValue: $0) } ?? .files

        let expandedKey = "dnp.mac.sidebar.expanded.\(projectURL.path)"
        let expanded = (UserDefaults.standard.object(forKey: expandedKey) as? Bool)
            ?? (UserDefaults.standard.object(forKey: "dnp.mac.sidebar.expanded") as? Bool)
            ?? false
        self.sidebarExpanded = expanded

        let projectSessions = coord.sessions.filter { $0.projectPath == projectURL.path }
        self.selectedSessionId = projectSessions.first?.id
    }

    /// Resolve `<projectRoot>/.git/config` to populate `projectGitHub`. Called from the
    /// window's `onAppear` (off the SwiftUI update cycle), or after a `git checkout`
    /// to refresh the branch chip. Runs on a background queue so the synchronous
    /// `git symbolic-ref` shell-out doesn't block the main thread.
    func detectGitHubAsync() {
        guard let url = projectRoot?.url else { return }
        Task.detached(priority: .userInitiated) {
            let info = GitHubProjectInfo.detect(at: url)
            await MainActor.run { [weak self] in
                self?.projectGitHub = info
            }
        }
    }

    // MARK: - Convenience derived properties

    /// Folder name shown in the status-bar pill / file-explorer header. Mirrors the old
    /// `MacAppViewModel.projectRootName` so views can migrate without changing call sites.
    var projectRootName: String? { projectRoot?.url.lastPathComponent }

    /// Convenience used by the workspace view to close a file in the editor stack — same
    /// semantics as `MacAppViewModel.closeFile(_:)` but scoped to this window's open files.
    func closeFile(_ file: OpenFile) {
        openFiles.removeAll { $0.id == file.id }
        if activeFile?.id == file.id {
            activeFile = openFiles.last
            workspacePane = activeFile.map { .editor($0) } ?? .terminal
        }
    }

    // MARK: - Filtered views over coordinator state

    /// Sessions that belong to this workspace's project. Recomputed from
    /// `coord.sessions` on every read so the list stays correct as sessions are added /
    /// closed across windows.
    ///
    /// Both sides of the comparison are run through
    /// `MacAppViewModel.normalizedProjectPath(_:)` so a session stamped
    /// with a slightly different surface form of the same folder (trailing
    /// slash, unresolved symlink, `~` vs `/Users/<name>`, `.` segment)
    /// still matches the workspace it actually belongs to. The exact-
    /// equality compare we used to do let cross-project sessions leak
    /// into the wrong sidebar — the user reported a temp-folder session
    /// appearing inside their "Local Agent" workspace, which is exactly
    /// what this fixes.
    var sessions: [Session] {
        guard let raw = projectRoot?.url.path else { return [] }
        let key = MacAppViewModel.normalizedProjectPath(raw)
        return coord.sessions.filter {
            MacAppViewModel.normalizedProjectPath($0.projectPath) == key
        }
    }

    /// Pending approvals scoped to this workspace — only ones whose session's
    /// `projectPath` matches. Used by the in-app approval card so an approval raised in
    /// project A doesn't appear in project B's window.
    var pendingApprovals: [ApprovalRequest] {
        let mySessionIds = Set(sessions.map { $0.id })
        return coord.pendingApprovals.filter { mySessionIds.contains($0.sessionId) }
    }

    var feed: [UUID: [SessionEvent]] {
        let mySessionIds = Set(sessions.map { $0.id })
        return coord.feed.filter { mySessionIds.contains($0.key) }
    }

    var contextSnapshots: [UUID: ContextSnapshot] {
        let mySessionIds = Set(sessions.map { $0.id })
        return coord.contextSnapshots.filter { mySessionIds.contains($0.key) }
    }

    /// Mark this workspace as the **currently-active** one — called when its window
    /// becomes the key window. Mirrors the workspace's project-scoped state into the
    /// legacy fields on `MacAppViewModel` so internal code paths that haven't been
    /// migrated to take a `WorkspaceController` parameter yet (hook routing, transcript
    /// watcher, dispatcher's "where do new sessions go" logic) continue to read the
    /// right projectRoot. New views read THIS controller directly and don't depend on
    /// the mirror — the mirror only exists to keep the legacy paths working.
    func activate() {
        coord.activeWorkspace = self
        coord.projectRoot = projectRoot
        coord.projectGitHub = projectGitHub
        coord.openFiles = openFiles
        coord.activeFile = activeFile
        coord.workspacePane = workspacePane
        coord.sidebarTab = sidebarTab
        coord.sidebarExpanded = sidebarExpanded
        coord.selectedSessionId = selectedSessionId
    }

    // MARK: - Mutations (forwarded to coordinator with the right project scope)

    @discardableResult
    func newSession() async -> Session {
        await coord.newSession(in: self)
    }

    func selectedSession() -> Session? {
        guard let id = selectedSessionId else { return sessions.first(where: { $0.status != .ended }) }
        return sessions.first(where: { $0.id == id })
    }

    func requestClose(sessionId: UUID) {
        coord.requestClose(sessionId: sessionId)
        pruneTreeIfStale()
    }

    // MARK: - Split-pane control
    //
    // Three operations the UI needs: enter split (creating a brand-new
    // session for the secondary pane is the natural default — the user
    // wants TWO sessions running, not the same session shown twice), close
    // split (drop the secondary, keep both sessions alive in the global
    // pool), and swap the two panes (primary ↔ secondary).
    //
    // `pruneTreeIfStale()` runs after any session-list change to make
    // sure `splitSessionId` doesn't dangle to a closed session — leaving
    // it pointing at an `.ended` session would render an empty pane.

    /// Spawn a new session and attach it to the layout by splitting the
    /// currently focused leaf. `direction` controls which way the split
    /// runs: `.horizontal` adds the new pane to the right of the focused
    /// pane, `.vertical` adds it below.
    ///
    /// Caps the layout at 4 panes — a 5th call is a soft no-op that just
    /// returns a freshly spawned session without attaching it (the caller
    /// can decide what to do; the toolbar disables the action above 4).
    @discardableResult
    func splitWithNewSession(direction: PaneOrientation = .horizontal) async -> Session {
        // CRITICAL: snapshot BOTH the focused leaf AND the current tree
        // BEFORE awaiting the new session. `coord.newSession(in:)`
        // mutates `selectedSessionId` (and may go through
        // `switchToSession` in the future, which would also flip
        // `paneTree` to nil). Reading either after the await would
        // produce the wrong reference and rebuild a degenerate layout
        // — the bug behind "splits don't work past 2 panes".
        let priorFocus = selectedSessionId
        let priorTree = paneTree
        let new = await coord.newSession(in: self)
        guard let focus = priorFocus else {
            // No prior focus — workspace was empty. The new session
            // becomes the only pane; selection is already on it.
            paneTree = nil
            return new
        }
        if priorTree == nil {
            // Single-pane → first split. Build a fresh 2-leaf tree with
            // the prior focus on the leading side and the new session on
            // the trailing side. Focus stays on the new pane (matches
            // tmux / iTerm convention — split-and-type-immediately).
            paneTree = .split(direction: direction,
                              leading: .leaf(focus),
                              trailing: .leaf(new.id),
                              fraction: 0.5)
            return new
        }
        // Already split — replace the focused leaf with a sub-split so
        // the new pane appears next to / below the one the user was in.
        if priorTree!.leafCount >= 4 {
            // Soft cap: don't attach. Restore the tree as-is in case
            // `coord.newSession` collapsed it; the new session lives in
            // the global session list but isn't laid out anywhere.
            paneTree = priorTree
            return new
        }
        paneTree = priorTree!.replacing(focus,
                                         with: .split(direction: direction,
                                                      leading: .leaf(focus),
                                                      trailing: .leaf(new.id),
                                                      fraction: 0.5))
        return new
    }

    /// Close a single pane. Removes its leaf and collapses the parent
    /// split (parent becomes its sibling). When only one leaf remains,
    /// drops `paneTree` back to nil — single-pane mode.
    func closePane(_ id: UUID) {
        guard let tree = paneTree else {
            // Single-pane mode: closing the only pane just clears focus.
            if selectedSessionId == id { selectedSessionId = nil }
            return
        }
        let next = tree.removing(id)
        applyPrunedTree(next, removed: id)
    }

    /// Swap two leaves in the tree — keeps the layout shape but flips
    /// which session sits in which slot. Used by the pane header's
    /// "swap" affordance for the secondary pane in a 2-leaf root split.
    func swapLeaves(_ a: UUID, _ b: UUID) {
        guard let tree = paneTree else { return }
        paneTree = tree.swapping(a, b)
    }

    /// Drop any leaves whose session is dead or removed; collapse parent
    /// splits whose sole remaining child becomes nil. Called after any
    /// session-list mutation bubbles through.
    func pruneTreeIfStale() {
        guard let tree = paneTree else { return }
        let live = Set(sessions.filter { $0.status != .ended }.map { $0.id })
        let next = tree.pruning { live.contains($0) }
        applyPrunedTree(next, removed: nil)
    }

    /// Re-anchor `selectedSessionId` and `paneTree` after a tree mutation:
    ///   - if the new tree is a single leaf, demote to single-pane mode
    ///   - if focus pointed at a leaf that no longer exists, jump to
    ///     whatever leaf is still alive (first one in the tree)
    private func applyPrunedTree(_ next: PaneTree?, removed: UUID?) {
        switch next {
        case .none:
            paneTree = nil
            // The tree is empty. The current selection is stale if the
            // closed/pruned id matches OR if the surviving session list
            // doesn't include it (the prune-stale path passes
            // `removed == nil` and may take EVERY leaf away in one go,
            // so the explicit removed-id check alone wouldn't catch it).
            if let removed, selectedSessionId == removed {
                selectedSessionId = nil
            } else if let sel = selectedSessionId,
                      sessions.contains(where: { $0.id == sel && $0.status != .ended }) == false {
                selectedSessionId = sessions.first(where: { $0.status != .ended })?.id
            }
        case .leaf(let only):
            paneTree = nil
            selectedSessionId = only
        case .split:
            paneTree = next
            if let removed, selectedSessionId == removed {
                selectedSessionId = next?.firstLeaf
            } else if let sel = selectedSessionId, next?.contains(sel) != true {
                selectedSessionId = next?.firstLeaf
            }
        }
    }

    /// Switch the visible terminal area to render `sessionId`. The
    /// "right" thing to do depends on whether the requested session
    /// is currently a leaf in `paneTree`:
    ///
    ///   * If it IS in the tree → just focus that leaf. Keeps all
    ///     existing panes visible; the user is moving keyboard focus,
    ///     not changing the layout.
    ///   * If it is NOT in the tree → collapse the tree and switch
    ///     to single-pane mode on the requested session. The panes
    ///     that were visible stay alive in the global session list
    ///     (they just aren't laid out anymore); the user can re-split
    ///     into them via the "Split right" / "Split down" buttons.
    ///
    /// All external "jump to session" entry points (sidebar row tap,
    /// command palette, feed click, session strip) route through here
    /// — direct writes to `selectedSessionId` are reserved for
    /// in-pane operations where the target leaf is already on screen.
    func switchToSession(_ sessionId: UUID) {
        if let tree = paneTree, tree.contains(sessionId) {
            // Session already visible — just focus it.
            selectedSessionId = sessionId
            return
        }
        // Session lives outside the current split layout. Drop the
        // tree (no leaves are lost — those sessions remain in the
        // global list) and render the requested session full-bleed.
        paneTree = nil
        selectedSessionId = sessionId
    }

    /// True when the workspace is rendering more than one pane.
    var isSplitActive: Bool { paneTree != nil }

    /// Number of visible panes — 1 in single-pane mode, otherwise the
    /// leaf count of the tree. The toolbar uses this to gate "add pane"
    /// at the 4-pane cap.
    var paneCount: Int {
        paneTree?.leafCount ?? (selectedSessionId == nil ? 0 : 1)
    }

    /// Whether the user can spawn another pane right now (cap = 4).
    var canAddPane: Bool { paneCount < 4 }

    /// Close THIS window's project — go back to the welcome window. Doesn't terminate
    /// any sessions; they remain alive in the global pool and can be reopened by
    /// re-picking the same project from Welcome.
    func closeProject() {
        // Persist current sidebar prefs so the next open of this project remembers them.
        if let path = projectRoot?.url.path {
            UserDefaults.standard.set(sidebarTab.rawValue,
                                       forKey: "dnp.mac.sidebar.tab.\(path)")
            UserDefaults.standard.set(sidebarExpanded,
                                       forKey: "dnp.mac.sidebar.expanded.\(path)")
        }
        // The window itself is closed by the View layer (calling `dismiss()`); we just
        // tear down per-workspace UI state here.
        projectRoot = nil
        openFiles.removeAll()
        activeFile = nil
    }

    // MARK: - Editor / file-open (kept simple — full file open routing stays on coord)

    func openFile(_ node: FileNode) {
        guard !node.isDirectory else { return }
        let entry = OpenFile(node: node, projectRoot: projectRoot?.url)
        if !openFiles.contains(where: { $0.id == entry.id }) {
            openFiles.append(entry)
        }
        activeFile = entry
        workspacePane = .editor(entry)
    }

    /// True if `url` points to a file Claude edited in this workspace, OR if `url` is
    /// a directory and any tracked edited file lives under it. Drives the file
    /// explorer's "modified" badge: not just the file's own row, but every ancestor
    /// folder that contains it (so a deeply-nested edit is still discoverable in a
    /// collapsed tree). Linear-time in `editedFilePaths.count`, which is fine — even
    /// long sessions rarely touch more than a few dozen files.
    func isEditedPath(_ url: URL, isDirectory: Bool) -> Bool {
        let target = url.standardizedFileURL.path
        if !isDirectory {
            return editedFilePaths.contains(target)
        }
        // Directory: match if any tracked file is `target/...`.
        let prefix = target.hasSuffix("/") ? target : target + "/"
        for p in editedFilePaths where p.hasPrefix(prefix) {
            return true
        }
        return false
    }
}
