import SwiftUI
import AppKit

/// Workspace pane for managing GitHub via the local `gh` CLI. Surfaced from the bottom-bar
/// "@user" pill and the (future) sidebar entry. Wraps the most-used `gh` commands behind
/// real buttons so the user can sign in / out, browse their repos, and open issues / PRs in
/// the system browser without leaving the app.
///
/// All command invocations go through `GitHubService.runCommand` (a synchronous shell-out to
/// `gh`). The pane runs everything off the main thread via `Task { @MainActor in ... }` and
/// renders progress where the call takes more than a beat.
struct GitHubPaneView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var status: GitHubService.Status = GitHubService.currentStatus()
    @State private var repos: [Repo] = []
    @State private var loadingRepos = false
    @State private var lastError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                authCard
                if status.signedIn {
                    repoCard
                }
                docsCard
                Spacer(minLength: 32)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacTheme.groupedBackground)
        .onAppear {
            // Force a fresh probe whenever this pane comes into view — auth state can change
            // between visits (e.g. user signed in via `gh auth login` in another terminal).
            status = GitHubService.currentStatus()
            if status.signedIn { loadRepos() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(MacTheme.accent)
                .frame(width: 56, height: 56, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub").font(.title.bold()).foregroundStyle(MacTheme.textPrimary)
                Text("Manage your GitHub authentication and browse repos via the `gh` CLI.")
                    .font(.callout).foregroundStyle(MacTheme.textSecondary)
            }
            Spacer()
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .help("Refresh")
        }
    }

    // MARK: - Auth card

    private var authCard: some View {
        SettingsCard(title: "Authentication", icon: "person.badge.key") {
            if !status.isInstalled {
                missingGhBlock
            } else if status.signedIn {
                signedInBlock
            } else {
                signedOutBlock
            }
            if let err = lastError {
                Divider().background(MacTheme.border).padding(.vertical, 4)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MacTheme.danger)
                    Text(err).font(.caption).foregroundStyle(MacTheme.danger)
                    Spacer()
                }
            }
        }
    }

    private var missingGhBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("`gh` CLI not installed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(MacTheme.warning)
            Text("Claude Code's GitHub integrations (PR creation, issue search, etc.) need the official GitHub CLI. Install via Homebrew:")
                .font(.callout).foregroundStyle(MacTheme.textSecondary)
            Text("brew install gh")
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
            Button { openInBrowser("https://cli.github.com") } label: {
                Label("Install instructions", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
        }
    }

    private var signedInBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(MacTheme.success)
                    .frame(width: 36, height: 36)
                    .background(MacTheme.success.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in to \(status.host ?? "github.com")")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    if let user = status.user {
                        Text("@\(user)")
                            .font(.caption.monospaced())
                            .foregroundStyle(MacTheme.textSecondary)
                    }
                }
                Spacer()
                Button(role: .destructive) { signOut() } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.bordered)
            }
            if let scopes = status.scopes, !scopes.isEmpty {
                Divider().background(MacTheme.border).padding(.vertical, 2)
                detailRow("Token scopes", scopes, mono: true)
            }
            if let path = status.ghPath {
                detailRow("Binary", path, mono: true)
            }
        }
    }

    private var signedOutBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.fill.questionmark")
                    .font(.title2)
                    .foregroundStyle(MacTheme.warning)
                    .frame(width: 36, height: 36)
                    .background(MacTheme.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not signed in")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("Claude can use `gh` for read-only commands, but PR creation and gists require auth.")
                        .font(.caption).foregroundStyle(MacTheme.textTertiary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button { signInWeb() } label: {
                    Label("Sign in via Browser", systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)
                .tint(MacTheme.accent)

                Button { signInTerminal() } label: {
                    Label("Sign in via Terminal", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
            }
            Text("`gh auth login --web` opens GitHub in your browser. We launch it in a Terminal window so you can paste the device code if prompted.")
                .font(.caption2).foregroundStyle(MacTheme.textTertiary)
        }
    }

    // MARK: - Repos card

    private var repoCard: some View {
        SettingsCard(title: "Your repositories", icon: "books.vertical") {
            HStack(spacing: 10) {
                Button { loadRepos() } label: {
                    Label("Refresh repos", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Spacer()
                if loadingRepos {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Each project opens in its own window — picking a repo here clones it (if needed) and launches a fresh IDE for it without disturbing the project you're in now.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().background(MacTheme.border).padding(.vertical, 4)
            if repos.isEmpty && !loadingRepos {
                Text("No repos loaded yet. Click Refresh repos.")
                    .font(.caption).foregroundStyle(MacTheme.textTertiary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(repos) { repo in repoRow(repo) }
                }
            }
        }
    }

    private func repoRow(_ repo: Repo) -> some View {
        let isCurrent = workspace.projectGitHub?.nameWithOwner == repo.nameWithOwner
        return HStack(spacing: 10) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .foregroundStyle(repo.isPrivate ? MacTheme.warning : MacTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.nameWithOwner)
                        .font(.callout)
                        .foregroundStyle(MacTheme.textPrimary)
                    if isCurrent {
                        Text("Current project")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MacTheme.success)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(MacTheme.success.opacity(0.15), in: Capsule())
                    }
                }
                if !repo.description.isEmpty {
                    Text(repo.description)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !isCurrent {
                Button {
                    Task { @MainActor in
                        // Opens (or refocuses) a dedicated WorkspaceWindow for this
                        // repo. Cloning is silent on first adopt; the new window
                        // appears once `~/Developer/<repo>` is on disk. The current
                        // window is unaffected.
                        _ = await vm.adoptGitHubProject(nameWithOwner: repo.nameWithOwner)
                    }
                } label: {
                    Label("Open in new window", systemImage: "macwindow.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clone if needed and open this repo in its own IDE window")
            }
            Button { openInBrowser(repo.url) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open on github.com")
        }
        .padding(.vertical, 6)
        .overlay(Divider().opacity(0.3), alignment: .bottom)
    }

    // MARK: - Docs card

    private var docsCard: some View {
        SettingsCard(title: "References", icon: "book") {
            HStack {
                Link("`gh` CLI manual",
                     destination: URL(string: "https://cli.github.com/manual/")!)
                Spacer()
            }
            HStack {
                Link("Claude Code GitHub workflow",
                     destination: URL(string: "https://docs.claude.com/en/docs/claude-code/github-actions")!)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(MacTheme.textSecondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func refresh() {
        status = GitHubService.currentStatus()
        if status.signedIn { loadRepos() } else { repos = [] }
    }

    private func loadRepos() {
        guard status.signedIn else { return }
        loadingRepos = true
        lastError = nil
        Task.detached {
            // `gh repo list --limit 50 --json nameWithOwner,description,isPrivate,url`
            let result = GitHubService.runCommand([
                "repo", "list", "--limit", "50",
                "--json", "nameWithOwner,description,isPrivate,url"
            ])
            await MainActor.run {
                loadingRepos = false
                guard let result, result.exit == 0 else {
                    lastError = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                                 ?? "gh failed to run"
                    return
                }
                guard let data = result.stdout.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode([Repo].self, from: data) else {
                    lastError = "Couldn't parse `gh repo list` output"
                    return
                }
                repos = parsed
            }
        }
    }

    private func signOut() {
        Task.detached {
            _ = GitHubService.runCommand(["auth", "logout", "--hostname",
                                          status.host ?? "github.com",
                                          "--quiet"])
            await MainActor.run { refresh() }
        }
    }

    /// Sign-in flow #1 — `gh auth login --web` directly. Triggers `gh` to open a browser
    /// tab with a device-code form. We don't capture stdout here because the user will
    /// confirm via the browser; we just kick off the process.
    private func signInWeb() {
        guard let gh = status.ghPath ?? GitHubService.runCommand(["--version"])?.stdout else {
            lastError = "Couldn't locate `gh` on disk"; return
        }
        _ = gh   // gh path is only there if installed.
        Task.detached {
            _ = GitHubService.runCommand(["auth", "login", "--web",
                                          "--hostname", "github.com",
                                          "--git-protocol", "https"])
            await MainActor.run { refresh() }
        }
    }

    /// Sign-in flow #2 — open a Terminal window running `gh auth login` so the user can
    /// follow the device-code prompt interactively. Useful when the silent `--web` flow
    /// runs into a token-paste step.
    private func signInTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "gh auth login --hostname github.com --git-protocol https --web"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var err: NSDictionary?
            appleScript.executeAndReturnError(&err)
            if let e = err { lastError = "AppleScript: \(e)" }
        }
    }

    private func openInBrowser(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

/// Lightweight model decoded from `gh repo list --json ...`.
private struct Repo: Codable, Identifiable {
    let nameWithOwner: String
    let description: String
    let isPrivate: Bool
    let url: String
    var id: String { nameWithOwner }

    private enum CodingKeys: String, CodingKey {
        case nameWithOwner, description, isPrivate, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nameWithOwner = try c.decode(String.self, forKey: .nameWithOwner)
        description   = (try? c.decode(String.self, forKey: .description)) ?? ""
        isPrivate     = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
        url           = (try? c.decode(String.self, forKey: .url)) ?? ""
    }
}
