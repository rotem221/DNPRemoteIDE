import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileExplorerView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var query: String = ""
    @State private var refreshTick = 0   // bump to force OutlineGroup to re-evaluate children

    var body: some View {
        SidebarPanel(
            title: workspace.projectRootName ?? "Files",
            icon: workspace.projectGitHub != nil ? "chevron.left.forwardslash.chevron.right" : "folder.fill",
            trailing: {
                Menu {
                    // "Open Folder…" and "Close Folder" deliberately removed — see
                    // `architecture_mac_multi_window` memory: each window is bound to
                    // its picked project. To work on another project the user goes
                    // back to the Welcome window. This menu is project-scoped only:
                    // refresh the tree, jump to GitHub.
                    if workspace.projectRoot != nil {
                        Button("Refresh") { vm.refreshProjectTree(); refreshTick += 1 }
                        if let gh = workspace.projectGitHub, let url = gh.webURL {
                            Divider()
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open on github.com", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            },
            content: {
                if let root = workspace.projectRoot {
                    VStack(alignment: .leading, spacing: 0) {
                        if workspace.projectGitHub != nil {
                            githubChip
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            Divider().background(MacTheme.border.opacity(0.5))
                        }
                        searchBar
                        Divider().background(MacTheme.border.opacity(0.5))
                        tree(root: root)
                    }
                } else {
                    emptyState
                }
            }
        )
    }

    /// Pill shown directly under the title when the project is GitHub-backed. Surfaces the
    /// `owner/repo` slug + the current branch as a chip; tapping the branch chip opens a
    /// menu that lets the user `git checkout` any local branch in one click.
    private var githubChip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MacTheme.accent)
                Text(workspace.projectGitHub?.nameWithOwner ?? "")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(MacTheme.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(MacTheme.accent.opacity(0.3), lineWidth: 0.5))

            Spacer(minLength: 0)

            branchMenu
        }
    }

    /// Branch picker chip — defers to `BranchMenu` which loads `git branch` on a
    /// detached Task. The previous form ran `GitHubProjectInfo.localBranches(at:)`
    /// synchronously inside `Menu`'s content closure; that closure is evaluated as
    /// part of SwiftUI's view-update cycle, and a synchronous `Process +
    /// waitUntilExit` from there spins the runloop, re-enters AttributeGraph, and
    /// crashes with `EXC_BAD_ACCESS` (`AttributeGraph: cycle detected`). Same fix
    /// already documented for `GitHubProjectInfo.detect` in `WorkspaceController`.
    private var branchMenu: some View {
        BranchMenu(
            projectURL: workspace.projectRoot?.url,
            currentBranch: workspace.projectGitHub?.currentBranch,
            onCheckout: { branch in
                guard let root = workspace.projectRoot?.url else { return }
                Task.detached(priority: .userInitiated) {
                    let result = GitHubProjectInfo.checkout(branch: branch, at: root)
                    guard result.success else { return }
                    // Re-detect on a background queue too — `detect` shells out.
                    let info = GitHubProjectInfo.detect(at: root)
                    await MainActor.run {
                        workspace.projectGitHub = info
                        vm.refreshProjectTree()
                    }
                }
            }
        )
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(MacTheme.textTertiary)
            TextField("Filter…", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(MacTheme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        // Pin to 32pt so the divider beneath the filter lines up with the divider
        // beneath the workspace's `EditorTabBarView` (each tab cell renders at
        // ~32pt). Without the explicit height, the .body-sized TextField made this
        // row a few points taller than the tab strip, leaving the two hairlines
        // visibly mismatched at the sidebar/workspace seam.
        .frame(height: 32)
    }

    // MARK: - Tree

    private func tree(root: FileNode) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FileTreeRow(node: root, depth: 0, query: query)
                    .id(refreshTick)
            }
            .padding(.vertical, 4)
        }
    }

    /// Empty state — only ever rendered if a workspace window somehow has a nil
    /// `projectRoot` (shouldn't happen in normal multi-window flow since `WindowGroup
    /// (for: URL.self)` requires a URL to even instantiate the workspace). No "Open
    /// Folder…" CTA — switching projects from inside a workspace window violates the
    /// "window = project" contract; the user picks projects from Welcome instead.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(MacTheme.textTertiary)
            Text("No folder open").foregroundStyle(MacTheme.textSecondary)
            Text("Pick a project from the Welcome window.")
                .font(.caption)
                .foregroundStyle(MacTheme.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }
}

// MARK: - Tree row (recursive)

struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    let query: String
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var expanded: Bool
    @State private var isHovering: Bool = false

    init(node: FileNode, depth: Int, query: String) {
        self.node = node
        self.depth = depth
        self.query = query
        // Auto-expand the root
        _expanded = State(initialValue: depth == 0)
    }

    var body: some View {
        let visible = filteredChildren()
        VStack(alignment: .leading, spacing: 0) {
            if !(depth == 0 && node.name.hasSuffix("/")) {
                row
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1) { handleTap() }
                    .onHover { hovering in
                        // Only flip the @State on a real change so SwiftUI doesn't
                        // schedule needless redraws as NSTrackingArea fires repeats.
                        if hovering != isHovering { isHovering = hovering }
                    }
                    .contextMenu { contextMenu }
            }
            if expanded, let kids = visible {
                ForEach(kids) { child in
                    FileTreeRow(node: child, depth: depth + 1, query: query)
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !node.isDirectory {
            Button { workspace.openFile(node) } label: { Label("Open", systemImage: "doc.text") }
            Divider()
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button { NSWorkspace.shared.open(node.url) } label: {
            Label("Open with default app", systemImage: "arrow.up.right.square")
        }
        Button { copyPath() } label: {
            Label("Copy path", systemImage: "doc.on.doc")
        }
        Button { copyRelativePath() } label: {
            Label("Copy relative path", systemImage: "doc.on.doc.fill")
        }
        if node.isDirectory {
            Divider()
            // ("Set as project root" deliberately removed: each window is bound to its
            // picked project; re-rooting the explorer mid-window would desync the rest
            // of the workspace state. To work on a different project, pick it from the
            // Welcome window — it opens in its own workspace window.)
            Button { createNewFile() } label: {
                Label("New file…", systemImage: "doc.badge.plus")
            }
            Button { createNewFolder() } label: {
                Label("New folder…", systemImage: "folder.badge.plus")
            }
            Button { vm.refreshProjectTree() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        if node.isDirectory, let project = workspace.projectRoot, node.url == project.url {
            // Don't allow deleting the project root.
        } else {
            Divider()
            Button(role: .destructive) { trash() } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }
    private func copyRelativePath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let root = workspace.projectRoot?.url.path, node.url.path.hasPrefix(root) {
            pb.setString(String(node.url.path.dropFirst(root.count + 1)), forType: .string)
        } else {
            pb.setString(node.url.path, forType: .string)
        }
    }
    private func createNewFile() {
        guard node.isDirectory else { return }
        var name = "untitled.txt"
        var i = 2
        while FileManager.default.fileExists(atPath: node.url.appendingPathComponent(name).path) {
            name = "untitled-\(i).txt"; i += 1
        }
        let url = node.url.appendingPathComponent(name)
        try? Data().write(to: url)
        vm.refreshProjectTree()
    }
    private func createNewFolder() {
        guard node.isDirectory else { return }
        var name = "New Folder"
        var i = 2
        while FileManager.default.fileExists(atPath: node.url.appendingPathComponent(name).path) {
            name = "New Folder \(i)"; i += 1
        }
        let url = node.url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        vm.refreshProjectTree()
    }
    private func trash() {
        try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        // If we trashed the active file, drop it from the open tabs.
        if let f = workspace.activeFile, f.node.url == node.url { workspace.closeFile(f) }
        vm.refreshProjectTree()
    }

    private var row: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
            if node.isDirectory {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 14)
                    .foregroundStyle(MacTheme.textTertiary)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Image(systemName: node.iconName)
                .font(.body)
                .frame(width: 22)
                .foregroundStyle(iconColor)
            Text(node.name)
                .font(.body)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Edit-status dot — visible on the file itself AND every ancestor folder
            // that contains a touched file. Solid orange so it reads from across the
            // pane without competing with the selection highlight.
            if isEdited {
                Circle()
                    .fill(MacTheme.warning)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 2)
                    .accessibilityLabel(node.isDirectory
                        ? "Contains modified files"
                        : "Modified by Claude")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground)
    }

    private var isSelected: Bool {
        workspace.activeFile?.node.url == node.url
    }

    /// True if Claude touched this file in the current workspace (or, for folders, if
    /// Claude touched any descendant). Powers the orange dot + accent-tinted name.
    private var isEdited: Bool {
        workspace.isEditedPath(node.url, isDirectory: node.isDirectory)
    }

    /// Row background priority (most specific wins):
    /// 1. Selected: solid surface highlight so the active file reads first.
    /// 2. Hovering: a soft accent-blue glow (Xcode/VS Code/Cursor pattern). Using a
    ///    DIFFERENT colour family than `surfaceAlt` makes the hover state legible
    ///    without competing visually with the selection — the previous form
    ///    (faded surfaceAlt at 28% vs 50%) was almost invisible on dark backgrounds,
    ///    which is what the user flagged.
    /// 3. Default: transparent so the side panel's surface shows through.
    private var rowBackground: Color {
        if isSelected { return MacTheme.surfaceAlt.opacity(0.55) }
        if isHovering { return MacTheme.accent.opacity(0.14) }
        return .clear
    }

    private var iconColor: Color {
        if node.isDirectory { return MacTheme.accent }
        if isEdited         { return MacTheme.warning }
        return MacTheme.textSecondary
    }

    private var textColor: Color {
        // Edited path → warm accent for both the file and every containing folder, so
        // the user can trace the modified file by following the tinted breadcrumb.
        if isEdited { return MacTheme.warning }
        if isSelected { return MacTheme.textPrimary }
        return node.isDirectory ? MacTheme.textPrimary : MacTheme.textSecondary
    }

    private func handleTap() {
        if node.isDirectory {
            withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
        } else {
            workspace.openFile(node)
        }
    }

    /// Filter children when there's a query. Empty query → return as-is.
    private func filteredChildren() -> [FileNode]? {
        guard let kids = node.children else { return nil }
        guard !query.isEmpty else { return kids }
        let q = query.lowercased()
        return kids.compactMap { child in
            if child.name.lowercased().contains(q) { return child }
            // For directories, keep them if any descendant matches.
            if child.isDirectory, descendantsMatch(child, query: q) { return child }
            return nil
        }
    }

    private func descendantsMatch(_ node: FileNode, query: String) -> Bool {
        guard let kids = node.children else { return false }
        for child in kids {
            if child.name.lowercased().contains(query) { return true }
            if child.isDirectory, descendantsMatch(child, query: query) { return true }
        }
        return false
    }
}

// MARK: - Branch picker (async-loaded)

/// Branch picker chip + menu. Owns the `[String]` cache of `git branch` so the
/// expensive `Process + waitUntilExit` shell-out is performed on a detached Task
/// — never inside SwiftUI's view-update cycle. The trigger pattern (`.task(id:)`)
/// auto-reloads when the project URL or the current branch changes (e.g. after a
/// successful checkout). When `branches` is empty we still render the chip so the
/// user can see the current branch label.
private struct BranchMenu: View {
    let projectURL: URL?
    let currentBranch: String?
    let onCheckout: (String) -> Void

    @State private var branches: [String] = []
    @State private var loading: Bool = false

    var body: some View {
        Menu {
            if loading && branches.isEmpty {
                Text("Loading branches…").foregroundStyle(.secondary)
            } else if branches.isEmpty {
                Text("No local branches").foregroundStyle(.secondary)
            } else {
                ForEach(branches, id: \.self) { branch in
                    Button {
                        onCheckout(branch)
                    } label: {
                        HStack {
                            if branch == currentBranch { Image(systemName: "checkmark") }
                            Text(branch)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2.weight(.semibold))
                Text(currentBranch ?? "—")
                    .font(.caption.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(MacTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(MacTheme.surfaceAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(MacTheme.border.opacity(0.5), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Reload whenever the project URL changes OR the current branch changes
        // (which happens after a successful checkout). The id tuple is a String
        // because `.task(id:)` only wants Hashable — URL? and String? both qualify
        // when joined into one string key.
        .task(id: "\(projectURL?.path ?? "")|\(currentBranch ?? "")") {
            await load()
        }
    }

    private func load() async {
        guard let url = projectURL else {
            branches = []
            return
        }
        loading = true
        defer { loading = false }
        // Detached so the synchronous Process spin runs OFF the main actor — no
        // chance of re-entering SwiftUI's update cycle.
        let result = await Task.detached(priority: .userInitiated) {
            GitHubProjectInfo.localBranches(at: url)
        }.value
        branches = result
    }
}
