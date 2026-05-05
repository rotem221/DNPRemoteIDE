import SwiftUI
import AppKit

/// Container view for a per-project window. Owns the `WorkspaceController` for its
/// project (created with `@StateObject` so it lives for the window's lifetime) and
/// presents the existing `MacAppShellView` inside.
///
/// Two responsibilities:
/// 1. **Activate** the workspace whenever its window becomes key — this mirrors the
///    workspace's projectRoot/sidebar state into the singleton VM's legacy fields so
///    internal code paths (hook routing, transcript watcher, etc.) continue to read
///    "the active project."
/// 2. **Listen for `ProjectWindowOpener.notification`** and forward the URL to SwiftUI's
///    `openWindow` action — the bridge that lets non-View code (Commands, AppKit menus)
///    open project windows. Each open WorkspaceWindow listens, but only one fires the
///    open call (deduped via the URL standardization that `WindowGroup(for:URL)` does
///    automatically).
struct WorkspaceWindow: View {
    let projectURL: URL
    @EnvironmentObject var coord: MacAppViewModel
    @StateObject private var workspace: WorkspaceController
    @Environment(\.openWindow) private var openWindow

    init(projectURL: URL) {
        let normalised = projectURL.standardizedFileURL
        self.projectURL = normalised
        // The coordinator is the static singleton — accessing `MacAppViewModel.shared`
        // here is safe at init time (no environment dependency). Multi-window pattern
        // requires exactly one coordinator across all windows; see the singleton doc.
        _workspace = StateObject(
            wrappedValue: WorkspaceController(projectURL: normalised,
                                              coord: MacAppViewModel.shared)
        )
    }

    var body: some View {
        MacAppShellView()
            .environmentObject(coord)
            .environmentObject(workspace)
            .onAppear {
                workspace.activate()
                // Resolve `.git/config` off the main thread — running it in
                // `WorkspaceController.init` (called from inside SwiftUI's update
                // cycle) would block on `Process.waitUntilExit` and trip
                // "AttributeGraph precondition failure: setting value during update"
                // → SIGABRT. Deferring to onAppear runs us outside the update cycle
                // and the detection itself dispatches to a background queue.
                workspace.detectGitHubAsync()
                // Register the window in the coordinator's open-windows list so
                // the menu-bar popover can list "active windows" (open projects)
                // and the user can switch to one with a click. Pairs with the
                // unregister call in `.onDisappear` below.
                coord.registerProjectWindow(projectURL)
            }
            .onDisappear {
                coord.unregisterProjectWindow(projectURL)
            }
            .background(KeyWindowObserver { isKey in
                if isKey { workspace.activate() }
            })
            // Set the window's title to the project name (used by the dock
            // menu / window menu / cmd+~ switcher). Replaces the role the
            // old `ProjectWindowTabbingConfigurator` was playing here, now
            // that the tabs feature is gone and the configurator with it.
            .background(WindowTitleSetter(title: projectURL.lastPathComponent))
            .background(WorkspaceCloseConfirmer(projectURL: projectURL))
            .onReceive(NotificationCenter.default.publisher(for: ProjectWindowOpener.notification)) { note in
                if let url = note.object as? URL {
                    // Bring the app forward FIRST so an already-open window of this
                    // project surfaces above other apps (without this, openWindow
                    // refocuses the existing window but it can stay behind another
                    // app). Then `openWindow(value:)` either brings the existing
                    // window of the same URL to the front or creates a new one for a
                    // first-time URL — `WindowGroup(for: URL.self)` dedupes for us.
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "project", value: url.standardizedFileURL)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: WelcomeWindowOpener.notification)) { _ in
                // Dock menu's "New Window" — open a fresh welcome / project picker.
                // SwiftUI's `Window(id: "welcome")` is restorable, so this re-creates
                // the welcome window even if it was previously dismissed.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "welcome")
            }
            // No `.navigationTitle` — the project name is rendered as a chip
            // inside `ProjectTopBar` (opposite the traffic lights). Setting
            // a navigationTitle here re-enables the system title text in the
            // title bar even with `titleVisibility = .hidden`, producing a
            // duplicate "ProjectName" strip above our custom top bar.
    }
}

/// Observes the `NSWindow.didBecomeKey` / `didResignKey` notifications for the host
/// window. Drives `WorkspaceController.activate()` so the singleton VM's "active project"
/// mirror stays in sync with whichever window the user is actually working in.
private struct KeyWindowObserver: NSViewRepresentable {
    let onKeyChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onKeyChange = onKeyChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ObserverView)?.onKeyChange = onKeyChange
    }

    private final class ObserverView: NSView {
        var onKeyChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = self.window else { return }
            // Initial fire — at attach time, the window may already be key.
            onKeyChange?(window.isKeyWindow)
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main
            ) { [weak self] _ in self?.onKeyChange?(true) }
        }
    }
}

/// Sets the host `NSWindow`'s title to the project name (used by the dock
/// menu, the Window menu, and ⌘~ window switcher) and forces tabbing off
/// for the workspace window. The "tabs in one window" feature was removed
/// — every project always opens in its own dedicated window now — so this
/// also detaches any window that was previously merged into a tab group by
/// an older version of the app.
private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { TrackerView(title: title) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackerView)?.titleText = title
    }

    private final class TrackerView: NSView {
        var titleText: String {
            didSet { applyToWindow() }
        }

        init(title: String) {
            self.titleText = title
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Defer one tick so SwiftUI's window-attach pass finishes
            // before we mutate the host NSWindow's properties.
            DispatchQueue.main.async { [weak self] in
                self?.applyToWindow()
            }
        }

        private func applyToWindow() {
            guard let win = window else { return }
            if !titleText.isEmpty, win.title != titleText {
                win.title = titleText
            }
            // Always render as a standalone window. macOS state restoration
            // (or an older app version) might have left this window in a
            // tab group — pop it out so the layout matches the rest of the
            // app's "one project, one window" model.
            win.tabbingMode = .disallowed
            win.tabbingIdentifier = ""
            if (win.tabGroup?.windows.count ?? 0) > 1 {
                win.moveTabToNewWindow(nil)
            }
        }
    }
}

/// Intercepts the workspace window's red-traffic-light close and asks the
/// user whether to keep or wipe this project's session history before the
/// window actually goes away. Behaviour:
///
///   • If the project has no persisted sessions, the close is allowed
///     immediately — no point interrupting with a meaningless prompt.
///   • Otherwise an NSAlert is shown with three buttons:
///       - **Keep History** (default): close the window, leave the disk
///         state intact so the next open re-hydrates everything.
///       - **Delete History** (destructive): wipe every persisted session
///         (`metadata.json`, `events.jsonl`, `transcript.md`, `summary.md`)
///         whose `projectPath` matches this project, then close.
///       - **Cancel**: keep the window open.
///
/// Implemented as an `NSViewRepresentable` so it can grab the host
/// `NSWindow` once it's attached and install itself as the window's
/// `delegate`. The delegate uses `windowShouldClose` to defer the close
/// while it shows the alert (sheet-modal on the workspace window).
private struct WorkspaceCloseConfirmer: NSViewRepresentable {
    let projectURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(projectURL: projectURL) }

    func makeNSView(context: Context) -> NSView {
        let view = AttachView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.projectURL = projectURL
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var projectURL: URL
        // True only while we're presenting the confirmation sheet — so a
        // re-entrant `windowShouldClose` from `window.close()` after the
        // user picked "Keep" / "Delete" doesn't loop the prompt.
        private var decisionMade = false

        init(projectURL: URL) { self.projectURL = projectURL }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if decisionMade { return true }
            let url = projectURL
            // Probe persistence off the main actor; only present the alert
            // if there's actually history worth asking about.
            Task { @MainActor in
                let persistence = MacAppViewModel.shared.persistence
                let hasHistory = await persistence.hasSessions(forProjectAt: url)
                guard hasHistory else {
                    self.decisionMade = true
                    sender.close()
                    return
                }
                self.presentAlert(on: sender, persistence: persistence, url: url)
            }
            return false
        }

        @MainActor
        private func presentAlert(on window: NSWindow,
                                  persistence: SessionPersistenceService,
                                  url: URL) {
            let alert = NSAlert()
            alert.messageText = "Close \(url.lastPathComponent)?"
            alert.informativeText = "Do you want to keep this project's session history (transcripts, events, and summaries) for next time, or delete it?"
            alert.alertStyle = .warning
            // Order matters — first added is the default (return key).
            alert.addButton(withTitle: "Keep History")
            alert.addButton(withTitle: "Delete History")
            alert.addButton(withTitle: "Cancel")
            // Mark "Delete History" as destructive so it gets the standard
            // red-tinted treatment on macOS 11+.
            if alert.buttons.count >= 2 {
                alert.buttons[1].hasDestructiveAction = true
            }
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn: // Keep
                    self.decisionMade = true
                    window.close()
                case .alertSecondButtonReturn: // Delete
                    Task { @MainActor in
                        _ = await persistence.purgeSessions(forProjectAt: url)
                        self.decisionMade = true
                        window.close()
                    }
                default: // Cancel — leave the window open.
                    break
                }
            }
        }
    }

    private final class AttachView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The host NSWindow may already have its own delegate installed
            // by SwiftUI. We deliberately replace it: SwiftUI's default
            // delegate doesn't intercept `windowShouldClose`, and the
            // window's other lifecycle hooks we care about (becomeKey /
            // resignKey) are already handled via NotificationCenter in
            // `KeyWindowObserver`, so there's nothing to forward.
            DispatchQueue.main.async { [weak self] in
                guard let self, let win = self.window, let coord = self.coordinator else { return }
                win.delegate = coord
            }
        }
    }
}
