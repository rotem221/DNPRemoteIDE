import SwiftUI
import AppKit

/// First screen the user sees when no project is open. Replaces the previous "Open
/// Folder…" empty state with a Cursor-style picker:
///   - Logo + product title at the top
///   - Three primary entry buttons: Open Project / Clone from Git / Connect to SSH
///   - Recent-projects rail below — clicking a row reopens that workspace
///
/// Renders in place of the IDE shell while `vm.projectRoot == nil`. Once the user picks
/// (or successfully completes a clone / SSH connect), the same view model's
/// `openProject(at:)` swaps in the IDE.
struct WelcomeView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @StateObject private var recents = RecentProjectsService.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var presentation: Presentation = .none
    /// Sheet for browsing every recent project — the welcome rail itself
    /// only shows the most recent four (see `welcomeRecentsLimit`).
    @State private var showingAllRecents = false

    /// How many recents the inline welcome rail shows. Anything past this
    /// is reachable via the "View all (N)" footer button which opens the
    /// `AllRecentsSheet`.
    private let welcomeRecentsLimit = 4

    enum Presentation: Identifiable, Equatable {
        case none
        case cloneFromGit
        case connectToSSH
        var id: String {
            switch self {
            case .none:          return "none"
            case .cloneFromGit:  return "git"
            case .connectToSSH:  return "ssh"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Upper content area, vertically centered. The welcome page
            // never scrolls — the recents rail is capped at 4 (with the
            // overflow living in the "View all" sheet) so the worst-case
            // intrinsic height is bounded and fits inside the minimum
            // window size set on the welcome scene. Centering is just two
            // `Spacer`s wrapping the content stack; if the window is
            // shrunk below the content's intrinsic height, content gets
            // visually clipped rather than producing a scrollbar.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 28) {
                    header
                    actionGrid
                    if !recents.entries.isEmpty {
                        recentsSection
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.groupedBackground)
        .sheet(isPresented: $showingAllRecents) {
            AllRecentsSheet(
                onSelect: { entry in
                    showingAllRecents = false
                    reopen(entry)
                },
                onDismiss: { showingAllRecents = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: WelcomeWindowOpener.notification)) { _ in
            // Dock menu's "New Window" — bring welcome forward if it's already open
            // (this listener doesn't fire when the window is closed; the AppDelegate
            // dock handler also calls `openWindow(id: "welcome")` via a SwiftUI route
            // for the closed case).
            NSApp.activate(ignoringOtherApps: true)
        }
        // Crash-recovery channel: at launch, `MacAppViewModel.restoreOpenProjectWindowsIfNeeded`
        // posts `ProjectWindowOpener.notification` for every project window
        // that was on screen during the previous run. No `WorkspaceWindow`
        // exists yet at launch, so we forward the post here instead — the
        // welcome window IS up at app launch and has the SwiftUI
        // `openWindow` action available. Without this listener, restored
        // project URLs were being dropped on the floor.
        .onReceive(NotificationCenter.default.publisher(for: ProjectWindowOpener.notification)) { note in
            guard let url = note.object as? URL else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "project", value: url.standardizedFileURL)
        }
        .sheet(isPresented: cloneSheetBinding) { CloneFromGitSheet(onComplete: { url in
            presentation = .none
            if let url { focusOrOpenProjectWindow(url: url) }
        }) }
        .sheet(isPresented: sshSheetBinding) { ConnectToSSHSheet(onComplete: { recent in
            presentation = .none
            if let recent { reopen(recent) }
        }) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            // Logo — `WelcomeLogo` is a dual-asset imageset that picks the light or dark
            // PNG automatically based on the system appearance, so we don't need
            // `.template` rendering or a tint. Sized with a FIXED frame (not `maxWidth`)
            // so the wordmark renders at the same intended size regardless of how wide
            // the window is. The 360×80 box matches the artwork's ~4.95:1 aspect ratio
            // (rendered ≈360×73), and the min window width below guarantees the box
            // always fits.
            Image("WelcomeLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 360, height: 80)
            Text("Open a project to start working with Claude.")
                .font(.callout)
                .foregroundStyle(MacTheme.textSecondary)
        }
    }

    // MARK: - Action grid

    private var actionGrid: some View {
        HStack(spacing: 14) {
            WelcomeActionCard(
                icon: "folder",
                title: "Open Project",
                subtitle: "Pick a folder on this Mac"
            ) { openLocalProject() }

            WelcomeActionCard(
                icon: "arrow.down.circle",
                title: "Clone from Git",
                subtitle: "Clone a repository by URL"
            ) { presentation = .cloneFromGit }

            WelcomeActionCard(
                icon: "network",
                title: "Connect to SSH",
                subtitle: "Open a remote folder over SSH"
            ) { presentation = .connectToSSH }
        }
        .frame(maxWidth: 760)
    }

    // MARK: - Recents

    private var recentsSection: some View {
        // Snapshot of the trimmed list — ensures the rendered rows AND the
        // first/last-position calculation that drives row corner rounding
        // both reference the exact same slice.
        let visible = Array(recents.entries.prefix(welcomeRecentsLimit))
        let total = recents.entries.count
        let hasMore = total > welcomeRecentsLimit

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Projects")
                    .font(.headline)
                    .foregroundStyle(MacTheme.textPrimary)
                Spacer()
                Menu {
                    Button("Clear All", role: .destructive) {
                        RecentProjectsService.shared.clearAll()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MacTheme.textSecondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            // Card content: at most `welcomeRecentsLimit` rows, optionally
            // followed by a "View all (N)" footer button when there are
            // more recents that didn't fit. The footer lives INSIDE the
            // card so the card's rounded clip naturally rounds its bottom
            // corners; rows above keep their flat bottom (treated as
            // non-last by `RecentProjectRow`).
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                    recentRow(
                        entry: entry,
                        isFirst: index == 0,
                        // When the footer is present, no row is "last" —
                        // the footer button takes the bottom-rounded slot.
                        isLast: !hasMore && index == visible.count - 1
                    )
                    if index < visible.count - 1 || hasMore {
                        Divider().background(MacTheme.border.opacity(0.5))
                    }
                }
                if hasMore {
                    viewAllRow(total: total)
                }
            }
            .background(MacTheme.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Clip the entire card content (including row hover backgrounds
            // and row dividers) to the card's rounded shape, so nothing can
            // bleed past the rounded corners on the first / last row.
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MacTheme.border.opacity(0.6), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: 760)
    }

    /// Footer button rendered as the last row inside the recents card when
    /// there are more entries than the welcome rail shows. Visually mirrors
    /// `RecentProjectRow` so the card reads as one continuous list with a
    /// "see the rest" affordance pinned to the bottom.
    private func viewAllRow(total: Int) -> some View {
        ViewAllRecentsRow(total: total) { showingAllRecents = true }
    }

    private func recentRow(entry: RecentProject, isFirst: Bool, isLast: Bool) -> some View {
        RecentProjectRow(
            entry: entry,
            iconName: rowIcon(entry),
            subtitle: rowSubtitle(entry),
            relativeTimeString: entry.lastOpenedAt.map {
                Self.relativeFormatter.localizedString(for: $0, relativeTo: Date())
            },
            isFirst: isFirst,
            isLast: isLast,
            onTap: { reopen(entry) },
            onDelete: { RecentProjectsService.shared.remove(id: entry.id) }
        )
        .contextMenu {
            Button("Reveal in Finder") {
                if entry.kind != .ssh {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.path)])
                }
            }
            .disabled(entry.kind == .ssh)
            Divider()
            Button("Remove from Recents", role: .destructive) {
                RecentProjectsService.shared.remove(id: entry.id)
            }
        }
    }

    private func rowIcon(_ e: RecentProject) -> String {
        switch e.kind {
        case .local: return "folder.fill"
        case .clone: return "arrow.down.app.fill"
        case .ssh:   return "network"
        }
    }
    private func rowSubtitle(_ e: RecentProject) -> String {
        switch e.kind {
        case .local: return e.path
        case .clone: return e.gitURL ?? e.path
        case .ssh:
            let user = e.sshUser ?? "user"
            let host = e.sshHost ?? "host"
            let port = e.sshPort.map { ":\($0)" } ?? ""
            return "\(user)@\(host)\(port):\(e.path)"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    // MARK: - Actions

    private func openLocalProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Surfaces the "New Folder" button in the panel's toolbar so the
        // user can create a fresh project folder without leaving the
        // dialog. NSOpenPanel itself localises that button (and every
        // other built-in control — Cancel, Open, "Show Hidden Files",
        // sidebar headings) to match the system language automatically;
        // we only have to localise the strings WE set below.
        panel.canCreateDirectories = true
        panel.prompt = WelcomeStrings.openPanelPrompt
        panel.message = WelcomeStrings.openPanelMessage
        // Default to the user's home so they're not stranded in /Volumes
        // on first launch — every macOS install has a writable home dir.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            RecentProjectsService.shared.registerLocal(at: url)
            focusOrOpenProjectWindow(url: url)
        }
    }

    /// Single funnel for `openWindow(id: "project", value:)` from the Welcome scene.
    /// Also dismisses the welcome window itself per the user's request: "after picking
    /// a project, close this window." The user can reopen it later via the dock right-
    /// click menu's "New Window" — that path posts `WelcomeWindowOpener.notification`.
    private func focusOrOpenProjectWindow(url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "project", value: url.standardizedFileURL)
        // Brief delay before dismiss so the workspace window has time to register
        // (`WindowGroup(for:)` is async on first creation). Without the delay, on the
        // very first project pick after launch the welcome dismissed before the
        // workspace had been instantiated, leaving the user with zero windows for a
        // beat — disorienting. The 0.15s gap is below the perception threshold but
        // long enough for SwiftUI to bring the new window forward first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dismissWindow(id: "welcome")
        }
    }

    // MARK: - Status footer

    /// Bottom strip with the relevant runtime info — Bridge / paired iOS / Claude. Same
    /// `.bar` material macOS uses for status chrome (Finder, Mail), 28pt high, hairline
    /// across the top. Reads directly off the singleton VM so it tracks live state.
    private var statusFooter: some View {
        HStack(spacing: 14) {
            bridgePill
            divider
            pairedDevicesPill
            divider
            claudePill
            Spacer(minLength: 0)
            // Subtle "New project window" hint — same icon the dock menu uses, helps
            // the user discover that pickers are themselves windows.
            Text("Right-click the dock icon for more windows")
                .font(.caption2)
                .foregroundStyle(MacTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MacTheme.border.opacity(0.6)),
            alignment: .top
        )
    }

    private var divider: some View {
        Rectangle().fill(MacTheme.border.opacity(0.5))
            .frame(width: 1, height: 14)
    }

    private var bridgePill: some View {
        let online = (vm.bridgeStatus == .connected) && vm.bridge.port != nil
        let label: String = {
            switch vm.bridgeStatus {
            case .connected:    return "Bridge online" + (vm.bridge.port.map { " · :\($0)" } ?? "")
            case .connecting:   return "Bridge connecting…"
            case .degraded:     return "Bridge degraded"
            case .error:        return "Bridge error"
            case .offline:      return "Bridge offline"
            case .discovering:  return "Bridge discovering…"
            case .authenticating: return "Bridge authenticating…"
            }
        }()
        let tint: Color = {
            switch vm.bridgeStatus {
            case .connected: return MacTheme.success
            case .degraded:  return MacTheme.warning
            case .error:     return MacTheme.danger
            case .offline:   return MacTheme.textTertiary
            default:         return MacTheme.accent
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(online ? MacTheme.textSecondary : tint)
        }
        .help(online ? "Local bridge listening for paired iOS clients" : label)
    }

    /// Indicator for paired iOS devices — shows total paired count AND how many are
    /// currently connected (live bridge connection). Apple-native pattern: green when
    /// at least one is live, neutral when paired-but-offline, dimmed when none paired.
    private var pairedDevicesPill: some View {
        let pairedCount = vm.connectedDevices.count
        let liveCount   = vm.connectedDeviceIds.count
        let icon: String = {
            if liveCount   > 0 { return "iphone.gen3.radiowaves.left.and.right" }
            if pairedCount > 0 { return "iphone.gen3" }
            return "iphone.slash"
        }()
        let label: String = {
            if liveCount   > 0 {
                return liveCount == 1 ? "1 iPhone connected" : "\(liveCount) iPhones connected"
            }
            if pairedCount > 0 {
                return pairedCount == 1 ? "1 paired · offline" : "\(pairedCount) paired · offline"
            }
            return "No iPhone paired"
        }()
        let tint: Color = {
            if liveCount   > 0 { return MacTheme.success }
            if pairedCount > 0 { return MacTheme.textSecondary }
            return MacTheme.textTertiary
        }()
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(tint)
        }
        .help(label)
    }

    private var claudePill: some View {
        let v = vm.claude.detectedVersion
        return HStack(spacing: 5) {
            Image(systemName: v == nil ? "sparkles.slash" : "sparkles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(v == nil ? MacTheme.textTertiary : MacTheme.accent)
            Text(v.map { "Claude \($0)" } ?? "Claude not found")
                .font(.caption)
                .foregroundStyle(v == nil ? MacTheme.textTertiary : MacTheme.textSecondary)
        }
        .help(v == nil ? "Install Claude Code CLI to enable session launches"
                       : "Detected Claude Code at \(vm.claude.detectedPath ?? "?")")
    }

    /// Re-open a recent project by routing to the right path based on kind.
    /// - local / clone: just `openProject(at:)` on the local path
    /// - ssh: open IDE on the local home directory + auto-launch a terminal that
    ///   `ssh`'s into the host. Remote-workspace mode is a separate (deferred) effort.
    private func reopen(_ entry: RecentProject) {
        RecentProjectsService.shared.register(entry)

        switch entry.kind {
        case .local, .clone:
            let url = URL(fileURLWithPath: entry.path)
            if !FileManager.default.fileExists(atPath: url.path) {
                let alert = NSAlert()
                alert.messageText = "\(entry.displayName) is no longer at \(entry.path)."
                alert.informativeText = "The folder may have been moved or deleted."
                alert.addButton(withTitle: "Remove from Recents")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    RecentProjectsService.shared.remove(id: entry.id)
                }
                return
            }
            focusOrOpenProjectWindow(url: url)
        case .ssh:
            guard let host = entry.sshHost, let user = entry.sshUser else { return }
            let conn = SSHConnectionService.Connection(
                host: host, user: user, port: entry.sshPort ?? 22,
                identityFile: entry.sshIdentityFile,
                remotePath: entry.path,
                displayName: entry.displayName
            )
            // SSH opens a workspace window rooted at the user's home (local file tree)
            // and auto-launches a terminal that ssh's into the remote. Remote-workspace
            // mode (real remote file browser) is the next step in this stack.
            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            focusOrOpenProjectWindow(url: homeURL)
            Task { @MainActor in
                // Wait one runloop tick so the new window's WorkspaceController has
                // had a chance to register itself as `coord.activeWorkspace`.
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let ws = vm.activeWorkspace {
                    await vm.openSSHSession(connection: conn,
                                            displayName: entry.displayName, in: ws)
                }
            }
        }
    }

    // MARK: - Bindings

    private var cloneSheetBinding: Binding<Bool> {
        Binding(get: { presentation == .cloneFromGit },
                set: { if !$0 { presentation = .none } })
    }
    private var sshSheetBinding: Binding<Bool> {
        Binding(get: { presentation == .connectToSSH },
                set: { if !$0 { presentation = .none } })
    }
}

// MARK: - Clone-from-Git sheet

struct CloneFromGitSheet: View {
    var onComplete: (URL?) -> Void
    @State private var url: String = ""
    @State private var destination: URL = MacAppViewModel.defaultClonesRoot
    @State private var cloning = false
    @State private var errorLog: String? = nil

    /// GitHub repo list — populated from `gh repo list` when the user is signed in. Drives
    /// the autocomplete popover that drops out of the URL field. `nil` while still
    /// loading; empty array when signed out / `gh` not installed.
    @State private var ghRepos: [GitHubRepoSummary]? = nil
    @State private var ghLoadError: String? = nil
    @State private var showSuggestions: Bool = false
    @FocusState private var urlFieldFocused: Bool

    /// User picked a custom destination via "Save copy at…" — once non-nil, the action row
    /// shows ONLY the "Save copy" button so the choice is unambiguous. Clearing returns to
    /// the default split UI ("Open" + "Save copy at…").
    @State private var customDestinationPicked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone from Git").font(.title2.bold())
            Text("Paste a Git URL — HTTPS or SSH. Or pick from your GitHub repos when signed in via `gh`.")
                .font(.caption).foregroundStyle(MacTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            urlFieldWithSuggestions

            destinationRow

            if let log = errorLog, !log.isEmpty {
                ScrollView { Text(log).font(.system(.caption2, design: .monospaced)) }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(MacTheme.danger.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            actionRow
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadGitHubRepos() }
    }

    // MARK: - URL field + suggestions

    /// Text field with a true floating dropdown of GitHub repos. Behaviour the user asked
    /// for explicitly:
    ///   1. Dropdown appears only WHEN TYPING — focus alone doesn't pop it; an empty
    ///      query never shows suggestions either, so the user can paste a URL without a
    ///      list of unrelated repos appearing.
    ///   2. Picking a row dismisses the dropdown and fills the URL.
    ///   3. Clicking outside the popover (including on Cancel / Save copy / Open buttons)
    ///      dismisses it cleanly — `.popover` handles outside-tap automatically, no
    ///      manual outside-touch listener needed.
    ///   4. The popover renders ABOVE the sheet, in its own native window — the previous
    ///      `.overlay` form was clipped by the sheet's rounded corners and looked
    ///      half-translucent.
    @ViewBuilder
    private var urlFieldWithSuggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repository").font(.caption).foregroundStyle(MacTheme.textSecondary)
            TextField("https://github.com/owner/repo.git", text: $url)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .focused($urlFieldFocused)
                .onChange(of: url) { _, newValue in
                    // Only surface the dropdown when the user is actively typing AND
                    // there's something to filter against. Empty query → hidden.
                    let q = newValue.trimmingCharacters(in: .whitespaces)
                    showSuggestions = urlFieldFocused && !q.isEmpty && !filteredRepos.isEmpty
                }
                .onChange(of: urlFieldFocused) { _, focused in
                    // Lose focus → dismiss. We don't auto-show on gain focus (per request).
                    if !focused { showSuggestions = false }
                }
                .popover(isPresented: $showSuggestions,
                         attachmentAnchor: .rect(.bounds),
                         arrowEdge: .top) {
                    suggestionsList
                        .frame(width: 500)
                }
        }
    }

    private var filteredRepos: [GitHubRepoSummary] {
        guard let repos = ghRepos, !repos.isEmpty else { return [] }
        let q = url.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(repos.prefix(10)) }
        // Match either the full `owner/repo` or just the repo name; also keep the URL
        // path component if the user pasted a partial URL.
        return repos.filter { repo in
            let path = repo.nameWithOwner.lowercased()
            return path.contains(q) || repo.url.lowercased().contains(q)
        }.prefix(10).map { $0 }
    }

    /// Popover content. Native popover already provides its own opaque chrome + shadow +
    /// arrow, so we just render the rows — no extra background / outer card. The list is
    /// scrollable (capped at ~280pt tall) so a long repo list stays usable on small
    /// screens. Hover state highlights the row that's about to be picked.
    private var suggestionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredRepos, id: \.nameWithOwner) { repo in
                    SuggestionRow(repo: repo) {
                        let cloneURL = repo.url
                        if !cloneURL.isEmpty {
                            url = cloneURL.hasSuffix(".git") ? cloneURL : "\(cloneURL).git"
                        } else {
                            url = "https://github.com/\(repo.nameWithOwner).git"
                        }
                        // Picking dismisses the dropdown AND drops keyboard focus so the
                        // user lands on the action buttons next.
                        showSuggestions = false
                        urlFieldFocused = false
                    }
                    if repo.nameWithOwner != filteredRepos.last?.nameWithOwner {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    // MARK: - Destination row

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(customDestinationPicked ? "Saving copy to" : "Working directory")
                    .font(.caption).foregroundStyle(MacTheme.textSecondary)
                Spacer()
                if customDestinationPicked {
                    Button("Use default") {
                        destination = MacAppViewModel.defaultClonesRoot
                        customDestinationPicked = false
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Text(destination.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - Action row

    /// Two distinct paths for the user, matching the request:
    /// 1. **Open** — clone into the default `~/Developer/<repo>` and open immediately.
    /// 2. **Save copy at…** — pick a custom destination first, then clone into it.
    /// Once a custom destination has been picked, the row collapses to a single
    /// confirmation button so the choice is unambiguous.
    @ViewBuilder
    private var actionRow: some View {
        HStack {
            Spacer()
            Button("Cancel") { onComplete(nil) }
                .keyboardShortcut(.cancelAction)

            if customDestinationPicked {
                Button(cloning ? "Saving…" : "Save copy") { startClone() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cloning || url.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Save copy at…") { pickCustomDestination() }
                    .disabled(cloning || url.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(cloning ? "Cloning…" : "Open") { startClone() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cloning || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func pickCustomDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Same "New Folder" + locale-aware copy treatment as the main
        // Open Project picker — the user might want to make a fresh
        // parent directory like `~/Code` before cloning into it.
        panel.canCreateDirectories = true
        panel.prompt = WelcomeStrings.cloneDestinationPrompt
        panel.message = WelcomeStrings.cloneDestinationMessage
        if panel.runModal() == .OK, let chosen = panel.url {
            destination = chosen
            customDestinationPicked = true
        }
    }

    private func startClone() {
        cloning = true
        errorLog = nil
        let raw = url.trimmingCharacters(in: .whitespaces)
        let dest = destination
        Task { @MainActor in
            // Existing-clone short-circuit: if the destination's leaf folder already
            // exists AND looks like a git repo (`.git` present), skip the clone and just
            // open it. The previous flow handed this case to `git clone` which errored
            // out with "destination path already exists" — surfaced to the user as a
            // scary fatal red box. Practically the user just wants the repo open;
            // re-cloning over an existing checkout would be destructive anyway.
            let leaf = GitCloneService.repoNameFromURL(raw)
            let candidate = dest.appendingPathComponent(leaf, isDirectory: true)
            if FileManager.default.fileExists(atPath:
                candidate.appendingPathComponent(".git").path) {
                let entry = RecentProject(
                    id: "clone:\(candidate.path)",
                    displayName: candidate.lastPathComponent,
                    path: candidate.path,
                    kind: .clone,
                    sshHost: nil, sshUser: nil, sshPort: nil, sshIdentityFile: nil,
                    gitURL: raw
                )
                RecentProjectsService.shared.register(entry)
                cloning = false
                onComplete(candidate)
                return
            }

            let result = await GitCloneService.clone(url: raw, into: dest)
            cloning = false
            if result.success {
                let entry = RecentProject(
                    id: "clone:\(result.destination.path)",
                    displayName: result.destination.lastPathComponent,
                    path: result.destination.path,
                    kind: .clone,
                    sshHost: nil, sshUser: nil, sshPort: nil, sshIdentityFile: nil,
                    gitURL: raw
                )
                RecentProjectsService.shared.register(entry)
                onComplete(result.destination)
            } else {
                errorLog = result.log.isEmpty ? "Clone failed (no output)." : result.log
            }
        }
    }

    // MARK: - GitHub repo loader

    private func loadGitHubRepos() async {
        let status = GitHubService.currentStatus()
        guard status.signedIn else {
            ghRepos = []
            return
        }
        let repos = await Task.detached { () -> [GitHubRepoSummary]? in
            guard let result = GitHubService.runCommand([
                "repo", "list", "--limit", "100",
                "--json", "nameWithOwner,description,isPrivate,url"
            ]), result.exit == 0,
                let data = result.stdout.data(using: .utf8) else { return nil }
            // Lenient decode — `description` is sometimes missing on empty repos.
            struct Row: Codable {
                let nameWithOwner: String
                let description: String?
                let isPrivate: Bool?
                let url: String?
            }
            guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
            return rows.map {
                GitHubRepoSummary(
                    nameWithOwner: $0.nameWithOwner,
                    description: $0.description ?? "",
                    isPrivate: $0.isPrivate ?? false,
                    url: $0.url ?? ""
                )
            }
        }.value
        await MainActor.run {
            if let repos {
                self.ghRepos = repos
            } else {
                self.ghRepos = []
                self.ghLoadError = "Could not list GitHub repos via `gh`."
            }
        }
    }
}

// MARK: - Connect-to-SSH sheet

struct ConnectToSSHSheet: View {
    var onComplete: (RecentProject?) -> Void
    @State private var host: String = ""
    @State private var user: String = NSUserName()
    @State private var port: String = "22"
    @State private var identity: String = ""
    @State private var remotePath: String = ""
    @State private var probing = false
    @State private var probeLog: String? = nil
    @State private var probeOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to SSH").font(.title2.bold())
            Text("Save an SSH connection. Re-opening it from the welcome screen launches a terminal that automatically ssh'es into the host. (Remote file browsing isn't supported yet — coming in a future build.)")
                .font(.caption).foregroundStyle(MacTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                field("Host", text: $host, placeholder: "example.com")
                field("Username", text: $user, placeholder: NSUserName())
            }
            HStack(spacing: 10) {
                field("Port", text: $port, placeholder: "22")
                    .frame(width: 80)
                field("Identity file (optional)", text: $identity,
                      placeholder: "~/.ssh/id_ed25519")
                Button("…") { pickIdentity() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            field("Remote path (optional)", text: $remotePath,
                  placeholder: "/home/\(user.isEmpty ? "user" : user)/project")

            if let log = probeLog, !log.isEmpty {
                ScrollView { Text(log).font(.system(.caption2, design: .monospaced)) }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background((probeOK ? MacTheme.success : MacTheme.danger)
                        .opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button(probing ? "Testing…" : "Test connection") { probe() }
                    .buttonStyle(.bordered)
                    .disabled(probing || host.isEmpty || user.isEmpty)
                Spacer()
                Button("Cancel") { onComplete(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save & Open") { saveAndOpen() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || user.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(MacTheme.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
        }
    }

    private func pickIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let chosen = panel.url { identity = chosen.path }
    }

    private func makeConnection() -> SSHConnectionService.Connection {
        let portInt = Int(port.trimmingCharacters(in: .whitespaces)) ?? 22
        let trimmedIdentity = identity.trimmingCharacters(in: .whitespaces)
        return .init(
            host: host.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            port: portInt,
            identityFile: trimmedIdentity.isEmpty ? nil : trimmedIdentity,
            remotePath: remotePath.trimmingCharacters(in: .whitespaces),
            displayName: "\(user)@\(host)"
        )
    }

    private func probe() {
        probing = true
        probeLog = nil
        let conn = makeConnection()
        Task { @MainActor in
            let r = await SSHConnectionService.probe(conn)
            probing = false
            probeOK = r.ok
            probeLog = r.ok ? "Connection OK." : (r.log.isEmpty ? "Connection failed." : r.log)
        }
    }

    private func saveAndOpen() {
        let conn = makeConnection()
        let entry = RecentProject(
            id: "ssh:\(conn.user)@\(conn.host):\(conn.port):\(conn.remotePath)",
            displayName: "\(conn.user)@\(conn.host)",
            path: conn.remotePath,
            kind: .ssh,
            sshHost: conn.host,
            sshUser: conn.user,
            sshPort: conn.port,
            sshIdentityFile: conn.identityFile,
            gitURL: nil
        )
        RecentProjectsService.shared.register(entry)
        onComplete(entry)
    }
}

/// One row inside the GitHub-repos popover. Pulled out into its own struct so the hover
/// state lives per-row (a single `@State var hovering` on the list would highlight the
/// wrong row when the user moves between adjacent items in the same render pass).
/// One row in the Welcome scene's Recent Projects list. Pulled into its own struct so
/// each row owns its own `@State var hovering` — a single hover state on the parent
/// would highlight + reveal the delete button on the wrong row when the cursor moves
/// between adjacent items in the same render pass.
///
/// Behaviour:
///   • Tap anywhere on the row body → reopens (or refocuses) the project window.
///   • Hover → reveals an `xmark.circle.fill` button on the right that, on click,
///     removes the entry from `RecentProjectsService` (NOT the project itself — just
///     drops it from the list).
///   • The delete button has its own hit-testing so a hover-tap on it doesn't also
///     trigger the row's reopen action.
private struct RecentProjectRow: View {
    let entry: RecentProject
    let iconName: String
    let subtitle: String
    let relativeTimeString: String?
    let isFirst: Bool
    let isLast: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    /// Hover fill matches the parent card's 12pt corners only on the edges
    /// the row actually meets (top for the first row, bottom for the last).
    /// Middle rows render fully square so the fill is flush with the card
    /// edges and adjacent dividers — no perceived rounding on the sides.
    private var hoverShape: UnevenRoundedRectangle {
        let r: CGFloat = 12
        return UnevenRoundedRectangle(
            topLeadingRadius:     isFirst ? r : 0,
            bottomLeadingRadius:  isLast  ? r : 0,
            bottomTrailingRadius: isLast  ? r : 0,
            topTrailingRadius:    isFirst ? r : 0,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            // The reopen button — covers the whole row.
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.callout.weight(.regular))
                        .foregroundStyle(MacTheme.textSecondary)
                        .frame(width: 22, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(MacTheme.textPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(MacTheme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    // Reserve space for the trailing zone — the timestamp lives there
                    // when not hovering, the delete button slots over it on hover.
                    if let time = relativeTimeString, !hovering {
                        Text(time)
                            .font(.caption)
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                    // Trailing slot is sized so the delete button doesn't shift the
                    // text when it appears.
                    Color.clear.frame(width: 26, height: 1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Edge-to-edge hover fill. Corner radii are applied per-row
                // via UnevenRoundedRectangle so first/last rows hug the
                // card's 12pt curve while middle rows stay perfectly square.
                .background(
                    hoverShape.fill(hovering ? MacTheme.surfaceAlt.opacity(0.55) : Color.clear)
                )
            }
            .buttonStyle(.plain)

            // Delete button — overlay so its tap doesn't bubble to the parent button.
            HStack {
                Spacer()
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(MacTheme.textTertiary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Recents")
                    .padding(.trailing, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One of the three primary entry buttons on the welcome page (Open Project /
/// Clone from Git / Connect to SSH). Extracted into its own `View` so each
/// card owns a per-instance `@State var hovering` flag — a single hover flag
/// on the parent `actionGrid` would highlight all three at once. The hover
/// treatment mirrors what Cursor / Xcode do: a slight lift, a brighter card
/// fill, and a more visible border, with a short ease-out animation so the
/// transition reads as material rather than a flash.
private struct WelcomeActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(MacTheme.textPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(MacTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? MacTheme.surfaceAlt : MacTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        MacTheme.border.opacity(hovering ? 1.0 : 0.6),
                        lineWidth: hovering ? 0.8 : 0.5
                    )
            )
            .shadow(
                color: .black.opacity(hovering ? 0.18 : 0),
                radius: hovering ? 10 : 0,
                y: hovering ? 3 : 0
            )
            .scaleEffect(hovering ? 1.012 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Footer row inside the recents card. Reads as "View all 23 projects" with
/// a small grid icon and a chevron, sized to match `RecentProjectRow` so the
/// card looks like a single continuous list. Hover follows the same edge-
/// to-edge fill rule, with the bottom corners rounded since this is always
/// the last row when present.
private struct ViewAllRecentsRow: View {
    let total: Int
    let onTap: () -> Void
    @State private var hovering = false

    private var hoverShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 12,
            bottomTrailingRadius: 12,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.callout.weight(.regular))
                    .foregroundStyle(MacTheme.textSecondary)
                    .frame(width: 22, alignment: .center)
                Text("View all \(total) projects")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacTheme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                hoverShape.fill(hovering ? MacTheme.surfaceAlt.opacity(0.55) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Modal sheet listing every recent project in a scrollable card. Reuses
/// `RecentProjectRow` so the look is identical to the welcome rail; tapping
/// any row picks that project (the parent dismisses the sheet and reopens
/// the workspace via `reopen(_:)`).
private struct AllRecentsSheet: View {
    @StateObject private var recents = RecentProjectsService.shared
    let onSelect: (RecentProject) -> Void
    let onDismiss: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header bar — title, count, close.
            HStack(spacing: 12) {
                Text("Recent Projects")
                    .font(.headline)
                    .foregroundStyle(MacTheme.textPrimary)
                Text("\(recents.entries.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacTheme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(MacTheme.surfaceAlt.opacity(0.6),
                                in: Capsule(style: .continuous))
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(MacTheme.border.opacity(0.6)),
                alignment: .bottom
            )

            // Scrollable card with every recent. Identical row chrome to the
            // welcome rail, just with no truncation and a real scroll bar.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(Array(recents.entries.enumerated()), id: \.element.id) { index, entry in
                        RecentProjectRow(
                            entry: entry,
                            iconName: rowIcon(entry),
                            subtitle: rowSubtitle(entry),
                            relativeTimeString: entry.lastOpenedAt.map {
                                Self.relativeFormatter.localizedString(for: $0, relativeTo: Date())
                            },
                            isFirst: index == 0,
                            isLast: index == recents.entries.count - 1,
                            onTap: { onSelect(entry) },
                            onDelete: { RecentProjectsService.shared.remove(id: entry.id) }
                        )
                        if entry.id != recents.entries.last?.id {
                            Divider().background(MacTheme.border.opacity(0.5))
                        }
                    }
                }
                .background(MacTheme.card,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(MacTheme.border.opacity(0.6), lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            // Footer with "Clear All" — destructive action lives down here
            // so the user has to deliberately reach for it.
            HStack {
                Button(role: .destructive) {
                    RecentProjectsService.shared.clearAll()
                    onDismiss()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(MacTheme.danger)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(MacTheme.border.opacity(0.6)),
                alignment: .top
            )
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 820,
               minHeight: 460, idealHeight: 560, maxHeight: 720)
        .background(MacTheme.groupedBackground)
    }

    // Mirrors the helpers on WelcomeView so the sheet is self-contained
    // and doesn't need the parent's private methods.
    private func rowIcon(_ e: RecentProject) -> String {
        switch e.kind {
        case .local: return "folder.fill"
        case .clone: return "arrow.down.app.fill"
        case .ssh:   return "network"
        }
    }

    private func rowSubtitle(_ e: RecentProject) -> String {
        switch e.kind {
        case .local, .clone: return e.path
        case .ssh:
            if let user = e.sshUser, let host = e.sshHost {
                return "\(user)@\(host):\(e.path)"
            }
            return e.path
        }
    }
}

private struct SuggestionRow: View {
    let repo: GitHubRepoSummary
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                    .font(.caption)
                    .foregroundStyle(MacTheme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.nameWithOwner)
                        .font(.callout.monospaced())
                        .foregroundStyle(MacTheme.textPrimary)
                        .lineLimit(1)
                    if !repo.description.isEmpty {
                        Text(repo.description)
                            .font(.caption2)
                            .foregroundStyle(MacTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? MacTheme.accent.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Locale-aware strings used by the Welcome scene's NSOpenPanel calls.
/// NSOpenPanel localises its built-in chrome (Cancel, Open, "New Folder",
/// sidebar headings, "Show Hidden Files", etc.) automatically based on the
/// macOS system language — but the `prompt` / `message` fields the caller
/// sets are NOT auto-localised, they're shown verbatim. So we detect the
/// system language here and return Hebrew or English variants accordingly.
/// Adding a third language later is a one-line `case` addition; if a
/// future codebase moves to `String(localized:)` + `.xcstrings` this whole
/// helper can be deleted in one pass.
enum WelcomeStrings {
    /// True when the user has set their macOS system language to Hebrew.
    /// `Locale.current.language.languageCode` returns the ISO-639-1 code of
    /// the user's primary preferred language as resolved by the system.
    private static var isHebrew: Bool {
        Locale.current.language.languageCode?.identifier == "he"
    }

    /// Default-button label for the Open Project panel.
    static var openPanelPrompt: String {
        isHebrew ? "פתח פרויקט" : "Open Project"
    }

    /// Banner message shown above the file list in the Open Project panel.
    static var openPanelMessage: String {
        isHebrew
            ? "בחר תיקייה לפתיחה כפרויקט. ניתן ליצור תיקייה חדשה בעזרת הכפתור “תיקייה חדשה”."
            : "Choose a folder to open as a project. Use “New Folder” to create one."
    }

    /// Default-button label for the Clone-from-Git destination picker.
    static var cloneDestinationPrompt: String {
        isHebrew ? "בחר" : "Choose"
    }

    /// Banner message for the Clone-from-Git destination picker.
    static var cloneDestinationMessage: String {
        isHebrew
            ? "בחר תיקיית-אם — שם הפרויקט יהפוך לתיקייה הפנימית שתיווצר."
            : "Pick the parent directory — the repo's name will be the leaf folder."
    }
}
