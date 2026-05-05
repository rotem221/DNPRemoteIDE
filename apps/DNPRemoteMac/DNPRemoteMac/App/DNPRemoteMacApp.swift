import SwiftUI
import AppKit

@main
struct DNPRemoteMacApp: App {
    /// The coordinator is a process-wide singleton (see `MacAppViewModel.shared`) so
    /// every window — Welcome and per-project workspace — observes the same global
    /// state pools (sessions, terminals, feed, paired devices, bridge).
    private let coord = MacAppViewModel.shared
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Welcome window — the project picker. Opens at first launch and stays available
        // via "File → New Welcome Window" (or close-all-projects → Welcome reopens).
        // Bootstrap intentionally NO LONGER runs from this view's `.task` — it now runs
        // from `MacAppDelegate.applicationDidFinishLaunching` so the bridge listener
        // comes up at app launch regardless of which window is open. Tying it to the
        // Welcome window meant that with `MenuBarExtra` (which can grab focus before
        // any window appears), the bridge could remain unstarted, leading to iPhone
        // pairing attempts hitting "Connection refused" because no port was bound.
        Window("DNP Remote", id: "welcome") {
            WelcomeView()
                .environmentObject(coord)
                // Minimum is sized so the three entry cards (each ~244pt wide
                // inside a 760pt action-grid container) plus the 48pt page
                // gutters and 360pt logo all fit without squeezing. Below
                // ~880×640 the content compresses and the layout no longer
                // reads cleanly — capping the minimum here prevents the
                // user from accidentally dragging the window down to a
                // size that hurts legibility.
                .frame(minWidth: 880, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        // Hide the "DNP Remote" title text from the welcome window's title
        // bar — the brand wordmark inside the WelcomeView body is already
        // the user-facing branding, so repeating the name above it is just
        // redundant chrome. `.hiddenTitleBar` keeps the title bar present
        // (so the user can still drag the window from the top edge and the
        // traffic-light buttons stay where macOS users expect them) but
        // erases the title text and removes the title bar's separator
        // line. The window-id "welcome" is what SwiftUI uses for routing,
        // so the still-set `Window("DNP Remote", id:)` value above is for
        // accessibility / Window menu only — not visible chrome.
        .windowStyle(.hiddenTitleBar)

        // One window per project URL. SwiftUI's `WindowGroup(for:)` keys windows off the
        // value passed to `openWindow(id:value:)` — calling it with a URL that's already
        // open just brings that window to the front instead of creating a duplicate, so
        // re-picking the same project from the dock menu / Welcome / File menu reuses
        // the existing window. iOS sees a flat list of all sessions across all windows;
        // each window only renders the subset whose `projectPath` matches its URL.
        WindowGroup("Project", id: "project", for: URL.self) { $url in
            if let url {
                WorkspaceWindow(projectURL: url)
                    .environmentObject(coord)
                    // Window minimum was 1100×720 — far larger than the
                    // IDE actually needs to render usefully. The
                    // 44pt icon strip + 180pt collapsed sidebar +
                    // 200pt terminal floor still fits comfortably at
                    // 640×540, and at that size every element keeps
                    // its responsive layout (sidebar reflows, splits
                    // clamp to their own per-pane mins, status bar
                    // wraps gracefully). Smaller min lets the user
                    // arrange the window alongside other apps —
                    // common for chat-while-coding workflows. Height
                    // floor was bumped from 440 → 540 so the 36pt
                    // ProjectTopBar at the top and the 28pt MacStatusBar
                    // at the bottom always have enough vertical room to
                    // render their full chrome (without the workspace
                    // pane collapsing under the 200pt terminal floor
                    // and pushing the status row out of view).
                    .frame(minWidth: 640, minHeight: 540)
                    .preferredColorScheme(.dark)
            } else {
                // Auto-dismiss any "Project" window that opens without a
                // bound URL. macOS state restoration (and a fresh Xcode
                // launch) re-opens every WindowGroup scene that was ever
                // shown — for `WindowGroup(for: URL.self)` that means an
                // empty placeholder window titled "Project" can appear at
                // launch with no project. Render an empty `Color.clear`
                // and immediately call `dismissWindow` so the user only
                // ever sees the Welcome window in that case.
                EmptyProjectWindowDismisser()
            }
        }
        // `.hiddenTitleBar` removes the AppKit title-bar strip entirely so
        // our custom `ProjectTopBar` (search + project chip) can render in
        // the same row as the traffic lights instead of being pushed below
        // a reserved title-bar area. The unified toolbar style was forcing
        // a real title bar above the content view, which is what produced
        // the "two-row" header in the screenshot. Traffic lights are still
        // drawn by AppKit because they're attached to the window itself,
        // independent of the title-bar style — `ProjectTopBar` reserves a
        // 78pt leading inset so its content never crowds them.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                // "New Session" — workspace-scoped. Routes to whichever window is key.
                Button("New Session") {
                    if let ws = coord.activeWorkspace {
                        Task { _ = await ws.newSession() }
                    }
                }
                .keyboardShortcut("n")
                .disabled(coord.activeWorkspace == nil)
                // Project switching deliberately is NOT here. Once the user has picked a
                // project on the Welcome scene, that window is bound to that project for
                // its lifetime — switching projects mid-window would re-thread sessions /
                // file explorer / GitHub state across two roots, which is exactly the
                // confusion multi-window was meant to eliminate. To work on a different
                // project the user closes this window (⇧⌘W) and picks again from the
                // Welcome window, which opens a fresh workspace window for the new pick.
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Close Project") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(coord.activeWorkspace == nil)
            }
            // "Check for Updates…" sits where every other Mac app puts
            // it: directly under "About DNP Remote Mac" in the
            // application menu. Without this, the only way to trigger
            // a manual update probe was the Settings card — which
            // breaks expectations and Apple HIG. Disabled while
            // Sparkle is still resolving its first feed (mostly the
            // first second after launch), so a click never silently
            // no-ops.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateService.shared.checkForUpdates()
                }
                .disabled(!UpdateService.shared.canCheckForUpdates)
            }
        }

        Settings { MacSettingsView().environmentObject(coord) }

        // Menu-bar status item — visible whether the app is foreground or background. The
        // label uses a custom view so we can paint the brand icon + a badge bubble in one
        // place; `MenuBarExtra` flattens the SwiftUI label into an NSImage for AppKit.
        MenuBarExtra {
            MacMenuBarView().environmentObject(coord)
        } label: {
            MacMenuBarLabel(coord: coord)
        }
        .menuBarExtraStyle(.window)
    }

}

/// Status-item label. Renders the brand mark (template image so it inherits the
/// menu-bar tint automatically) and overlays a numeric badge whenever there's
/// something the user should look at — pending approvals or a degraded bridge.
private struct MacMenuBarLabel: View {
    @ObservedObject var coord: MacAppViewModel

    var body: some View {
        HStack(spacing: 3) {
            // The previous 18→22→26 frame bumps were getting silently
            // clipped: SwiftUI's `MenuBarExtra` flattens its label to a
            // single NSImage, and AppKit auto-clamps that image to the
            // system menu-bar drawable region (~22pt) UNLESS the label
            // explicitly opts into a fixed size. Combining a wider
            // source-aspect frame with `.fixedSize()` tells AppKit "use
            // this exact size for the bitmap", which breaks past the
            // soft clamp and renders the brand "n" noticeably bigger
            // (and visibly different from the previous step).
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 30)
                .fixedSize()
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(badgeCount) pending")
            } else if showsAttentionDot {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
        }
    }

    /// Pending approvals get a real number; "background activity" (live verifying handshake,
    /// bridge degraded) just shows a dot to avoid noisy counters.
    private var badgeCount: Int { coord.pendingApprovals.count }
    private var showsAttentionDot: Bool {
        if coord.bridge.port == nil { return true }
        if case .verifying = coord.pairingActivity { return true }
        if case .failed = coord.pairingActivity { return true }
        return false
    }
}

/// AppKit shim — gives us hooks SwiftUI doesn't expose directly (dock menu) and holds a
/// weak ref to the coordinator so menu actions can reach it.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: MacAppViewModel?

    /// Bootstrap fires here — NOT from a SwiftUI `.task` modifier — so the bridge
    /// listener and other services come up the moment the app finishes launching,
    /// independent of which (if any) windows happen to be open. This was a real bug:
    /// when bootstrap was tied to the Welcome window's `.task`, certain combinations
    /// of `MenuBarExtra` + window-restoration could delay or skip the task entirely,
    /// leaving the iPhone pairing attempts hitting "Connection refused" on port
    /// 18733 because nothing was bound. AppDelegate is the canonical Mac launch
    /// entry-point and runs once per process — exactly what we want.
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let coord = MacAppViewModel.shared
            self.viewModel = coord
            await MacNotificationService.shared.bootstrap()
            MainThreadWatchdog.shared.start()
            // Boot Sparkle as early as possible so the first background
            // update probe can land within the launch window. Calling
            // `start()` before `bootstrap()` is intentional — the
            // updater needs to read Info.plist + UserDefaults, neither
            // of which depend on our own services, and we want a fresh
            // appcast probe on the wire even if `bootstrap()` is slow.
            UpdateService.shared.start()
            await coord.bootstrap()
            // Re-open any project windows that were on-screen the last
            // time the app shut down (whether cleanly or via a crash /
            // force-quit). Runs AFTER `bootstrap()` so the persistence
            // stack, bridge, and Claude detector are ready before the
            // restored `WorkspaceWindow`s mount.
            coord.restoreOpenProjectWindowsIfNeeded()
        }
    }

    /// Lock down the persisted "open project windows" list before
    /// SwiftUI starts its teardown. Each `WorkspaceWindow.onDisappear`
    /// fires during a clean quit and calls `unregisterProjectWindow(url)`,
    /// whose didSet would otherwise persist a SHRINKING list and end
    /// with an empty array on disk — making next launch restore nothing.
    /// Setting `isTerminating = true` here, BEFORE the disappear chain
    /// runs, keeps the last-run snapshot intact.
    nonisolated func applicationWillTerminate(_ notification: Notification) {
        // `MainActor.assumeIsolated` is safe because
        // `applicationWillTerminate` is delivered on the main thread by
        // AppKit. Marking the function `nonisolated` matches the
        // protocol shape; the assume hop is the canonical AppKit
        // idiom for getting onto MainActor synchronously.
        MainActor.assumeIsolated {
            MacAppViewModel.shared.isTerminating = true
        }
    }

    nonisolated func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        MainActor.assumeIsolated { buildDockMenu() }
    }

    private func buildDockMenu() -> NSMenu {
        let menu = NSMenu()

        // "New Window" — explicitly summons the welcome / project-picker window. The
        // user closed it on project pick (per the multi-window flow); this is how
        // they re-enter the picker to open ADDITIONAL projects in parallel.
        let newWindow = NSMenuItem(title: "New Window",
                                    action: #selector(newWelcomeWindowFromDock(_:)),
                                    keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)

        // Visual separator between window-management entries and project entries.
        menu.addItem(NSMenuItem.separator())

        let open = NSMenuItem(title: "Open Project…", action: #selector(openProjectFromDock(_:)),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        // Dock menu lists projects that have a CURRENTLY-OPEN window, not the full
        // historical recents. Closing a project window removes it from this list
        // immediately — the user explicitly asked for that, since the dock menu is
        // really for "jump to an active workspace" not "browse history". The full
        // history still lives on the Welcome scene's "Recent Projects" section.
        let openWindows = viewModel?.openProjectWindows ?? []
        if !openWindows.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "Open Projects", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in openWindows.prefix(8) {
                let item = NSMenuItem(title: url.lastPathComponent,
                                      action: #selector(focusOpenProjectFromDock(_:)),
                                      keyEquivalent: "")
                item.representedObject = url
                item.target = self
                // Use the real Finder folder icon for the project (or a fallback
                // SF Symbol if the path no longer exists), sized down to the
                // standard menu glyph height so it sits neatly beside the title.
                item.image = Self.folderIcon(for: url)
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func focusOpenProjectFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSApp.activate(ignoringOtherApps: true)
        // `WindowGroup(for: URL.self)` deduplicates by value, so this just brings
        // the existing window forward instead of opening a new one.
        ProjectWindowOpener.openProject(at: url)
    }

    @objc private func newWelcomeWindowFromDock(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        // If a welcome window is already open (just minimized / hidden), surface it
        // directly via AppKit. Otherwise post the notification — any open WorkspaceWindow
        // / WelcomeView listener will call `openWindow(id: "welcome")`.
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome-AppWindow-1" || $0.identifier?.rawValue == "welcome" }) {
            existing.deminiaturize(nil)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        WelcomeWindowOpener.openWelcome()
    }

    /// Override the default "+" tab-bar button. macOS calls this on the
    /// responder chain when the user clicks "+" inside a tabbed window;
    /// the default behaviour spawns an empty new window of the same kind
    /// (which in our case meant a blank project tab with no project URL —
    /// a dead end for the user). Routing it through the Welcome window
    /// instead lets the user pick a folder / git repo / SSH host the same
    /// way they would when launching the app fresh, which matches the
    /// affordance the user explicitly asked for.
    @objc func newWindowForTab(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "welcome-AppWindow-1"
                || $0.identifier?.rawValue == "welcome"
        }) {
            existing.deminiaturize(nil)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        WelcomeWindowOpener.openWelcome()
    }

    @objc private func openProjectFromDock(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            RecentProjectsService.shared.registerLocal(at: url)
            ProjectWindowOpener.openProject(at: url)
        }
    }

    @objc private func reopenRecentFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = RecentProjectsService.shared.entries.first(where: { $0.id == id })
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        RecentProjectsService.shared.register(entry)
        switch entry.kind {
        case .local, .clone:
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            ProjectWindowOpener.openProject(at: url)
        case .ssh:
            guard let host = entry.sshHost, let user = entry.sshUser else { return }
            let conn = SSHConnectionService.Connection(
                host: host, user: user, port: entry.sshPort ?? 22,
                identityFile: entry.sshIdentityFile,
                remotePath: entry.path,
                displayName: entry.displayName
            )
            // SSH shells run inside whatever workspace window is currently active — the
            // local file explorer is still local for now (remote-workspace = future).
            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            ProjectWindowOpener.openProject(at: homeURL)
            let displayName = entry.displayName
            Task { @MainActor [weak self] in
                guard let ws = self?.viewModel?.activeWorkspace else { return }
                await self?.viewModel?.openSSHSession(connection: conn,
                                                      displayName: displayName,
                                                      in: ws)
            }
        }
    }

    /// Renders the real Finder icon for a project at `url`, sized to the
    /// standard 16pt menu glyph height. Falls back to an SF Symbol "folder"
    /// when the path no longer exists on disk (recently moved / deleted).
    private static func folderIcon(for url: URL) -> NSImage {
        let icon: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else if let symbol = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            icon = symbol
        } else {
            icon = NSImage(size: NSSize(width: 16, height: 16))
        }
        let resized = NSImage(size: NSSize(width: 16, height: 16))
        resized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        resized.unlockFocus()
        // Template = false so the colorful Finder folder badge keeps its color
        // instead of being recolored as a monochrome menu glyph.
        resized.isTemplate = false
        return resized
    }
}

/// Tiny SwiftUI shim that closes its own host window the moment it
/// appears. Used as the placeholder body of the `Project` WindowGroup
/// when it's instantiated without a bound URL — instead of presenting
/// an empty workspace window titled "Project", we close it immediately.
/// `Color.clear` keeps the window content well-defined (a zero-content
/// view crashes some builds of SwiftUI). The dismiss runs on the next
/// runloop tick to avoid mutating window state inside SwiftUI's render
/// pass.
private struct EmptyProjectWindowDismisser: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                DispatchQueue.main.async {
                    dismissWindow(id: "project")
                }
            }
    }
}

/// Helper for opening project windows from non-View contexts (Commands closures, AppKit
/// callbacks). Posts a Notification that a tiny SwiftUI shim listens for and forwards to
/// the real `openWindow` environment action — needed because `@Environment(\.openWindow)`
/// only works inside a View.
enum ProjectWindowOpener {
    static let notification = Notification.Name("dnp.openProjectWindow")

    static func openProject(at url: URL) {
        NotificationCenter.default.post(name: notification, object: url.standardizedFileURL)
    }
}

/// Same trick for the welcome (project picker) window — used by the dock menu's "New
/// Window" item to summon another welcome window so the user can pick an additional
/// project in parallel. WorkspaceWindow + WelcomeView both listen to this notification.
enum WelcomeWindowOpener {
    static let notification = Notification.Name("dnp.openWelcomeWindow")

    static func openWelcome() {
        NotificationCenter.default.post(name: notification, object: nil)
    }
}
