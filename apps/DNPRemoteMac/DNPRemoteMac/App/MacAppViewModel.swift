import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacAppViewModel: ObservableObject {

    /// Process-wide singleton. Multi-window mode requires that every window's
    /// `WorkspaceController` holds the same coordinator reference so they share the
    /// global session pool, the bridge listener, and the paired-devices store. Using a
    /// `@StateObject` in the App scene wouldn't expose the same instance to a per-URL
    /// `WindowGroup(for:)` workspace window; the static `shared` does.
    static let shared = MacAppViewModel()

    /// The currently-active workspace window — nil while only the Welcome window is up.
    /// Internal code paths that historically read `self.projectRoot` (hooks, dispatcher,
    /// transcript watcher, restore-on-launch) keep working because those legacy fields
    /// mirror the active workspace's state. New views read `WorkspaceController`
    /// directly and never depend on this mirror.
    weak var activeWorkspace: WorkspaceController?

    @Published var sessions: [Session] = []
    @Published var selectedSessionId: UUID?
    @Published var pendingApprovals: [ApprovalRequest] = []
    @Published var connectedDevices: [DeviceRecord] = []
    @Published var connectedDeviceIds: Set<UUID> = []
    /// Per-device transport — `local` (LAN / loopback) vs `tailscale`
    /// (Tailscale CGNAT 100.64.0.0/10 or `*.ts.net` hostname). Populated
    /// by `BridgeDispatcher.recordRemoteForDevice(...)` whenever a
    /// device finishes authenticating; cleared when the connection
    /// drops. Read by the Pairing pane to label each `DeviceRow` with
    /// "via LAN" / "via Tailnet" so the user can see how their iPhone
    /// is currently reaching the Mac.
    @Published var connectedDeviceTransports: [UUID: PairingTransport] = [:]
    @Published var bridgeStatus: ConnectionStatus = .offline
    @Published var contextSnapshots: [UUID: ContextSnapshot] = [:]
    @Published var feed: [UUID: [SessionEvent]] = [:]
    @Published var diagnostics: DiagnosticsSnapshot = .empty

    // MARK: Project / IDE state
    @Published var projectRoot: FileNode?
    /// Set when the active project is a GitHub clone. Drives the "linked to GitHub" badge in
    /// the file explorer + the branch chip in the workspace toolbar.
    @Published var projectGitHub: GitHubProjectInfo?
    @Published var openFiles: [OpenFile] = []
    @Published var activeFile: OpenFile?
    @Published var workspacePane: WorkspacePane = .terminal
    /// Persisted across launches via UserDefaults. Storing `rawValue` keeps the value
    /// schema-compatible with future `SidebarTab` additions — unknown values fall back to
    /// `.files` on read.
    @Published var sidebarTab: SidebarTab = {
        if let raw = UserDefaults.standard.string(forKey: "dnp.mac.sidebar.tab"),
           let tab = SidebarTab(rawValue: raw) { return tab }
        return .files
    }() {
        didSet { UserDefaults.standard.set(sidebarTab.rawValue, forKey: "dnp.mac.sidebar.tab") }
    }

    /// Sidebar open/closed state. **Defaults to closed** on a fresh install (no UserDefaults
    /// entry yet) so the first-launch impression is the wide IDE workspace, not a half-empty
    /// folder pane. Subsequent launches restore the last state — open or closed — so the
    /// user's working layout survives quitting the app. Width is persisted separately via
    /// `@AppStorage("dnp.mac.sidebarWidth")` in MacAppShellView.
    @Published var sidebarExpanded: Bool = (UserDefaults.standard.object(forKey: "dnp.mac.sidebar.expanded") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(sidebarExpanded, forKey: "dnp.mac.sidebar.expanded") }
    }

    /// One running terminal per `Session.id`. Created on `newSession()`, retained while the user
    /// switches between sessions, torn down on `closeSession(_:)`. Each terminal keeps its own PTY
    /// child process and its own scrollback — the user can have N sessions running in parallel.
    @Published var terminalSessions: [UUID: TerminalSession] = [:]


    /// Sessions for which we already wrote a context-critical handoff note. Avoids duplicate writes.
    private var handoffWritten: Set<UUID> = []

    /// Maps Claude's own session_id (from hook payloads) → our local Session.id. Populated by
    /// SessionStart and refreshed whenever a hook arrives with both ids visible. Used to route
    /// every hook event back to the right local session, independent of `selectedSessionId`.
    fileprivate(set) var claudeSessionToLocal: [String: UUID] = [:]

    /// Per-session set of assistant-message text fingerprints we've already broadcast. The
    /// transcript watcher and the Stop hook can both surface the same assistant turn — this
    /// stops the iOS feed from showing the reply twice.
    private var deliveredAssistantHashes: [UUID: Set<Int>] = [:]

    /// Prompts queued for a session whose terminal isn't yet ready. Flushed by
    /// `flushPendingPrompts(_:)` when the transcript watcher reports Claude has spawned
    /// (= the session's `.jsonl` file appeared, so the TUI is initialised and accepts
    /// stdin). This was the source of the "first message in a brand-new session is lost"
    /// bug — the previous `Task.sleep(1.2 s)` was sometimes too short on first launch.
    private var pendingPromptsBySession: [UUID: [String]] = [:]

    /// Per-session set of user-message text fingerprints already delivered. iOS-originated
    /// prompts (which are echoed via `handleIncomingUserPrompt`) and Mac-typed prompts (which
    /// arrive via the transcript watcher) get the same text — this dedupes them to a single bubble.
    private var deliveredUserHashes: [UUID: Set<Int>] = [:]

    /// Per-session ring of recently-emitted tool activity fingerprints — `name|summary` —
    /// to swallow duplicates when both PreToolUse hooks and the transcript watcher fire.
    private var deliveredToolKeys: [UUID: Set<String>] = [:]

    /// Sessions whose title was set by Claude's own `ai-title` JSONL line. Once a session
    /// is in this set, we stop overriding its title from prompt-derived heuristics or
    /// from the `Claude · <short-id>` placeholder — Claude's name wins, period (per
    /// user's "אם קלוד כן נותן שם אל תשנה כלום" rule).
    private var claudeNamedSessions: Set<UUID> = []

    /// Files Claude has touched, keyed by absolute project root path → set of standardized
    /// absolute file paths. Drives the file explorer's "modified" badge: each
    /// `WorkspaceController` reads the entry for its own root and decorates rows whose
    /// path (or any descendant) lives in the set. @Published so SwiftUI re-renders the
    /// file tree the moment a new edit arrives, without needing each row to subscribe
    /// to its own publisher.
    @Published var editedFilesByProject: [String: Set<String>] = [:]

    /// Most recent unified diff per file (absolute, standardized path). Drives the
    /// inline diff banner shown above `CodeEditorView` when the user opens a file
    /// Claude just edited — green for additions, red for deletions, mirroring the
    /// feed-pane card. Latest write wins; we don't keep history.
    @Published var lastDiffByFile: [String: String] = [:]

    /// Latest "thinking" text per session (extended-thinking blocks). Surfaced by the iOS
    /// thinking indicator below the bubble of dots.
    @Published var thinkingTexts: [UUID: String] = [:]

    /// Latest Claude Code quota snapshot (`5h` / `7d` / Sonnet / Omelette
    /// utilisation %). Refreshed every 5 min by `aiUsageRefreshTimer`,
    /// broadcast to iOS on every refresh and on each new connection. Drives
    /// the AI Usage pill in the Mac status bar AND the AI Usage rows in the
    /// iOS Context popover.
    @Published var aiUsage: AIUsageSnapshot?

    /// Most recent session id we broadcast to iOS as the IDE's
    /// "currently focused" session — set whenever any
    /// `WorkspaceController.selectedSessionId` changes via
    /// `notifyActiveSessionChanged(_:)`. Replayed to fresh iOS clients
    /// in `BridgeDispatcher.sendActiveSessionIfAvailable(to:)` so a
    /// reconnecting iPhone can adopt the right session immediately
    /// instead of waiting for the next user-driven pane swap. nil =
    /// no session currently focused.
    ///
    /// Intentionally NOT `@Published` — no SwiftUI view observes this
    /// state; it's purely the dispatcher's last-write cache. Marking
    /// it `@Published` was the trigger for an AttributeGraph hang the
    /// user hit when opening a split: `pruneTreeIfStale()` runs from
    /// inside a SwiftUI `onChange` handler and re-anchors
    /// `selectedSessionId`, whose `didSet` calls into here. Mutating
    /// a `@Published` mid-update is the "modifying state during view
    /// update" trap that crashes AttributeGraph (and was the same
    /// failure mode WorkspaceController.init's GitHub-detection
    /// comment describes). Plain `var` keeps the cache without the
    /// SwiftUI side effects.
    var lastBroadcastActiveSessionId: UUID?

    /// URLs of project windows currently open on screen, in the order they
    /// were registered (i.e. the order the user opened them). Populated by
    /// `WorkspaceWindow.onAppear` and pruned by `.onDisappear` so the list
    /// reflects exactly what's mounted as a SwiftUI window. The menu-bar
    /// popover reads this to show "active windows" — one entry per
    /// `WorkspaceWindow`, which is the user-facing meaning of "active project"
    /// in the multi-window architecture (a project is "open" iff its window
    /// exists, regardless of whether any of its terminal sessions are running).
    ///
    /// `didSet` mirrors every change to `UserDefaults` under
    /// `Self.openProjectURLsKey` so the next app launch can re-open whatever
    /// was on screen — even if the previous run crashed or was killed with
    /// `kill -9` (`applicationWillTerminate` doesn't fire in that case, so
    /// macOS's built-in state restoration is unreliable; we own this list).
    @Published var openProjectWindows: [URL] = [] {
        didSet {
            // Skip persistence while the app is shutting down. SwiftUI
            // tears down every WorkspaceWindow's view tree during a
            // clean quit, firing each window's `.onDisappear` →
            // `coord.unregisterProjectWindow(url)` → this `didSet`,
            // which would otherwise persist a SHRINKING list and end
            // with an empty array on disk. Next launch would then have
            // nothing to restore. Locking persistence behind
            // `isTerminating` (set by `applicationWillTerminate`)
            // keeps the LAST-RUN snapshot intact across clean quits.
            // Force-kills (`kill -9`) skip both `applicationWillTerminate`
            // and the SwiftUI teardown, so the latest live persisted
            // state survives there too.
            guard !isTerminating else { return }
            persistOpenProjectWindows()
        }
    }

    /// Set by `MacAppDelegate.applicationWillTerminate` so the
    /// persistence didSets above can recognise "we're shutting down,
    /// don't mutate the saved state." Read AND written on the main
    /// actor only.
    var isTerminating: Bool = false

    /// How a paired device is currently reaching the Mac. Derived from
    /// the connection's remote address: Tailscale CGNAT addresses
    /// (`100.64.0.0/10`) and `*.ts.net` hostnames map to `.tailscale`;
    /// every other resolvable address (LAN, loopback, hotspot) maps to
    /// `.local`. `unknown` is the fallback when the remote string can't
    /// be parsed at all.
    enum PairingTransport: String {
        case local, tailscale, unknown

        /// Human label rendered next to the connected badge. Kept short
        /// so it fits inside a row chip without truncation.
        var label: String {
            switch self {
            case .local:     return "Local"
            case .tailscale: return "Tailnet"
            case .unknown:   return "—"
            }
        }
        var iconName: String {
            switch self {
            case .local:     return "wifi"
            case .tailscale: return "antenna.radiowaves.left.and.right"
            case .unknown:   return "questionmark.circle"
            }
        }

        /// Decide LAN vs Tailscale from the bridge-reported remote
        /// address string. The remote arrives as either `IP:port` for
        /// IPv4 or `[IPv6]:port` for IPv6. Tailscale routes all tailnet
        /// peers through the 100.64.0.0/10 CGNAT block and gives them
        /// `*.ts.net` MagicDNS names; both signals are checked.
        static func from(remote: String) -> PairingTransport {
            let lower = remote.lowercased()
            if lower.contains(".ts.net") { return .tailscale }
            // Strip [IPv6] brackets and trailing :port to isolate the host.
            var host = lower
            if host.hasPrefix("[") {
                if let end = host.firstIndex(of: "]") {
                    host = String(host[host.index(after: host.startIndex)..<end])
                }
            } else if let colon = host.lastIndex(of: ":") {
                host = String(host[..<colon])
            }
            // Tailscale CGNAT range: 100.64.0.0 – 100.127.255.255.
            if host.hasPrefix("100.") {
                let parts = host.split(separator: ".")
                if parts.count >= 2, let octet = Int(parts[1]), (64...127).contains(octet) {
                    return .tailscale
                }
            }
            // Anything else with a parseable IPv4 / IPv6 / loopback host
            // is local.
            if host.isEmpty { return .unknown }
            return .local
        }
    }

    /// Set the transport for a device that just finished authenticating.
    /// Called by `BridgeDispatcher` once it has both the connection's
    /// remote string AND the device id (the dispatcher gets the device
    /// id only after the hello / pairing handshake completes).
    @MainActor
    func recordTransport(for deviceId: UUID, remote: String) {
        connectedDeviceTransports[deviceId] = .from(remote: remote)
    }

    /// Reorder the open-project-windows list so a dragged tab in the
    /// `ProjectTabsStrip` (or the menu-bar / dock listing that mirrors it)
    /// lands at the user's chosen position. Insertion follows the same
    /// AppKit semantics as `moveSession`: dropping ON a target places the
    /// source IMMEDIATELY BEFORE it, dropping past the last entry appends.
    /// Silent no-op on stale URLs.
    @MainActor
    func moveProjectWindow(_ sourceURL: URL, before targetURL: URL?) {
        let src = sourceURL.standardizedFileURL
        let tgt = targetURL?.standardizedFileURL
        guard let fromIndex = openProjectWindows.firstIndex(of: src) else { return }
        let url = openProjectWindows.remove(at: fromIndex)
        if let tgt, let toIndex = openProjectWindows.firstIndex(of: tgt) {
            openProjectWindows.insert(url, at: toIndex)
        } else {
            openProjectWindows.append(url)
        }
    }

    /// Reorder the global sessions array so a dragged session row in the
    /// sidebar lands at the user's chosen position. Both ids must reference
    /// real sessions; if either lookup fails the call is a silent no-op so
    /// stale drag payloads (e.g. from a session that was just closed mid-
    /// drag) don't crash the reorder. Insertion follows AppKit semantics:
    /// dropping ON a target row places the source IMMEDIATELY BEFORE it,
    /// dropping past the last row appends.
    @MainActor
    func moveSession(_ sourceId: UUID, before targetId: UUID?) {
        guard let fromIndex = sessions.firstIndex(where: { $0.id == sourceId }) else { return }
        let session = sessions.remove(at: fromIndex)
        if let targetId,
           let toIndex = sessions.firstIndex(where: { $0.id == targetId }) {
            sessions.insert(session, at: toIndex)
        } else {
            sessions.append(session)
        }
    }

    /// Register a project window as open. Idempotent — calling twice with the
    /// same URL is a no-op. Standardises the URL so two paths that resolve to
    /// the same on-disk location collapse to one entry, matching how
    /// `WindowGroup(for: URL.self)` dedupes its windows.
    func registerProjectWindow(_ url: URL) {
        let std = url.standardizedFileURL
        if !openProjectWindows.contains(std) {
            openProjectWindows.append(std)
        }
    }

    /// Remove a project window from the open list when its `WorkspaceWindow`
    /// is torn down (user closes the window or quits the app). Tolerates a
    /// URL that's no longer in the list.
    func unregisterProjectWindow(_ url: URL) {
        let std = url.standardizedFileURL
        openProjectWindows.removeAll { $0 == std }
    }

    /// UserDefaults key for the persisted list of open project URLs. Read at
    /// launch by `restoreOpenProjectWindowsIfNeeded()`; written on every
    /// change to `openProjectWindows`.
    static let openProjectURLsKey = "dnp.mac.openProjectURLs"

    private func persistOpenProjectWindows() {
        let paths = openProjectWindows.map(\.standardizedFileURL.path)
        UserDefaults.standard.set(paths, forKey: Self.openProjectURLsKey)
    }

    /// Reopen every project window that was on-screen the last time the app
    /// shut down (cleanly OR via crash / force-quit). Called from
    /// `MacAppDelegate.applicationDidFinishLaunching` after `bootstrap()`
    /// completes, so the restored windows mount on top of a fully-bootstrapped
    /// view-model and persistence stack. Filters out paths that no longer
    /// exist on disk (project deleted between runs) and emits each survivor
    /// through `ProjectWindowOpener.openProject(at:)` — the same path the
    /// Welcome window uses, so restored windows go through the standard
    /// `WindowGroup(for: URL.self)` flow and don't duplicate if the user
    /// also opened them manually before this code runs.
    @MainActor
    func restoreOpenProjectWindowsIfNeeded() {
        let raw = UserDefaults.standard.array(forKey: Self.openProjectURLsKey) as? [String] ?? []
        let urls = raw.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !urls.isEmpty else { return }
        // Stagger the open calls so each `WorkspaceWindow` mounts on its
        // own runloop tick — opening N windows in a single tick can race
        // SwiftUI's `WindowGroup(for:)` dedup logic and produce stacked
        // identical windows for the same URL on rare occasions.
        for (idx, url) in urls.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.05) {
                ProjectWindowOpener.openProject(at: url)
            }
        }
    }

    /// Last live-thinking snapshot we broadcast per session — drives the dedup gate so
    /// the PTY-scrape poller (`pollLiveTerminalText`) doesn't spam iOS with identical
    /// thinkingSummary events when the terminal hasn't actually changed since the last
    /// tick. Cleared on session close.
    private var lastBroadcastLiveText: [UUID: String] = [:]

    /// Periodic timer driving `pollLiveTerminalText`. One timer for the whole app —
    /// each tick walks the active terminals and emits a thinkingSummary for any
    /// session whose visible text changed AND whose iOS-side thinking indicator is
    /// currently shown. We don't burn cycles on idle sessions.
    private var liveTerminalPollTimer: Timer?

    /// 5-minute timer driving Claude Code AI Usage refreshes. Same cadence
    /// Muxy uses; the Anthropic endpoint is not cheap to hit faster than
    /// that and the windows reset on minute boundaries anyway.
    private var aiUsageRefreshTimer: Timer?

    /// Tool context cached from `PreToolUse` / `PermissionRequest` hooks per session.
    /// Hooks DO NOT raise approval cards anymore — they just stash context here so
    /// when the PTY-driven poller spots Claude's actual inline prompt it can build a
    /// rich approval card (with the right tool name + target). Cleared on `PostToolUse`.
    /// This is the architectural shift behind "no more false-positive `allow`
    /// notifications": the PTY is the single source of truth for "is Claude really
    /// paused?", and the hook just provides context-when-it-arrives.
    struct PendingHookCall { let toolName: String; let target: String; let timestamp: Date }
    private var pendingHookCalls: [UUID: PendingHookCall] = [:]

    /// Approvals currently being raised (`raiseApproval` await in flight) — guards
    /// the poller from issuing two raises in the same 750ms window before
    /// `pendingApprovals` reflects the first one.
    private var approvalRaiseInFlight: Set<UUID> = []

    /// First tick during which `isAtClaudePrompt()` reported FALSE for an existing
    /// pending approval. We wait a grace period (~1.5s) before silently dismissing
    /// to absorb redraw flicker — without it, a transient SwiftTerm repaint could
    /// dismiss a real card mid-keypress.
    private var approvalNotPromptedSince: [UUID: Date] = [:]

    /// Live pairing handshake state, surfaced in `PairingSheet` so the Mac shows the same
    /// "Connecting → Verifying → Paired/Failed" beats the iPhone shows. Mirrors the iOS
    /// `pairingState` semantics. Driven by `BridgeServerService` (new connection observed)
    /// and `BridgeDispatcher.handlePairing` (request decoded → accepted or denied).
    @Published var pairingActivity: MacPairingActivity = .idle

    let runtime = PTYRuntimeService()
    let claude = ClaudeSessionService()
    let transcripts = TranscriptWatcher()
    let normalizer = EventNormalizerService()
    let approvals = ApprovalCoordinator()
    let contextMonitor = ContextMonitorService()
    let bridge = BridgeServerService()
    let hookIngest = HookIngestServer()
    let pairing = DeviceTrustService()
    let persistence = SessionPersistenceService()
    let memory = ProjectMemoryService()
    let crashes = CrashReporter.shared
    private(set) lazy var dispatcher: BridgeDispatcher = {
        let d = BridgeDispatcher(); d.vm = self; return d
    }()

    func bootstrap() async {
        crashes.installSignalHandlers()
        // MetricKit subscriber — system-collected crash, hang, and
        // performance payloads land in
        // `~/Library/Application Support/DNPRemoteMac/memory/crashes/metrickit/`.
        // Complements the in-process `CrashReporter` with full
        // post-mortem backtraces; no third-party SDK needed.
        MetricKitReporter.shared.install()
        await persistence.bootstrap()
        await pairing.bootstrap()

        // Banner taps on session-error notifications focus the originating session in the
        // sidebar so the user lands directly on the failing session when reopening the
        // app from outside it.
        MacNotificationService.shared.onSessionTap = { [weak self] sessionId in
            Task { @MainActor in
                guard let self else { return }
                if self.sessions.contains(where: { $0.id == sessionId }) {
                    self.selectedSessionId = sessionId
                }
            }
        }
        // Approve / Deny tapped on a Mac banner (or floating panel). Routes back through
        // the same `handleApprovalDecision` path the in-app buttons use, so Claude's TUI
        // gets the `1\r` / `2\r` answer typed into the PTY exactly once regardless of
        // which surface the decision came from.
        MacNotificationService.shared.onApprovalAction = { [weak self] approvalId, decision in
            Task { @MainActor in
                guard let self else { return }
                await self.handleApprovalDecision(approvalId: approvalId, decision: decision)
            }
        }

        // Wire the bridge dispatcher BEFORE the listener accepts connections.
        bridge.onIncomingFrame = { [weak self] data, connId in
            guard let self else { return }
            Task { @MainActor in await self.dispatcher.handleIncoming(data, connectionId: connId) }
        }
        bridge.onConnectionDropped = { [weak self] connId in
            guard let self else { return }
            Task { @MainActor in await self.dispatcher.handleConnectionDropped(connId) }
        }
        bridge.onConnectionAccepted = { [weak self] connId, remote in
            guard let self else { return }
            // Defer to the NEXT runloop tick (NOT a `Task @MainActor`, which can run
            // synchronously during a view update and trip "Publishing changes from
            // within view updates" → AttributeGraph cycle storms). This callback fires
            // from the bridge listener queue on every TCP accept, so under a flapping
            // iPhone reconnect loop it triggers many publishes per second; bouncing
            // through `DispatchQueue.main.async` guarantees each one lands on a clean
            // runloop and not inside SwiftUI's own update pass.
            DispatchQueue.main.async {
                // Stash the remote address against the connection id so
                // the dispatcher can derive the per-device transport
                // (LAN / Tailscale) once the device finishes
                // authenticating. Done here BEFORE updating
                // `pairingActivity` because the latter might briefly
                // bounce SwiftUI through a render pass.
                self.dispatcher.recordRemote(remote, for: connId)
                switch self.pairingActivity {
                case .idle, .connecting:
                    self.pairingActivity = .connecting(remote: remote)
                default: break
                }
            }
        }

        await bridge.start()
        bridgeStatus = .connected

        // Lock-state monitor — drives the iOS unlock-button visibility
        // gate. We start it AFTER the bridge is up so the very first
        // `broadcastProjectInfo` already carries an accurate
        // `isLocked` flag. The callback re-broadcasts ProjectInfo on
        // every transition so a paired iPhone sees the change in
        // real time without having to poll.
        MacLockMonitorService.shared.start()
        MacLockMonitorService.shared.onLockStateChanged = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.dispatcher.broadcastProjectInfo()
            }
        }

        // Start the local HTTP listener that `dnp-hook-relay` posts to.
        hookIngest.onHook = { [weak self] body in
            guard let self else { return }
            Task { @MainActor in await self.ingestHookRelayPayload(body) }
        }
        hookIngest.start()

        // Install hooks at the USER level (~/.claude/settings.json) so EVERY Claude session
        // — even ones started directly in a terminal outside our Mac app — fires PreToolUse
        // / Stop / etc. Without this the per-project `settings.local.json` only covers
        // projects we explicitly opened via the Mac app, which is why approvals weren't
        // showing up for sessions launched from `DNPNEW` etc.
        Self.installUserLevelHookSettings()

        // Tail Claude's transcript JSONLs as the source of truth for assistant replies.
        // Hooks (which require user-side permission acceptance) are still wired for richer
        // events, but the transcript path delivers plain assistant text 100% of the time.
        transcripts.onAssistantMessage = { [weak self] localSid, claudeSid, text in
            guard let self else { return }
            Task { @MainActor in
                await self.deliverAssistantMessage(localSid: localSid, claudeSid: claudeSid, text: text)
            }
        }
        transcripts.onUserMessage = { [weak self] localSid, claudeSid, text in
            guard let self else { return }
            Task { @MainActor in
                await self.deliverUserMessage(localSid: localSid, claudeSid: claudeSid, text: text,
                                              source: .hookRelay)
            }
        }
        transcripts.onToolActivity = { [weak self] localSid, toolName, summary, started in
            guard let self else { return }
            Task { @MainActor in
                await self.deliverToolActivity(localSid: localSid, toolName: toolName,
                                               summary: summary, started: started)
            }
        }
        transcripts.onCodeEdit = { [weak self] localSid, path, adds, removes, diff, kind in
            guard let self else { return }
            Task { @MainActor in
                await self.deliverCodeEdit(localSid: localSid, path: path,
                                            linesAdded: adds, linesRemoved: removes,
                                            diff: diff, kind: kind)
            }
        }
        transcripts.onThinking = { [weak self] localSid, text in
            guard let self else { return }
            Task { @MainActor in
                self.thinkingTexts[localSid] = text
                let evt = self.makeEvent(sid: localSid, type: .thinkingSummary, severity: .debug,
                                         title: "Thinking", summary: text)
                await self.dispatcher.emitLiveEvent(evt)
            }
        }
        transcripts.onUsage = { [weak self] localSid, input, cacheRead, cacheCreate, output, model in
            guard let self else { return }
            Task { @MainActor in
                await self.applyUsage(localSid: localSid, input: input, cacheRead: cacheRead,
                                      cacheCreate: cacheCreate, output: output, model: model)
            }
        }
        transcripts.onAITitle = { [weak self] localSid, title in
            guard let self else { return }
            Task { @MainActor in
                await self.applyClaudeAITitle(localSid: localSid, title: title)
            }
        }
        transcripts.onClaudeSessionDiscovered = { [weak self] localSid, claudeSid in
            guard let self else { return }
            Task { @MainActor in
                self.claudeSessionToLocal[claudeSid] = localSid
                if let i = self.sessions.firstIndex(where: { $0.id == localSid }) {
                    self.sessions[i].claudeSessionId = claudeSid
                    try? await self.persistence.sessions.upsert(self.sessions[i])
                }
                // Claude has spawned (`.jsonl` exists) — fire any prompts that were queued
                // while we waited for the TUI to come up. This is the "Claude is ready"
                // signal the previous fixed-sleep was approximating with a 1.2 s delay.
                await self.flushPendingPrompts(for: localSid)
            }
        }
        transcripts.start()

        // Live PTY-text mirror — every 750ms, snapshot the terminal of any session
        // whose iOS-side thinking indicator should be lit (= a turn is in flight) and
        // forward the cleaned tail to iOS as a `.thinkingSummary` event. This is what
        // makes the iOS indicator's secondary line read what Claude is ACTUALLY saying
        // instead of just the verb "Thinking" (the user's complaint that only the
        // word "thinking" appears). The transcript JSONL only commits whole turns so
        // it can't carry streaming text; the PTY can.
        liveTerminalPollTimer?.invalidate()
        liveTerminalPollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLiveTerminalText() }
        }

        // Claude Code AI usage — pull immediately on launch, then every 5 min.
        // Hits Anthropic's `/api/oauth/usage` endpoint with the user's
        // existing Claude Code OAuth token (no new credentials), parses the
        // 5h / 7d / Sonnet / Omelette utilisation %, and broadcasts the
        // snapshot to iOS so its Context popover can show the same numbers.
        Task { @MainActor in await self.refreshAIUsage() }
        aiUsageRefreshTimer?.invalidate()
        aiUsageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAIUsage() }
        }

        // Restore persisted sessions from disk + RE-LAUNCH each one so the IDE comes back
        // to a "live" state — terminals running, `claude --resume <id>` reattached, full
        // context intact. iOS sees them via the same `backfillFeed` path that ships
        // historical events on connect, so the iPhone mirrors the IDE the instant it
        // reconnects. Persistence files (`metadata.json` / `events.jsonl` /
        // `transcript.md`) are wiped in `confirmClose` so a closed session leaves no trace.
        let restored = (try? await persistence.sessions.list(includeArchived: false)) ?? []
        sessions = restored.map {
            var s = $0
            if s.status != .ended { s.status = .running }
            return s
        }
        // Backfill the in-memory feed from persistence so the chat history is visible the
        // moment the user reopens the app — and the iOS feed-backfill on reconnect mirrors it.
        for session in sessions {
            let events = await persistence.loadEvents(session.id)
            if !events.isEmpty { feed[session.id] = events }
        }
        // Eager re-launch: spawn each session's TerminalSession + start `claude --resume
        // <claudeSessionId>`. Honors the `claudeSessionId` we persisted at session creation
        // so Claude reattaches to the existing transcript instead of starting fresh — the
        // user's conversation continues exactly where it left off.
        for session in sessions where session.status != .ended {
            let terminal = TerminalSession()
            terminalSessions[session.id] = terminal
            autoLaunch(in: session)
        }
        if selectedSessionId == nil { selectedSessionId = sessions.first?.id }
        connectedDevices = await pairing.trustedDevices
        // Bootstrap intentionally does NOT auto-restore the last project — Cursor-style,
        // the user lands on the Welcome scene and picks (or re-picks from recents). This
        // way "open another project" doesn't fight a silent restore on cold start, and
        // the `RecentProjectsService` is the single source of truth for "what should I
        // open." The previous `restoreLastProject()` behaviour is preserved as a fallback
        // path used by the dock menu's "Open Last Project" entry.
        diagnostics = .init(claudePath: claude.detectedPath, claudeVersion: claude.detectedVersion,
                            ptyAvailable: PTYRuntimeService.ptyAvailable,
                            bridgePort: bridge.port,
                            issues: [])
    }

    /// Refresh the trusted-device list from the actor (call after pairing or revocation).
    func refreshTrustedDevices() async {
        connectedDevices = await pairing.trustedDevices
    }

    /// Permanently remove a paired device. Sends a `revoke` envelope FIRST so the iPhone
    /// gracefully unpairs (clears its stored Mac record + halts auto-reconnect), THEN drops
    /// the TCP connection. Without the heads-up the iPhone would just see a dropped socket
    /// and try to reconnect forever — the user explicitly asked for "remove on Mac → iOS
    /// disconnects immediately and stops trying".
    func removeDevice(_ id: UUID, reason: String? = nil) async {
        await dispatcher.sendRevoke(toDevice: id, reason: reason)
        dispatcher.dropAllConnections(forDevice: id)
        await pairing.forget(deviceId: id)
        connectedDeviceIds.remove(id)
        // Drop the per-device transport too so the row's "via LAN" /
        // "via Tailnet" badge can't linger after the device is gone.
        connectedDeviceTransports.removeValue(forKey: id)
        connectedDevices = await pairing.trustedDevices
    }

    /// Create a fresh session with its own terminal — auto-launches Claude (or shell) inside it.
    /// Existing sessions keep running in the background.
    @discardableResult
    func newSession() async -> Session {
        let session = await createNewSessionShell()
        autoLaunch(in: session)
        // Mirror the new selection into the active workspace so the IDE's tab strip
        // jumps to the freshly-created session — matters when iOS triggers the create
        // (`requestNewSession`): without this the Mac IDE kept the previous tab
        // selected even though the global `selectedSessionId` had moved on, so the
        // user had to manually click the new tab. The `if let` no-ops gracefully when
        // there is no active workspace yet (e.g. only the Welcome window is up).
        if let ws = activeWorkspace, ws.id.path == session.projectPath {
            ws.selectedSessionId = session.id
        }
        // Push the fresh list to any paired iOS device immediately.
        await dispatcher.broadcastSessionList()
        return session
    }

    /// Workspace-scoped session creation — used by per-window views so the new session
    /// belongs to **that** window's project rather than the singleton's "active"
    /// projectRoot. The window's `WorkspaceController` activates itself before calling
    /// this so the legacy internal paths (hook routing, transcript watcher) read the
    /// correct projectRoot. After creation, the calling workspace selects the new
    /// session locally; `coord.selectedSessionId` mirror is updated for legacy callers.
    ///
    /// `projectURL` is passed EXPLICITLY (workspace.projectRoot?.url) so the session's
    /// stored `projectPath` is bound to the workspace that asked — never to whatever
    /// `coord.projectRoot` happened to be at the moment `createNewSessionShell` ran.
    /// Without this, a near-simultaneous `activate()` from another window could leave
    /// `coord.projectRoot` stale by the time the awaitable session-shell function
    /// reads it, stamping a session with the wrong project path. The user reported
    /// this as "a session from another project showing up running here."
    @discardableResult
    func newSession(in workspace: WorkspaceController) async -> Session {
        // Make the workspace active so `createNewSessionShell` reads its projectRoot.
        workspace.activate()
        let session = await createNewSessionShell(projectURL: workspace.projectRoot?.url)
        autoLaunch(in: session)
        workspace.selectedSessionId = session.id
        await dispatcher.broadcastSessionList()
        return session
    }

    /// Create a session shell (Session record + empty TerminalSession) without launching anything.
    ///
    /// `projectURL` defaults to `coord.projectRoot?.url` for the legacy single-workspace
    /// path. Per-workspace callers (`newSession(in:)`, splits) pass it explicitly so the
    /// session is pinned to the requesting workspace, not whichever workspace happens to
    /// be active on `coord` at the moment.
    @discardableResult
    private func createNewSessionShell(projectURL: URL? = nil) async -> Session {
        let resolvedURL = projectURL ?? projectRoot?.url
        // Always stamp the canonical, slash-trimmed path so cross-workspace
        // session filters (`WorkspaceController.sessions`) match exactly even
        // when the same folder was opened with a trailing slash, via a
        // symlink, or with a `./` segment somewhere along the way.
        let projectPath = Self.normalizedProjectPath(resolvedURL?.path ?? NSHomeDirectory())
        let projectName = resolvedURL?.lastPathComponent ?? "Home"
        let nextNumber = (sessions.map(\.title).filter { $0.hasPrefix("Session ") }.count) + 1
        // Stamp GitHub backing on creation. iOS surfaces this as a per-session badge — cheap
        // to compute (just reads `.git/config`) and keeps each session pinned to whatever
        // remote / branch was active when it was spawned, even if the user later moves on.
        let gitHubInfo: SessionGitHubInfo? = {
            guard let url = resolvedURL, let info = GitHubProjectInfo.detect(at: url) else { return nil }
            return SessionGitHubInfo(nameWithOwner: info.nameWithOwner,
                                     webURL: info.webURL?.absoluteString,
                                     currentBranch: info.currentBranch)
        }()
        let session = Session(
            title: "Session \(nextNumber)",
            projectPath: projectPath,
            projectName: projectName,
            status: .running,
            lastActivityAt: Date(),
            gitHub: gitHubInfo
        )
        sessions.append(session)
        selectedSessionId = session.id
        sidebarTab = .sessions    // make the session visible immediately
        workspacePane = .terminal

        let terminal = TerminalSession()
        // Pin the terminal to its owning session so spawned children
        // inherit a `DNP_SESSION_ID` env var — the authoritative
        // routing key the hook relay echoes back to us.
        terminal.sessionId = session.id
        terminalSessions[session.id] = terminal

        try? await persistence.sessions.upsert(session)
        return session
    }

    /// Thin re-export of `DNPShared.PathUtilities.normalizedProjectPath`
    /// so existing call sites don't need to learn the new shared
    /// helper's name. The shared implementation is the source of truth
    /// — it's covered by `PathUtilitiesTests`.
    static func normalizedProjectPath(_ raw: String) -> String {
        PathUtilities.normalizedProjectPath(raw)
    }

    /// Auto-launch the appropriate process in this session's terminal. Honors `claudeSessionId`
    /// when present so a session restored from disk on reopen continues with `claude --resume`
    /// — preserving the entire conversation history across Mac app restarts.
    /// Watches for early-exit (within 3 seconds): if the PTY child dies that fast it almost
    /// certainly never started — we mark the session as `.crashed` and broadcast, so iOS
    /// won't show a session that isn't actually running.
    private func autoLaunch(in session: Session) {
        guard let terminal = terminalSessions[session.id] else { return }
        installLocalHookSettings(at: session.projectPath)
        transcripts.register(sessionId: session.id, projectPath: session.projectPath)
        if let claudePath = claude.detectedPath {
            var args: [String] = []
            if let resumeId = session.claudeSessionId, !resumeId.isEmpty {
                args = ["--resume", resumeId]
            }
            terminal.startCommand(claudePath, args: args, workingDirectory: session.projectPath)
        } else {
            terminal.startLoginShell(workingDirectory: session.projectPath)
        }
        // Failed-launch detector: if `isRunning` is still false 3s after spawn, mark the
        // session as crashed and broadcast so iOS drops it from the active list.
        let sid = session.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let term = terminalSessions[sid], !term.isRunning,
               let i = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[i].status = .crashed
                sessions[i].updatedAt = Date()
                try? await persistence.sessions.upsert(sessions[i])
                // Crash banner — distinct from the clean-close path so
                // the lock-screen copy reads "Session crashed" instead
                // of "Session ended".
                MacNotificationService.shared.fireSessionEnded(
                    sessionId: sessions[i].id,
                    sessionTitle: sessions[i].title,
                    reason: "crashed"
                )
                await dispatcher.broadcastSessionList()
            }
        }
    }

    /// Write `.claude/settings.local.json` into the given project, wiring every hook event to a
    /// SELF-CONTAINED shell relay we install at `~/Library/Application Support/DNPRemote/
    /// dnp-hook-relay`. The shell version doesn't depend on the Swift binary being on PATH or
    /// findable via repo walk — it's just curl + python3 (both shipped with every macOS).
    /// This is what fixes "approvals don't appear on iOS": before, the hook command pointed
    /// at a binary that wasn't installed, so Claude's hook silently no-op'd and we never saw
    /// PreToolUse events to raise approvals from.
    private func installLocalHookSettings(at projectPath: String) {
        let claudeDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Make sure the shell relay exists before referencing it. Installs on first use.
        let relay = Self.ensureShellRelayInstalled()

        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PermissionRequest", "Notification", "PreCompact", "SessionEnd",
                      "Stop", "SubagentStop"]
        var hooks: [String: Any] = [:]
        for ev in events {
            // Single-quote the relay path — `~/Library/Application Support/...` contains a
            // space, and Claude Code feeds the command to `/bin/sh -c` which would otherwise
            // split on it ("Application: No such file or directory").
            hooks[ev] = [["matcher": "*",
                          "hooks": [["type": "command",
                                     "command": "'\(relay)' --event \(ev)"]]]]
        }
        let settings: [String: Any] = ["hooks": hooks]
        let target = claudeDir.appendingPathComponent("settings.local.json")
        if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: target, options: .atomic)
        }
    }

    /// Merge our hook block into `~/.claude/settings.json` so EVERY Claude Code session —
    /// even ones not launched via our Mac app — calls our relay. Preserves any existing
    /// settings the user has there (we only overwrite the keys we own under `hooks`).
    /// Idempotent: safe to run on every Mac app launch.
    private static func installUserLevelHookSettings() {
        let userClaudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: userClaudeDir, withIntermediateDirectories: true)
        let target = userClaudeDir.appendingPathComponent("settings.json")

        let relay = ensureShellRelayInstalled()
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PermissionRequest", "Notification", "PreCompact", "SessionEnd",
                      "Stop", "SubagentStop"]
        var hooks: [String: Any] = [:]
        for ev in events {
            // Single-quote the relay path — see `installLocalHookSettings` for the reason.
            hooks[ev] = [["matcher": "*",
                          "hooks": [["type": "command",
                                     "command": "'\(relay)' --event \(ev)"]]]]
        }

        // Read whatever's already there, merge our hooks in, write back. If the file
        // doesn't exist or is invalid JSON we just write a fresh file with our block.
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: target),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        settings["hooks"] = hooks
        if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: target, options: .atomic)
        }
    }

    /// Idempotently writes the shell relay to a stable absolute path and returns that path.
    /// Path is `~/Library/Application Support/DNPRemote/dnp-hook-relay`. The script is
    /// regenerated each call (cheap; ensures upgrades land); we only chmod once.
    private static func ensureShellRelayInstalled() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DNPRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("dnp-hook-relay")

        let script = """
        #!/bin/bash
        # DNP Remote — self-contained Claude Code hook relay. Reads the hook payload on
        # stdin, builds an envelope, and POSTs it to the Mac app's HookIngestServer at
        # 127.0.0.1:18734. NEVER blocks Claude on relay errors — always exits 0.
        set +e
        EVENT=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --event) EVENT="$2"; shift 2;;
                *) shift;;
            esac
        done
        RAW=$(cat)
        TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        # JSON-encode the raw stdin string safely. Python is on every macOS install.
        JSON_RAW=$(printf '%s' "$RAW" | /usr/bin/python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')
        # `DNP_REMOTE` is the marker the Mac app sets on the env it spawns Claude with — see
        # `TerminalSession.startCommand`. It travels through Claude → hook subprocess → here,
        # and the Mac uses it to distinguish "this is one of our sessions" from foreign Claude
        # sessions the user runs in Terminal.app or another IDE (which don't have it set).
        # `DNP_SESSION_ID` is the per-session UUID — same env-vehicle, but unique to one
        # local session even when two sessions share a project. The Mac uses it as the
        # AUTHORITATIVE routing key so `cwd`-based fallback can never misattribute a hook
        # from session B onto session A's feed (the bug the user hit running parallel sessions).
        PAYLOAD=$(printf '{"event":"%s","timestamp":"%s","cwd":"%s","dnp_remote":"%s","dnp_session_id":"%s","pid":%d,"raw":%s}' \\
            "$EVENT" "$TS" "$PWD" "${DNP_REMOTE:-}" "${DNP_SESSION_ID:-}" "$$" "$JSON_RAW")
        /usr/bin/curl -s -m 2 -X POST \\
            -H "Content-Type: application/json" \\
            -d "$PAYLOAD" \\
            http://127.0.0.1:18734/hook > /dev/null 2>&1
        exit 0
        """

        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // chmod 0755 — idempotent.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }

    /// Single funnel for "Claude said X" — used by both the transcript watcher and the Stop
    /// hook. De-dupes by content hash per session, emits the bubble event to all paired iOS
    /// clients, and clears the thinking indicator.
    func deliverAssistantMessage(localSid: UUID, claudeSid: String, text: String) async {
        // Bind / refresh the Claude↔local mapping so any subsequent hook events route correctly.
        if !claudeSid.isEmpty { claudeSessionToLocal[claudeSid] = localSid }

        let key = text.hashValue
        if deliveredAssistantHashes[localSid]?.contains(key) == true { return }
        deliveredAssistantHashes[localSid, default: []].insert(key)

        let evt = makeEvent(sid: localSid, type: .assistantMessage, severity: .info,
                            title: "Claude", summary: text,
                            payload: .message(MessagePayload(role: .assistant, text: text)))
        await dispatcher.emitLiveEvent(evt)
        thinkingSessions.remove(localSid)
        thinkingTexts.removeValue(forKey: localSid)
    }

    /// Single funnel for "user said X" — covers BOTH iOS-originated prompts (via
    /// `handleIncomingUserPrompt`) and Mac-terminal-typed prompts (via the transcript watcher).
    /// Dedupes by content hash so the iOS feed never shows the same bubble twice.
    func deliverUserMessage(localSid: UUID, claudeSid: String, text: String,
                            source: SessionSource) async {
        if !claudeSid.isEmpty { claudeSessionToLocal[claudeSid] = localSid }

        // Skip whitespace-only / hook-injection prefixes (e.g. "<system-reminder>...").
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("[Request interrupted") {
            return
        }

        let key = trimmed.hashValue
        if deliveredUserHashes[localSid]?.contains(key) == true { return }
        deliveredUserHashes[localSid, default: []].insert(key)

        // First user message = the natural session title. Mirrors what Claude Code does in its
        // own session list. Only auto-set if the user hasn't already named the session.
        await maybeAutoTitleSession(localSid: localSid, fromFirstPrompt: trimmed)

        let evt = SessionEvent(
            sessionId: localSid,
            sequence: (feed[localSid]?.last?.sequence ?? 0) + 1,
            type: .userMessage, severity: .info,
            source: source,
            title: source == .ios ? "You (iOS)" : "You",
            summary: trimmed,
            payload: .message(MessagePayload(role: .user, text: trimmed)))
        await dispatcher.emitLiveEvent(evt)
        // A user message means the user is actively conversing — flip thinking on so the
        // indicator shows immediately on iOS even before Claude starts responding.
        thinkingSessions.insert(localSid)
    }

    /// Read the on-disk Claude transcript for a session and replay it as `SessionEvent`s
    /// for backfill. Used when iOS connects to a Mac that already had a Claude session
    /// running — the in-memory `feed[]` only carries events emitted since the Mac app
    /// booted, so we have to reconstruct historic content from the transcript file.
    /// Returns the LAST 200 events (`eventBackfillBatchSize`) so we don't blow up huge
    /// transcripts; iOS receives "the recent conversation" exactly as Claude has written it.
    func reconstructEventsFromTranscript(for session: Session) async -> [SessionEvent] {
        // 1. Locate the session's transcript file in `~/.claude/projects/<encoded>/`.
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(TranscriptWatcher.encodeProjectPath(session.projectPath))",
                                    isDirectory: true)
        let url: URL? = {
            // Prefer the file matching this session's stored Claude id, else the newest jsonl.
            if let claudeSid = session.claudeSessionId, !claudeSid.isEmpty {
                let candidate = projectDir.appendingPathComponent("\(claudeSid).jsonl")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return Self.newestTranscript(in: projectDir)
        }()
        guard let url else { return [] }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        // 2. Parse each line and turn it into a SessionEvent. Mirrors what the live
        //    watcher does, just over the file's full history instead of the tail.
        var out: [SessionEvent] = []
        var seq: UInt64 = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Skip sidechain (Task tool sub-agent) entries — those aren't part of the user's
            // visible conversation.
            if (obj["isSidechain"] as? Bool) == true { continue }
            let kind = obj["type"] as? String ?? ""
            switch kind {
            case "user":
                guard let message = obj["message"] as? [String: Any] else { continue }
                if Self.isToolResult(message) { continue }
                let text = Self.extractText(from: message)
                guard !text.isEmpty,
                      !text.hasPrefix("<system-reminder>"),
                      !text.hasPrefix("[Request interrupted") else { continue }
                seq += 1
                out.append(SessionEvent(
                    sessionId: session.id, sequence: seq,
                    type: .userMessage, severity: .info,
                    source: .hookRelay, title: "You", summary: text,
                    payload: .message(MessagePayload(role: .user, text: text))))
            case "assistant":
                guard let message = obj["message"] as? [String: Any] else { continue }
                let text = Self.extractText(from: message)
                if !text.isEmpty {
                    seq += 1
                    out.append(SessionEvent(
                        sessionId: session.id, sequence: seq,
                        type: .assistantMessage, severity: .info,
                        source: .hookRelay, title: "Claude", summary: text,
                        payload: .message(MessagePayload(role: .assistant, text: text))))
                }
            default:
                continue
            }
        }
        return Array(out.suffix(ProtocolConstants.eventBackfillBatchSize))
    }

    /// Newest `.jsonl` in the directory by file modification date.
    private static func newestTranscript(in dir: URL) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        return urls.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    private static func isToolResult(_ message: [String: Any]) -> Bool {
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == "tool_result" }
    }

    private static func extractText(from message: [String: Any]) -> String {
        if let content = message["content"] as? [[String: Any]] {
            let texts: [String] = content.compactMap {
                ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil
            }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let text = message["content"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Single source of truth for "what does THIS tool call act on" — drives both the
    /// approval card's `target` field AND the dedup key. Returning the same value from
    /// every hook path is what guarantees PreToolUse + PermissionRequest hashes collide
    /// (so we don't stack two cards for the same Edit/Write/Bash). Order matches the
    /// fields Claude actually uses per tool family.
    static func unifiedToolTarget(toolName: String, toolInput: [String: Any]?) -> String? {
        guard let input = toolInput else { return nil }
        // Bash — the command is always the meaningful payload.
        if toolName == "Bash" {
            return (input["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        // File-touching tools — the path is THE identity.
        if let p = input["file_path"] as? String, !p.isEmpty { return p }
        if let p = input["path"] as? String,      !p.isEmpty { return p }
        // Search-y tools.
        if let q = input["pattern"] as? String,   !q.isEmpty { return q }
        if let q = input["query"] as? String,     !q.isEmpty { return q }
        if let u = input["url"] as? String,       !u.isEmpty { return u }
        // Generic command-style tools.
        if let c = input["command"] as? String,   !c.isEmpty { return c }
        return nil
    }

    /// Decide whether THIS specific tool invocation deserves an iOS approval card.
    /// Edit / Write / MultiEdit / NotebookEdit always do — they modify files. For Bash we
    /// only flag commands Claude itself pauses on (push, install, rm, sudo, etc.); raising
    /// approvals for read-only Bash like `git status` was wrong because Claude doesn't
    /// wait for confirmation, and our `1\r` answer would be sent as a stray prompt.
    static func toolNeedsApproval(_ toolName: String, bashCommand: String? = nil) -> Bool {
        switch toolName {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return true
        case "Bash":
            return Self.bashIsRisky(bashCommand)
        default:
            return false
        }
    }

    /// Heuristic that picks out the Bash invocations that match Claude's own "ask before
    /// running" rules. Returns `true` for commands that touch the network, the filesystem
    /// in a write-y way, or escalate privileges. Anything else (status / log / ls / cat /
    /// find / grep / which / pwd / etc.) is treated as safe and silently auto-runs.
    static func bashIsRisky(_ raw: String?) -> Bool {
        guard let cmd = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty
        else { return false }
        let lower = cmd.lowercased()
        // Pattern catalog — match the START of pipeline segments to avoid false positives
        // (e.g. `cat foo | grep "rm "` shouldn't trigger).
        let riskyTokens = [
            "git push", "git commit", "git rebase", "git reset", "git merge", "git cherry-pick",
            "git tag", "git branch -d", "git branch -f",
            "rm ", "rmdir", "mv ", "cp ",
            "brew install", "brew uninstall", "brew upgrade",
            "npm install", "npm uninstall", "npm publish",
            "yarn add", "yarn remove",
            "pnpm add", "pnpm remove", "pnpm publish",
            "pip install", "pip uninstall", "pip3 install",
            "uv add", "uv pip install",
            "cargo install", "cargo publish",
            "gem install", "bundle install",
            "go install", "go get",
            "make ", "make install", "cmake --install",
            "apt-get", "apt install", "dnf install", "yum install",
            "chmod", "chown",
            "curl ", "wget ", "scp ", "rsync ",
            "docker run", "docker rm", "docker rmi", "docker build", "docker push",
            "kubectl apply", "kubectl delete", "helm install", "helm upgrade",
            "terraform apply", "terraform destroy",
            "gh repo create", "gh repo delete", "gh pr create", "gh pr merge",
            "ssh ",
            "killall", "kill -9",
            "systemctl", "launchctl",
            "defaults write", "defaults delete",
            "softwareupdate"
        ]
        for token in riskyTokens {
            if lower.contains(token) { return true }
        }
        // Sudo gates everything regardless of command.
        if lower.hasPrefix("sudo ") || lower.contains(" sudo ") { return true }
        // Output redirection that creates/overwrites files (`> foo` / `>> foo`) — exclude
        // `2>&1` / `>/dev/null` etc. by checking for a real word after the redirection.
        if let r = lower.range(of: ">\\s*[^&/\\s]", options: .regularExpression) {
            let _ = r; return true
        }
        return false
    }

    /// Build an `ApprovalRequest` for an upcoming risky tool call, dedupe per-session per-
    /// tool-target, store on `vm.pendingApprovals`, and emit a live event so the iOS
    /// `ApprovalCarouselView` shows it. The approval id is what comes back via
    /// `approvalResponse`; `handleApprovalDecision` (below) uses the id to find the request,
    /// look up its session, and inject "1\r" or "2\r" into that session's PTY — answering
    /// Claude's inline TUI prompt.
    func raiseApproval(sessionId: UUID, toolName: String, target: String) async {
        // No in-function dedup anymore. The hook-driven raise paths are gone (only
        // the PTY poller calls this), and the poller already gates on
        // `pending == nil` + `approvalRaiseInFlight`, so duplicate concurrent calls
        // can't happen. The previous content-hash dedup ALSO blocked legitimate
        // re-prompts: when Claude prompted, we silently dismissed (turn moved on),
        // and Claude re-prompted for the same tool a beat later, the second raise
        // returned early on the stale hash and iOS saw nothing — exactly the
        // "didn't pop when it should have" bug the user reported.
        let actionType: ApprovalActionType = {
            switch toolName {
            case "Bash":                       return .bashCommand
            case "Edit", "MultiEdit":          return .fileEdit
            case "Write", "NotebookEdit":      return .fileWrite
            default:                           return .other
            }
        }()
        let approval = ApprovalRequest(
            sessionId: sessionId,
            actionType: actionType,
            target: target,
            summary: "Claude wants to run \(toolName)",
            risk: toolName == "Bash"
                ? RiskClassifier.risk(forBash: target)
                : .medium,
            timeoutAt: Date().addingTimeInterval(ProtocolConstants.approvalDefaultTimeoutSeconds)
        )
        await approvals.create(approval)
        pendingApprovals.append(approval)
        surfaceApprovalLocally(approval)

        let evt = makeEvent(sid: sessionId, type: .approvalRequired, severity: .warning,
                            title: "Approval requested", summary: target,
                            payload: .approval(ApprovalEventPayload(
                                approvalId: approval.id, lifecycle: .requested,
                                actionSummary: target, request: approval)))
        await dispatcher.emitLiveEvent(evt)
    }

    /// Called by the dispatcher when iOS sends an approvalResponse. Resolves the request,
    /// types the corresponding answer into Claude's inline TUI prompt (1 = Yes, 2 = No),
    /// and emits an approvalResult event so iOS removes the card.
    /// Fire the Mac-side surfaces for a freshly-created approval: time-sensitive system
    /// banner + (optional) floating popup pinned above all of the app's windows. Both are
    /// gated by user-controlled toggles in Settings, so this is a no-op when the user has
    /// the surfaces disabled. Called from every approval-creation path (PreToolUse hook,
    /// PermissionRequest hook, transcript-derived raises) so a request shows up everywhere
    /// regardless of which trigger produced it.
    private func surfaceApprovalLocally(_ approval: ApprovalRequest) {
        let title = sessions.first(where: { $0.id == approval.sessionId })?.title ?? "Session"
        // Clear any generic "Claude needs attention" banner for this session — the
        // structured approval is the more specific signal and supersedes it.
        MacNotificationService.shared.clearAttention(sessionId: approval.sessionId)
        MacNotificationService.shared.fireApprovalRequest(
            approvalId: approval.id,
            sessionId: approval.sessionId,
            sessionTitle: title,
            summary: approval.summary,
            risk: approval.risk
        )
        MacApprovalPopupController.shared.present(
            approvalId: approval.id,
            sessionTitle: title,
            summary: approval.summary,
            risk: approval.risk,
            actionType: approval.actionType,
            onApprove: { [weak self] in
                Task { @MainActor in
                    await self?.handleApprovalDecision(approvalId: approval.id, decision: .approve)
                }
            },
            onDeny: { [weak self] in
                Task { @MainActor in
                    await self?.handleApprovalDecision(approvalId: approval.id, decision: .reject)
                }
            }
        )
    }

    func handleApprovalDecision(approvalId: UUID, decision: ApprovalDecision) async {
        // Look up the approval first — we need the sessionId to build the response.
        let snapshot = await approvals.snapshot()
        let approval: ApprovalRequest? = snapshot.first(where: { $0.id == approvalId })
            ?? pendingApprovals.first(where: { $0.id == approvalId })
        guard let approval else {
            // Unknown id — stale UI lying around. Just clean it up.
            MacNotificationService.shared.clearApprovalRequest(approvalId: approvalId)
            MacApprovalPopupController.shared.dismiss(approvalId: approvalId)
            return
        }
        let sid = approval.sessionId

        // CRITICAL idempotency gate. The actor's `apply(...)` is the single source of
        // truth for "is this the FIRST decision on this approval?" — `.accepted` means
        // yes (we type into the PTY + broadcast); `.alreadyDecided` / `.notFound` /
        // `.expired` mean someone else already resolved it (iOS retry, multi-device
        // race, banner-then-popup double-tap, dispatcher pre-apply, etc.).
        //
        // The previous form pre-applied in the dispatcher and then UNCONDITIONALLY
        // typed `1\r` here — so the iOS belt-and-suspenders 1.5s resend caused a
        // second `1\r` to land while Claude was no longer at a prompt, and the digit
        // leaked into the chat as a regular user message. Routing every caller through
        // this single `apply` gate kills the duplicate.
        let macDeviceId = await pairing.macDeviceId
        let response = ApprovalResponse(
            approvalId: approvalId, sessionId: sid,
            decision: decision, deviceId: macDeviceId
        )
        let result = await approvals.apply(response)

        // Always clean local UI — banner + popup + sidebar mirror — regardless of
        // whether this was the first decision or a duplicate. Stale UI is what the
        // user sees as "phantom approval" reappearing.
        pendingApprovals.removeAll { $0.id == approvalId }
        MacNotificationService.shared.clearApprovalRequest(approvalId: approvalId)
        MacApprovalPopupController.shared.dismiss(approvalId: approvalId)

        // PTY write rules:
        //   • `.accepted` → first decision, always write the digit.
        //   • `.alreadyDecided` → another path (iOS, banner, this same panel
        //     pressed twice in 100ms) already typed the digit. SKIP only if
        //     the previous write happened recently (< 2s); otherwise write
        //     again so the user's repeat-click on the Mac panel ISN'T silent
        //     when Claude was still bringing up its inline prompt and missed
        //     the first keystroke. The user explicitly reported "I clicked
        //     Allow on the Mac panel and Claude didn't proceed — I had to
        //     manually type 1 in the terminal." That's exactly this race.
        //   • `.notFound` / `.expired` → the approval is gone, never type.
        let now = Date()
        let shouldWrite: Bool
        switch result {
        case .accepted:
            shouldWrite = true
        case .alreadyDecided:
            let last = lastApprovalPTYWriteAt[sid] ?? .distantPast
            shouldWrite = now.timeIntervalSince(last) > 2.0
            if shouldWrite {
                print("[Approval] alreadyDecided but >2s since last PTY write — re-sending digit for resilience")
            }
        case .notFound, .expired:
            shouldWrite = false
        }
        if shouldWrite, let term = terminalSessions[sid] {
            // Last-line defense against the "1 leaked into chat" bug: only write the
            // digit when Claude's inline prompt is ACTUALLY on screen. If the prompt
            // text isn't visible (Claude already moved on, or this is a phantom
            // card the user is approving after the fact), the PTY is at the regular
            // chat input and "1\r" would land as a stray user message — exactly the
            // bug the user keeps reporting. The dedup work above mostly prevents
            // this, but multi-device races / network retries can still get us here
            // with a stale decision; this is the catch-all.
            if term.isAtClaudePrompt() {
                term.sendInput(decision == .approve ? "1\r" : "2\r")
                lastApprovalPTYWriteAt[sid] = now
            } else {
                print("[Approval] suppressed PTY write — Claude is not at its inline prompt (decision=\(decision), sid=\(sid.uuidString.prefix(8)))")
            }
        }
        // For non-accepted results, skip the broadcast/event emission below — only
        // the original decision should produce the chat-feed `approvalResult` event.
        guard case .accepted = result else { return }

        let lifecycle: ApprovalLifecycle = (decision == .approve) ? .approved : .rejected
        let evt = makeEvent(sid: sid, type: .approvalResult, severity: .info,
                            title: decision == .approve ? "Approved" : "Rejected",
                            summary: approval.target,
                            payload: .approval(ApprovalEventPayload(
                                approvalId: approvalId, lifecycle: lifecycle,
                                actionSummary: approval.target, request: approval)))
        await dispatcher.emitLiveEvent(evt)
    }

    /// User-driven "force allow" — types `1\r` into the named session's PTY without
    /// going through the approval-card lifecycle. This is the iOS escape hatch
    /// when our PTY-driven approval detector misses a real prompt and an approval
    /// card never surfaced; the user can still confirm Claude's pending action.
    ///
    /// We DELIBERATELY skip the `isAtClaudePrompt()` guard here. The whole point
    /// of the force button is to let the user override the auto-detector when it
    /// fails — applying the same detector to this path would re-introduce the
    /// false-negative the user is trying to bypass. The risk (digit leaks into a
    /// chat input) is the user's accepted trade-off; the iOS button explicitly
    /// reads as "force allow" and the user can hide it from Settings.
    func forceApprove(sessionId: UUID) async {
        guard let term = terminalSessions[sessionId] else {
            print("[ForceApprove] no terminal for sid=\(sessionId.uuidString.prefix(8))")
            return
        }
        let atPrompt = term.isAtClaudePrompt()
        print("[ForceApprove] sid=\(sessionId.uuidString.prefix(8)) atPrompt=\(atPrompt) — typing 1\\r")
        term.sendInput("1\r")
        lastApprovalPTYWriteAt[sessionId] = Date()
        // Clear any pending card for this session so iOS doesn't keep showing a
        // stale approval after the force write resolved Claude's prompt.
        if let pending = pendingApprovals.first(where: { $0.sessionId == sessionId }) {
            pendingApprovals.removeAll { $0.id == pending.id }
            MacNotificationService.shared.clearApprovalRequest(approvalId: pending.id)
            MacApprovalPopupController.shared.dismiss(approvalId: pending.id)
            let evt = makeEvent(sid: sessionId, type: .approvalResult, severity: .info,
                                title: "Approved (force)",
                                summary: pending.target,
                                payload: .approval(ApprovalEventPayload(
                                    approvalId: pending.id, lifecycle: .approved,
                                    actionSummary: pending.target, request: pending)))
            await dispatcher.emitLiveEvent(evt)
        }
    }

    /// Push a `codeEditSummary` event for an Edit/Write/MultiEdit invocation. Carries the
    /// unified diff so iOS can render coloured `+`/`-` lines per row.
    func deliverCodeEdit(localSid: UUID, path: String, linesAdded: Int, linesRemoved: Int,
                         diff: String, kind: String) async {
        let key = "edit|\(path)|\(linesAdded)|\(linesRemoved)|\(diff.hashValue)"
        if deliveredToolKeys[localSid]?.contains(key) == true { return }
        deliveredToolKeys[localSid, default: []].insert(key)

        let changeKind: CodeChangeKind = {
            switch kind {
            case "write":     return .created
            default:          return .modified
            }
        }()
        let payload = CodeEditPayload(
            filePath: path,
            changeKind: changeKind,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            summary: "+\(linesAdded)/-\(linesRemoved) in \((path as NSString).lastPathComponent)",
            diffPreview: diff,
            toolSource: kind
        )
        let evt = makeEvent(sid: localSid, type: .codeEditSummary, severity: .info,
                            title: "Edit: \((path as NSString).lastPathComponent)",
                            summary: payload.summary,
                            payload: .codeEdit(payload))
        await dispatcher.emitLiveEvent(evt)

        // Track the edited path under its session's project root so the file explorer
        // can decorate the row + every ancestor folder with the "modified" badge.
        // We key off the session's `projectPath` so an edit raised in project A's
        // session doesn't decorate project B's tree even when both windows are open.
        if let session = sessions.first(where: { $0.id == localSid }) {
            let normalizedRoot = URL(fileURLWithPath: session.projectPath).standardizedFileURL.path
            let normalizedFile = URL(fileURLWithPath: path).standardizedFileURL.path
            editedFilesByProject[normalizedRoot, default: []].insert(normalizedFile)
            // Stash the diff text for the inline banner above CodeEditorView.
            // Only keep the LATEST diff per file — the banner shows the most
            // recent change, not a running log.
            lastDiffByFile[normalizedFile] = diff
        }
    }

    /// Auto-derive a friendly session title from the first user prompt — but only when the
    /// session is still wearing one of our auto-generated default titles. If the user (or
    /// Claude) has already given the session a real name, we leave it alone.
    private func maybeAutoTitleSession(localSid: UUID, fromFirstPrompt text: String) async {
        guard let i = sessions.firstIndex(where: { $0.id == localSid }) else { return }
        // If Claude has already named this session via `ai-title`, never override.
        if claudeNamedSessions.contains(localSid) { return }
        let current = sessions[i].title
        let isDefault = current.hasPrefix("Session ")
                     || current.hasPrefix("Claude · ")
                     || current.isEmpty
        guard isDefault else { return }
        // Already auto-titled by an earlier user message in this session.
        if userMessageCount(localSid: localSid) > 1 { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? trimmed
        let candidate = firstLine.prefix(48)
        let title = candidate.count < firstLine.count
            ? "\(candidate)…"
            : String(candidate)
        guard !title.isEmpty else { return }

        sessions[i].title = title
        sessions[i].updatedAt = Date()
        try? await persistence.sessions.upsert(sessions[i])
        await dispatcher.broadcastSessionList()
    }

    /// How many user messages we've already broadcast for this session — used to gate the
    /// auto-title path so it only fires on the FIRST prompt.
    private func userMessageCount(localSid: UUID) -> Int {
        return (feed[localSid] ?? []).filter { $0.type == .userMessage }.count
    }

    /// Periodic PTY scrape. Two responsibilities:
    ///
    /// 1. **Live thinking text** — for sessions whose iOS-side indicator should be
    ///    lit, mirror the visible terminal as a `.thinkingSummary` event so the
    ///    indicator's secondary line shows what Claude is actually saying.
    ///
    /// 2. **Approval lifecycle from the PTY (the real source of truth)** — for every
    ///    session with a terminal, check whether Claude's `Do you want to proceed?`
    ///    inline prompt is visible. If yes AND no approval is pending → raise one
    ///    using the cached `pendingHookCalls` context. If a pending approval exists
    ///    AND the prompt is no longer visible past the grace period → silently
    ///    dismiss (Claude already auto-allowed, or the user pressed `1` directly
    ///    in the Mac terminal). This is what eliminates the false-positive `allow`
    ///    cards the user kept seeing — hooks fire ahead of the prompt and don't
    ///    always lead to one, so we wait for the PTY to confirm before bothering iOS.

    /// Pull a fresh AI Usage snapshot from `ClaudeUsageService` and broadcast
    /// it. Called from the 5-minute timer in `bootstrap()` and on every iOS
    /// reconnect via `BridgeDispatcher.broadcastAIUsage`.
    func refreshAIUsage() async {
        let snapshot = await ClaudeUsageService.shared.fetchSnapshot()
        self.aiUsage = snapshot
        await dispatcher.broadcastAIUsage(snapshot: snapshot)
    }

    /// Wired from `WorkspaceController.selectedSessionId.didSet` —
    /// every time the user clicks a different session pane on the Mac
    /// IDE, push the new id to all paired iOS clients so the iPhone
    /// session capsule auto-follows.
    ///
    /// Idempotent: a no-op when the id hasn't actually changed (so
    /// SwiftUI updates that re-fire the observer with the same value
    /// don't spam the bridge).
    ///
    /// Implementation note: the entire body runs in a `Task { @MainActor }`
    /// so the cache write + broadcast spawn ALWAYS land on the next
    /// runloop tick, never inside the SwiftUI render pass that
    /// triggered the `selectedSessionId` mutation. This is the second
    /// half of the freeze fix: `applyPrunedTree` re-anchors selection
    /// from inside `TerminalSplitContainer.onChange`, whose body sits
    /// in the view-update path; a synchronous broadcast/cache update
    /// from the didSet was racing AttributeGraph and hanging the app
    /// when the user opened a split. Deferring keeps every subsequent
    /// state touch out of that critical section.
    func notifyActiveSessionChanged(_ sessionId: UUID?) {
        Task { @MainActor in
            guard sessionId != self.lastBroadcastActiveSessionId else { return }
            self.lastBroadcastActiveSessionId = sessionId
            await self.dispatcher.broadcastActiveSession(sessionId: sessionId)
        }
    }

    private func pollLiveTerminalText() {
        // Live thinking-text mirror — only walks `thinkingSessions` because that's
        // the cheap signal that "a turn is in flight". Skipped when no session is
        // thinking so the BufferLine walk is paid only when needed. This is the
        // expensive part of the poll (a 30-line BufferLine snapshot per
        // thinking session); keeping it gated saves the bulk of the cost.
        if !thinkingSessions.isEmpty {
            for sid in thinkingSessions {
                guard let term = terminalSessions[sid] else { continue }
                let raw = term.recentVisibleText(maxLines: 30)
                let cleaned = Self.filterClaudeTUI(raw)
                guard !cleaned.isEmpty else { continue }
                if lastBroadcastLiveText[sid] == cleaned { continue }
                lastBroadcastLiveText[sid] = cleaned
                thinkingTexts[sid] = cleaned
                let evt = self.makeEvent(sid: sid, type: .thinkingSummary, severity: .debug,
                                         title: "Thinking", summary: cleaned)
                Task { await self.dispatcher.emitLiveEvent(evt) }
            }
        }

        // Approval lifecycle — MUST run across ALL sessions with a terminal,
        // not just sessions that have cached hook context. An earlier
        // optimisation gated this loop on `pendingHookCalls.keys ∪
        // pendingApprovals.sessionIds ∪ approvalRaiseInFlight`; that
        // dropped approval cards in two real cases:
        //   1. Tools where the PreToolUse hook fires but our classifier
        //      `Self.toolNeedsApproval` returns false (so no hook context
        //      gets cached) — Claude can still surface its inline prompt.
        //   2. Hooks deferred / disabled / not-yet-bound for a session
        //      Claude already started prompting on (cwd binding races).
        // Both produce a real `Do you want to proceed?` headline that the
        // user is staring at, but no card on iOS / no Allow popup on Mac.
        // Reverting to "iterate every terminal" guarantees the PTY scan
        // catches the prompt regardless of hook state. `isAtClaudePrompt()`
        // is a small fixed-line buffer scan, so the cost is bounded per
        // session even with many parallel terminals.
        for (sid, term) in terminalSessions {
            let prompted = term.isAtClaudePrompt()
            let pending  = pendingApprovals.first(where: { $0.sessionId == sid })

            if prompted, pending == nil, !approvalRaiseInFlight.contains(sid) {
                // PTY confirms a real prompt and no card is up yet → raise.
                let context = pendingHookCalls[sid]
                let toolName = context?.toolName ?? "Tool"
                let target   = context?.target ?? Self.scrapePromptTarget(from: term)
                              ?? "(awaiting confirmation)"
                approvalRaiseInFlight.insert(sid)
                Task { @MainActor in
                    await self.raiseApproval(sessionId: sid, toolName: toolName, target: target)
                    self.approvalRaiseInFlight.remove(sid)
                }
            } else if !prompted, let pending {
                // Card up but Claude isn't (or no longer) at a prompt. Wait out a
                // grace period before dismissing — SwiftTerm can briefly re-paint.
                let firstSeen = approvalNotPromptedSince[pending.id] ?? Date()
                approvalNotPromptedSince[pending.id] = firstSeen
                if Date().timeIntervalSince(firstSeen) > 1.5 {
                    approvalNotPromptedSince.removeValue(forKey: pending.id)
                    Task { @MainActor in
                        await self.silentlyDismissStaleApproval(pending,
                                                                reason: "PTY prompt vanished")
                    }
                }
            } else if prompted, let pending {
                // Prompt still up — reset any in-flight grace timer.
                approvalNotPromptedSince.removeValue(forKey: pending.id)
            }
        }
    }

    /// Best-effort target line scrape for a prompt that surfaced WITHOUT a cached
    /// hook context (hooks lagging or disabled). We read the line just above the
    /// `Do you want to proceed?` headline — that's where Claude prints what it's
    /// asking permission for (e.g. `Bash command (3.4s)` or `Edit file foo.swift`).
    private static func scrapePromptTarget(from term: TerminalSession) -> String? {
        let snapshot = term.recentVisibleText(maxLines: 30)
        let lines = snapshot.split(separator: "\n").map(String.init)
        guard let headlineIdx = lines.firstIndex(where: { $0.contains("Do you want") || $0.contains("Allow Claude") }) else {
            return nil
        }
        // Walk backward for the first non-empty, non-decorator line above the headline.
        var i = headlineIdx - 1
        while i >= 0 {
            let candidate = lines[i].trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty,
               !candidate.hasPrefix("─"), !candidate.hasPrefix("━"),
               !candidate.hasPrefix("⎿"), !candidate.hasPrefix("│") {
                return candidate
            }
            i -= 1
        }
        return nil
    }

    /// Dismiss an approval that the PTY says is no longer real (Claude moved on,
    /// user pressed `1` directly in the Mac terminal, hook fired without a
    /// follow-up prompt, etc.). Mirrors the cleanup arm of
    /// `handleApprovalDecision` minus the PTY write — we explicitly DO NOT type
    /// a digit because Claude isn't there to receive it. iOS gets an
    /// `.approvalResult` event with `.expired` lifecycle so the card disappears.
    func silentlyDismissStaleApproval(_ approval: ApprovalRequest, reason: String) async {
        // Only dismiss if it's still actually pending — the user might have
        // tapped Approve/Reject in the same tick.
        guard pendingApprovals.contains(where: { $0.id == approval.id }) else { return }
        print("[Approval] silently dismissing \(approval.id.uuidString.prefix(8)) — \(reason)")
        pendingApprovals.removeAll { $0.id == approval.id }
        MacNotificationService.shared.clearApprovalRequest(approvalId: approval.id)
        MacApprovalPopupController.shared.dismiss(approvalId: approval.id)
        let evt = makeEvent(sid: approval.sessionId, type: .approvalResult, severity: .info,
                            title: "Approval no longer required",
                            summary: approval.target,
                            payload: .approval(ApprovalEventPayload(
                                approvalId: approval.id, lifecycle: .expired,
                                actionSummary: approval.target, request: approval)))
        await dispatcher.emitLiveEvent(evt)
    }

    /// Trim Claude's TUI scraping down to the substantive lines: drop the prompt-input
    /// row (`> `), separators, the status bar at the bottom (`? for shortcuts`), and
    /// the "Worked for Ns" footer. What's left is the visible reasoning + tool output
    /// — exactly what the user wants to see streaming on iOS.
    private static func filterClaudeTUI(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop chrome rows that aren't part of the conversation content.
        let cleaned = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            // Status / hint bars Claude paints at the bottom of its TUI.
            if trimmed.hasPrefix("? for shortcuts") { return false }
            if trimmed.hasPrefix("─") || trimmed.hasPrefix("━") { return false }
            // Empty composer row at the very bottom (just the leading `>`).
            if trimmed == ">" || trimmed == "│ >" { return false }
            return true
        }
        // Cap output length so a 1MB buffer scrape doesn't blow up envelopes.
        let joined = cleaned.suffix(20).joined(separator: "\n")
        if joined.count > 1200 {
            return String(joined.suffix(1200))
        }
        return joined
    }

    /// Adopt the title Claude Code generated for this session (`ai-title` line in the
    /// JSONL transcript). Claude's title takes priority over our prompt-derived
    /// auto-title — the session is marked Claude-named so future prompt arrivals don't
    /// overwrite it. No-op if the title is unchanged so we don't spam persistence /
    /// broadcasts when Claude re-emits the same `ai-title` line.
    func applyClaudeAITitle(localSid: UUID, title: String) async {
        guard let i = sessions.firstIndex(where: { $0.id == localSid }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Idempotent: if we already adopted this exact title, just record the lock.
        if sessions[i].title == trimmed {
            claudeNamedSessions.insert(localSid)
            return
        }
        sessions[i].title = trimmed
        sessions[i].updatedAt = Date()
        claudeNamedSessions.insert(localSid)
        try? await persistence.sessions.upsert(sessions[i])
        await dispatcher.broadcastSessionList()
    }

    /// Single funnel for tool activity (Bash, Read, Edit, Glob, Grep, ...). `started=true` for
    /// new invocations, `false` for completion. De-dupes per session via name+summary.
    func deliverToolActivity(localSid: UUID, toolName: String, summary: String?,
                             started: Bool) async {
        let key = "\(toolName)|\(summary ?? "")|\(started ? "start" : "end")"
        if deliveredToolKeys[localSid]?.contains(key) == true { return }
        deliveredToolKeys[localSid, default: []].insert(key)

        // If a tool actually starts running for this session AND there's a pending approval
        // matching that tool, the user must have answered the prompt directly in Claude
        // (typed "1" / "y" themselves on the Mac terminal) — Claude wouldn't proceed
        // otherwise. Auto-clear the pending approval so iOS doesn't keep showing a stale
        // "Approve / Deny" card after the user already decided in the IDE.
        if started {
            await reconcilePendingApproval(sessionId: localSid, executingToolName: toolName)
        }

        let title = started ? "Tool: \(toolName)" : "Tool completed: \(toolName)"
        let provider: ToolProvider = toolName.hasPrefix("mcp__") ? .mcp : .builtIn
        let evt = makeEvent(sid: localSid, type: .toolActivity,
                            severity: .info,
                            title: title, summary: summary,
                            payload: .toolActivity(ToolActivityPayload(
                                toolName: toolName,
                                provider: provider,
                                status: started ? .started : .completed)))
        await dispatcher.emitLiveEvent(evt)
    }

    /// Mark a pending approval as resolved when the user manually approved in Claude's IDE.
    /// Called from `deliverToolActivity` on the rising edge of a `started` event — proof
    /// that Claude got past its `1. Yes / 2. No` permission prompt without going through
    /// our `handleApprovalDecision` path.
    private func reconcilePendingApproval(sessionId: UUID, executingToolName: String) async {
        // Match the most recent pending approval for this session whose action type maps
        // to the executing tool. We don't try to match precise targets (Bash command text
        // varies between hook payload and execution) — same session + same tool family is
        // strong enough.
        let candidates = pendingApprovals.filter { $0.sessionId == sessionId }
        guard !candidates.isEmpty else { return }

        let toolFamily: ApprovalActionType = {
            switch executingToolName {
            case "Bash":                  return .bashCommand
            case "Edit", "MultiEdit":     return .fileEdit
            case "Write", "NotebookEdit": return .fileWrite
            default:                       return .other
            }
        }()
        // Strict match by action-type — no fallback. The previous fallback to
        // `candidates.last` could clear an unrelated pending approval when a non-matching
        // tool started running, which would either (a) make iOS lose a real pending
        // request silently or (b) send an unwanted approve signal. Better to leave a real
        // approval pending than to clear the wrong one.
        guard let match = candidates.last(where: { $0.actionType == toolFamily })
        else { return }

        // Cleanup mirrors the in-app `handleApprovalDecision` cleanup, minus the PTY write
        // (the user already typed the answer themselves) and minus the actor `apply` (no
        // ApprovalResponse to apply — there isn't one). Broadcasts an `approvalResult` so
        // every paired iOS client clears its overlay / inline card / system banner.
        await approvals.markAppliedToRuntime(match.id)
        pendingApprovals.removeAll { $0.id == match.id }
        MacNotificationService.shared.clearApprovalRequest(approvalId: match.id)
        MacApprovalPopupController.shared.dismiss(approvalId: match.id)

        let evt = makeEvent(sid: sessionId, type: .approvalResult, severity: .info,
                            title: "Approved in IDE",
                            summary: match.target,
                            payload: .approval(ApprovalEventPayload(
                                approvalId: match.id, lifecycle: .appliedToRuntime,
                                actionSummary: match.target, request: match)))
        await dispatcher.emitLiveEvent(evt)
    }

    /// Send SIGINT (Ctrl-C) into the named session's terminal, interrupting whatever Claude /
    /// shell process is running in it. Followed by a Stop hook that clears the thinking state.
    func cancelRunningTurn(sessionId: UUID) async {
        guard let term = terminalSessions[sessionId] else { return }
        // 0x03 = ETX = Ctrl-C. Most TUIs (including Claude's) translate this into "abort current
        // input/turn" — they re-enter the prompt waiting for the next request.
        term.sendInput("\u{03}")
        thinkingSessions.remove(sessionId)
        let evt = makeEvent(sid: sessionId, type: .warning, severity: .notice,
                            title: "Cancelled by user",
                            payload: .warning(WarningPayload(code: "user.cancel",
                                                             title: "Cancelled by user")))
        await dispatcher.emitLiveEvent(evt)
    }

    /// Returns the active session's terminal — creating a session if none exists yet.
    /// Does NOT auto-launch anything (the caller will spawn a process explicitly).
    private func ensureCurrentTerminal() async -> TerminalSession {
        if let id = selectedSessionId, let term = terminalSessions[id] { return term }
        let session = await createNewSessionShell()
        return terminalSessions[session.id]!
    }

    /// Show the confirmation dialog for closing a session.
    ///
    /// Uses an AppKit `NSAlert` sheet attached to the main window instead of SwiftUI's
    /// `.confirmationDialog`. The SwiftUI variant binds presentation to a `@Published`
    /// flag — every click forced a full shell re-render (sidebar + workspace + status bar
    /// + SwiftTerm host) before the dialog could appear, so the click-to-dialog latency
    /// felt like 200-500ms on a busy session. `beginSheetModal` opens immediately on the
    /// main runloop without going through SwiftUI's invalidate / layout pass.
    func requestClose(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        // Settings → General offers a "Skip close confirmation" toggle.
        // When it's on, every close path (sidebar row ✕, workspace tab
        // strip ✕, split-pane ✕) drops straight to the destructive
        // action. The setting key is shared across all sessions —
        // user opted out once, opted out for everything.
        let skipConfirm = UserDefaults.standard.bool(forKey: "dnp.mac.skipCloseConfirm")
        if skipConfirm {
            Task { @MainActor [weak self] in await self?.confirmClose(sessionId: sessionId) }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(session.title)?"
        alert.informativeText = "This will stop the running terminal and Claude process. A handoff note is saved automatically to memory/notes/ so you can pick up in the next session."
        alert.addButton(withTitle: "Close session")
        alert.addButton(withTitle: "Cancel")
        // Cmd-. cancels (Apple HIG); Esc also maps to Cancel by default.
        alert.buttons.last?.keyEquivalent = "\u{1B}"
        // "Don't ask again" suppression checkbox — AppKit-native, lives
        // beneath the informative text. When the user ticks it AND
        // confirms (Close session), we flip the global
        // `dnp.mac.skipCloseConfirm` flag so future closes skip this
        // alert. Settings → General reflects the same flag, so the
        // user can re-enable the prompt from there. Ticking the box
        // and then Cancelling does NOT change the flag — the user has
        // to commit to the close action for the suppression to stick.
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let host = NSApp.windows.first(where: { $0.isKeyWindow })
                  ?? NSApp.windows.first(where: { $0.isMainWindow })
                  ?? NSApp.windows.first

        // Capture the suppression-button reference; reading it from
        // inside the sheet completion is safe but we read the state
        // (`.state == .on`) at that point so the click order doesn't
        // matter.
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(true, forKey: "dnp.mac.skipCloseConfirm")
                }
                Task { @MainActor in await self.confirmClose(sessionId: sessionId) }
            }
        }

        if let window = host {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            // No window yet (extreme edge case during launch) — fall back to a modal.
            handle(alert.runModal())
        }
    }

    /// Close a session: write a memory handoff, terminate the PTY, drop from disk.
    func confirmClose(sessionId: UUID) async {
        // 0. Fire the "Session ended" banner BEFORE we drop the row,
        //    while the title is still in `sessions`. Gated by the
        //    user's `dnp.mac.notifySessionEnded` Settings toggle —
        //    default OFF, so no surprise banner on first install.
        if let session = sessions.first(where: { $0.id == sessionId }) {
            MacNotificationService.shared.fireSessionEnded(
                sessionId: sessionId,
                sessionTitle: session.title,
                reason: "ended"
            )
        }

        // 1. Save a memory handoff so the next session can pick up where we left off.
        await saveSessionHandoff(sessionId: sessionId, reason: "user closed")

        // 2. Stop the terminal child process and free the NSView reference.
        if let terminal = terminalSessions.removeValue(forKey: sessionId) {
            terminal.stop()
        }
        transcripts.unregister(sessionId: sessionId)
        deliveredAssistantHashes.removeValue(forKey: sessionId)
        claudeNamedSessions.remove(sessionId)
        lastBroadcastLiveText.removeValue(forKey: sessionId)
        pendingHookCalls.removeValue(forKey: sessionId)
        approvalRaiseInFlight.remove(sessionId)

        // 3. Drop the session from the in-memory list AND wipe its persistence directory
        // (`metadata.json` + `events.jsonl` + `transcript.md`). The user explicitly asked
        // for the persistence files to vanish at session end so a closed session leaves no
        // trace on disk and won't reappear on the next app launch.
        sessions.removeAll { $0.id == sessionId }
        feed.removeValue(forKey: sessionId)
        try? await persistence.sessions.delete(sessionId)

        // 4. If this was the active session, switch to another live one or "no session".
        if selectedSessionId == sessionId {
            selectedSessionId = sessions.first(where: { $0.status != .ended })?.id
        }

        // Push the trimmed list to iOS clients so the row disappears there too.
        await dispatcher.broadcastSessionList()
    }

    /// Auto-write a markdown handoff under the project's `memory/notes/`. Idempotent per (session, reason).
    func saveSessionHandoff(sessionId: UUID, reason: String) async {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        let projectPath = session.projectPath

        let events = feed[sessionId] ?? []
        let snapshot = contextSnapshots[sessionId]

        var body = "*Project:* \(session.projectName)\n"
        body += "*Started:* \(ISO8601DateFormatter.dnpShared.string(from: session.createdAt))\n"
        body += "*Closed:* \(ISO8601DateFormatter.dnpShared.string(from: Date()))\n"
        body += "*Reason:* \(reason)\n"
        if let snap = snapshot, let used = snap.percentUsed {
            body += "*Context at close:* \(Int((used * 100).rounded()))% used (\(snap.health.rawValue), \(snap.confidence.rawValue))\n"
        }

        let commands = events.filter { $0.type == .commandStarted }.count
        let edits = events.filter { $0.type == .codeEditSummary }.count
        let approvals = events.filter { $0.type == .approvalResult }.count

        body += "\n## Activity summary\n\n"
        body += "- \(events.count) total events\n"
        body += "- \(commands) commands\n"
        body += "- \(edits) code edits\n"
        body += "- \(approvals) approval decisions\n"

        if let firstUser = events.first(where: { $0.type == .userMessage }),
           case .message(let m)? = firstUser.payload {
            body += "\n## Initial intent\n\n> \(m.text.prefix(800))\n"
        }

        // Last user message — what the user was trying to achieve when the session ended.
        if let lastUser = events.last(where: { $0.type == .userMessage }),
           case .message(let m)? = lastUser.payload, lastUser.sequence > 1 {
            body += "\n## Last user request\n\n> \(m.text.prefix(800))\n"
        }

        // Code edits — list affected files for easy pickup.
        let editPaths: [String] = events.compactMap { ev in
            if case .codeEdit(let p)? = ev.payload { return p.filePath }
            return nil
        }
        if !editPaths.isEmpty {
            body += "\n## Files touched\n\n"
            for path in Set(editPaths).sorted() { body += "- `\(path)`\n" }
        }

        body += "\n## Pickup instructions for a new session\n\n"
        body += "Read this note first, then check `memory/MEMORY.md` for the full index.\n"
        body += "Avoid re-running commands already listed above. Continue from \"Last user request\".\n"

        // Best-effort handoff note — `memory.appendNote` returns the
        // URL it wrote to, which we don't use here. `_ =` silences the
        // "result of 'try?' is unused" warning without changing
        // semantics (the note is still written; failures are still
        // swallowed because the recovery path is to keep going).
        _ = try? await memory.appendNote(
            projectPath: projectPath,
            title: "Session handoff: \(session.title)",
            body: body,
            tags: ["handoff", "session", reason]
        )
    }

    /// Called whenever a `ContextSnapshot` arrives for a session. When we cross into critical, we
    /// proactively save a handoff note so the user doesn't lose context if Claude dies on the next message.
    func observeContextChange(_ snapshot: ContextSnapshot) async {
        guard snapshot.health == .critical, !handoffWritten.contains(snapshot.sessionId) else { return }
        handoffWritten.insert(snapshot.sessionId)
        await saveSessionHandoff(sessionId: snapshot.sessionId, reason: "context critical")
    }

    /// Reset the handoff flag for a session that recovered (e.g., after compaction).
    func resetHandoffMarker(sessionId: UUID) {
        handoffWritten.remove(sessionId)
    }

    /// Append the event to feed + persistence + bookkeeping. Context snapshots are now driven
    /// **only** by transcript-based measurements (taken on `Stop` hooks), so we don't pollute the
    /// UI with optimistic 99% guesses on a brand-new session.
    ///
    /// `lastActivityAt` is THROTTLED to once-per-second per session — chatty events (toolActivity,
    /// commandOutput) used to mutate `sessions[i]` on every callback, which re-rendered the
    /// entire view tree at 30+ fps for a busy session. Throttling cuts global re-renders by
    /// ~95% on a busy session without changing visible behaviour (the sidebar's "last activity"
    /// label only ticks once a second anyway).
    func recordEventForContextMonitor(_ event: SessionEvent) async {
        feed[event.sessionId, default: []].append(event)
        if let i = sessions.firstIndex(where: { $0.id == event.sessionId }) {
            let last = sessions[i].lastActivityAt ?? .distantPast
            if event.timestamp.timeIntervalSince(last) >= 1.0 {
                sessions[i].lastActivityAt = event.timestamp
            }
        }
        // Surface session-level failures as banners so the user notices when the Mac
        // window is on another Space / hidden. Only the strong signals — `.crash` and
        // `severity == .error/.critical` — qualify; routine warnings are noisy and have
        // their own status-bar badge already.
        if let title = sessions.first(where: { $0.id == event.sessionId })?.title {
            let summary = event.summary ?? event.title
            if event.type == .crash {
                MacNotificationService.shared.fireSessionCrash(
                    sessionId: event.sessionId, sessionTitle: title, summary: summary
                )
            } else if event.severity == .error || event.severity == .critical {
                MacNotificationService.shared.fireSessionError(
                    sessionId: event.sessionId, sessionTitle: title, summary: summary
                )
            }
        }
        await persistence.appendEvent(event)
    }

    /// Set a real, transcript-derived `ContextSnapshot` for a session. Drives the ring + warnings.
    /// Used as a fallback when no `usage` block has been seen yet (Stop hook with file size).
    func setMeasuredContext(sessionId: UUID, transcriptBytes: Int) async {
        // If we already have a usage-driven snapshot, don't downgrade it to a heuristic one.
        if contextSnapshots[sessionId]?.source == .claudeMetadata { return }
        // Use the SAME budget resolution path the measured-snapshot code uses
        // so the heuristic shares a denominator with `applyUsage`. Without
        // this, a long-restored transcript on a 1M-plan session would
        // estimate `used ≈ 250K` against a 200K default and clamp to 100%
        // used, even after the user picked "1M" in Settings.
        let inferredUsed = max(0, Int(Double(transcriptBytes) / 3.8))
        let resolvedTotal = Self.resolveBudget(
            observedUsed: inferredUsed,
            priorTotal: contextSnapshots[sessionId]?.totalEstimate,
            model: nil
        )
        let estimator = ContextEstimator(bytesPerToken: 3.8, totalTokenBudget: resolvedTotal)
        let snapshot = estimator.snapshot(
            sessionId: sessionId,
            transcriptBytes: transcriptBytes,
            eventCount: feed[sessionId]?.count ?? 0,
            confidence: .estimated,
            source: .heuristic
        )
        contextSnapshots[sessionId] = snapshot
        await observeContextChange(snapshot)
    }

    /// Walk every cached `ContextSnapshot` and rebuild it against the
    /// currently-configured budget. Called when the user toggles the
    /// "Default context window" setting in Mac Settings — flips every
    /// session's ring to the new denominator immediately, instead of
    /// waiting for the next live `usage` block. Heuristic snapshots are
    /// re-run through the same estimator so their bytes-to-tokens
    /// approximation lines up with the new budget too.
    @MainActor
    func recomputeContextSnapshotsForBudgetChange() async {
        for (sid, snap) in contextSnapshots {
            guard let used = snap.usedEstimate else { continue }
            // Re-resolve against the latest user override. `priorTotal: nil`
            // is intentional here: the whole point of the user toggling the
            // setting is to reset the denominator, so we don't keep
            // remembering an empirical bump from before. Empirical bumps
            // still re-apply naturally if `used` exceeds the new picked
            // budget.
            let newTotal = Self.resolveBudget(
                observedUsed: used,
                priorTotal: nil,
                model: nil
            )
            guard newTotal != snap.totalEstimate else { continue }
            let remaining = max(0, newTotal - used)
            let percent = Double(remaining) / Double(newTotal)
            let health = ContextHealth.health(forPercent: percent)
            var warning: ContextWarning? = nil
            switch health {
            case .low:      warning = .lowContext
            case .critical: warning = .sessionEndingSoon
            default: break
            }
            let updated = ContextSnapshot(
                sessionId: sid,
                usedEstimate: used,
                totalEstimate: newTotal,
                remainingEstimate: remaining,
                percentRemaining: percent,
                health: health,
                confidence: snap.confidence,
                source: snap.source,
                warning: warning,
                lastTurnOutputTokens: snap.lastTurnOutputTokens
            )
            contextSnapshots[sid] = updated
            // Broadcast to iOS so the iPhone rings flip in lockstep with
            // Mac — same path `applyUsage` uses.
            let evt = makeEvent(sid: sid, type: .contextUpdate, severity: .info,
                                title: "Context update",
                                summary: "Used \(used.formatted())/\(newTotal.formatted()) tokens",
                                payload: .context(updated))
            await dispatcher.emitLiveEvent(evt)
        }
    }

    /// Apply Claude's own `usage` numbers from the transcript. The token count Claude reports
    /// in `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` IS the live
    /// context occupancy at the start of that turn — authoritative, not estimated.
    ///
    /// Total budget is picked per model via `budget(forModel:)`. Default is 200K (Claude
    /// Code's own interactive context-window simulation hardcodes MAX = 200_000, confirming
    /// this is the default-tier window for Sonnet/Opus; the 1M window is an opt-in beta
    /// signalled by the `[1m]` marker on the model id). The function then performs a
    /// **dynamic upgrade**: if the observed `used` token count exceeds the picked budget,
    /// we know empirically that the user must be on a larger window than the model string
    /// declared (otherwise Claude would have auto-compacted before reaching that count),
    /// so we promote to the next tier rather than report `>100%` used.
    func applyUsage(localSid: UUID, input: Int, cacheRead: Int, cacheCreate: Int,
                    output: Int, model: String?) async {
        let used = input + cacheRead + cacheCreate
        let prior = contextSnapshots[localSid]
        let total = Self.resolveBudget(observedUsed: used,
                                        priorTotal: prior?.totalEstimate,
                                        model: model)
        let remaining = max(0, total - used)
        let percent = Double(remaining) / Double(total)
        let health = ContextHealth.health(forPercent: percent)
        var warning: ContextWarning? = nil
        switch health {
        case .low:      warning = .lowContext
        case .critical: warning = .sessionEndingSoon
        default: break
        }
        let snapshot = ContextSnapshot(
            sessionId: localSid,
            usedEstimate: used,
            totalEstimate: total,
            remainingEstimate: remaining,
            percentRemaining: percent,
            health: health,
            confidence: .measured,
            source: .claudeMetadata,
            warning: warning,
            lastTurnOutputTokens: output
        )
        contextSnapshots[localSid] = snapshot

        // Also publish as a context update event so iOS gets the snapshot pushed in real time.
        let evt = makeEvent(sid: localSid, type: .contextUpdate, severity: .info,
                            title: "Context update",
                            summary: "Used \(used.formatted())/\(total.formatted()) tokens",
                            payload: .context(snapshot))
        await dispatcher.emitLiveEvent(evt)
        await observeContextChange(snapshot)
    }

    /// Resolve the per-session context-window budget given (a) what we already had cached
    /// for this session, (b) what we just observed used, and (c) the current model id.
    ///
    /// Three rules in priority order:
    ///   1. **Sticky tier** — if we previously upgraded a session to a larger window, we
    ///      keep it on that tier even if the model string for the latest turn is more
    ///      conservative. A session that consumed 350K tokens once cannot meaningfully
    ///      drop back to a 200K denominator on the next turn.
    ///   2. **Empirical upgrade** — if `used` already exceeds the model-declared budget,
    ///      Claude Code MUST be running on a larger window (it would have auto-compacted
    ///      around 92% otherwise). Promote to the next tier large enough to contain
    ///      `used` plus a small safety headroom.
    ///   3. **Model-declared default** — fall through to `budget(forModel:)`.
    private static func resolveBudget(observedUsed: Int, priorTotal: Int?, model: String?) -> Int {
        let declared = budget(forModel: model)
        let candidate = max(priorTotal ?? 0, declared)
        if observedUsed <= candidate {
            return candidate
        }
        // Observed > candidate: pick the smallest tier that can hold the observation.
        // Tiers track Anthropic's public ladder so the percentage never reads >100%.
        for tier in [200_000, 500_000, 1_000_000, 2_000_000] where tier > observedUsed {
            return tier
        }
        // Off the top of the ladder (>2M used) — round up to the next million so the
        // ring still renders something sensible instead of a negative remaining count.
        return ((observedUsed / 1_000_000) + 1) * 1_000_000
    }

    /// Pick the per-model context-window budget.
    ///
    /// Resolution order:
    ///   1. **Explicit `[1m]` / `-1m` marker on the model id** → 1M, regardless
    ///      of any user override (the model itself declared the window).
    ///   2. **Explicit Haiku** → 200K (no haiku has shipped a 1M variant).
    ///   3. **User override from Settings** (`dnp.mac.defaultContextWindow`):
    ///        • `"auto"` (default) → 200K (matches Claude Code's standard
    ///          window — what the official `/context` simulation hardcodes).
    ///        • `"200000"` / `"1000000"` / `"2000000"` → use that value.
    ///      The override exists because the model id Anthropic writes to
    ///      transcripts (e.g. `claude-opus-4-7`) does NOT carry the `[1m]`
    ///      marker even when the user is signed up for the 1M-context plan.
    ///      Without an override, those sessions used to read "near 100%"
    ///      against a 200K denominator while the user is actually at 10-20%
    ///      of their real 1M window. The override lets a 1M-plan user pin
    ///      the right denominator from the first turn.
    ///   4. The empirical upgrade in `resolveBudget` still applies on top —
    ///      if observed usage exceeds the picked budget, we promote to the
    ///      next tier so the ring never reads >100% under any setting.
    private static func budget(forModel model: String?) -> Int {
        if let model = model?.lowercased() {
            if model.contains("[1m]") || model.contains("-1m") || model.contains(" 1m") {
                return 1_000_000
            }
            if model.contains("haiku") {
                return 200_000
            }
        }
        // User override — read live from UserDefaults so a Settings change
        // takes effect on the next usage block without a relaunch. Keys
        // and values are documented above next to the setting.
        let override = UserDefaults.standard.string(forKey: "dnp.mac.defaultContextWindow") ?? "auto"
        switch override {
        case "200000":   return 200_000
        case "500000":   return 500_000
        case "1000000":  return 1_000_000
        case "2000000":  return 2_000_000
        default:          return 200_000
        }
    }


    // MARK: - Hook ingest

    /// Decode the relay's JSON envelope, map to `SessionEvent`s, persist + broadcast to iOS.
    /// Bodies look like: `{ "event": "UserPromptSubmit", "timestamp": "...", "cwd": "...", "raw": "..." }`
    /// where `raw` is the JSON Claude Code sent to the hook on stdin.
    func ingestHookRelayPayload(_ body: Data) async {
        guard let outer = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let eventName = outer["event"] as? String,
              let raw = outer["raw"] as? String,
              !raw.isEmpty,
              let inner = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { return }

        let claudeSid = (inner["session_id"] as? String) ?? ""
        let cwd = (outer["cwd"] as? String)
            ?? (inner["cwd"] as? String) ?? ""

        // Gate hooks by ownership. THREE accept paths (any one is sufficient):
        //   1. `dnp_remote == "1"` — env marker set by `TerminalSession.spawn`,
        //      threaded through Claude → hook subprocess → relay payload.
        //   2. `claudeSessionToLocal[claudeSid]` is bound — we already saw this
        //      session via the transcript watcher or an earlier hook.
        //   3. `cwd` matches the projectPath of a live DNP session — Claude
        //      running inside a DNP project directory is OURS regardless of
        //      whether the env marker survived. This is the path that fixes
        //      the "iOS user types a prompt, Claude asks for permission via
        //      its inline TUI prompt, but the iOS Allow popup never shows"
        //      bug: in some user configs the `DNP_REMOTE` env var doesn't
        //      reach Claude's hook subprocess (zsh profile, env-stripping
        //      pyenv shim, Claude's own env allowlist, etc.), so the env-only
        //      gate dropped the PreToolUse / PermissionRequest hook silently
        //      and the approval never reached iOS. Cwd-binding catches it.
        let dnpMarker = (outer["dnp_remote"] as? String) ?? ""

        // Direct per-session marker — the env var the Mac threads into
        // `TerminalSession.spawn` and the hook relay echoes back to us.
        // When present, this is THE routing key. No cwd disambiguation
        // needed; no race with the transcript-watcher binding.
        let directSessionIdRaw = (outer["dnp_session_id"] as? String) ?? ""
        let directSessionId: UUID? = directSessionIdRaw.isEmpty
            ? nil
            : UUID(uuidString: directSessionIdRaw)
        let directSession = directSessionId.flatMap { id in
            sessions.first(where: { $0.id == id })
        }

        let cwdMatchedSession = sessions.first(where: {
            !cwd.isEmpty && $0.projectPath == cwd && $0.status != .ended
        })
        let isOurs = (dnpMarker == "1")
            || directSession != nil
            || (!claudeSid.isEmpty && claudeSessionToLocal[claudeSid] != nil)
            || (cwdMatchedSession != nil)
        guard isOurs else {
            #if DEBUG
            print("[Hook] dropped \(eventName) — not ours (claudeSid=\(claudeSid.prefix(8)), dnp_remote=\(dnpMarker), cwd=\(cwd))")
            #endif
            return
        }
        // Bind the claudeSid to the local session id eagerly. Prefer
        // the direct DNP_SESSION_ID marker (unambiguous) over the cwd
        // match (which can pick the wrong session when two sessions
        // share a project). This is the core fix for the cross-session
        // attribution bug.
        if !claudeSid.isEmpty, claudeSessionToLocal[claudeSid] == nil {
            if let direct = directSession {
                claudeSessionToLocal[claudeSid] = direct.id
                print("[Hook] bound claudeSid=\(claudeSid.prefix(8)) → local sid=\(direct.id.uuidString.prefix(8)) via DNP_SESSION_ID")
            } else if let cwdMatched = cwdMatchedSession {
                // Only attempt cwd binding when there's exactly ONE live
                // session for that project — otherwise the binding is a
                // 50/50 guess and would mis-route events for the duration
                // of the Claude session. Skip the bind and let the next
                // hook (which will likely carry DNP_SESSION_ID) settle it.
                let cwdMatchCount = sessions.filter {
                    !cwd.isEmpty && $0.projectPath == cwd && $0.status != .ended
                }.count
                if cwdMatchCount == 1 {
                    claudeSessionToLocal[claudeSid] = cwdMatched.id
                    print("[Hook] bound claudeSid=\(claudeSid.prefix(8)) → local sid=\(cwdMatched.id.uuidString.prefix(8)) via cwd=\(cwd) (sole match)")
                } else {
                    print("[Hook] deferred binding for claudeSid=\(claudeSid.prefix(8)) — \(cwdMatchCount) sessions share cwd=\(cwd); waiting for DNP_SESSION_ID-bearing hook")
                }
            }
        }
        let sessionId: UUID = {
            // Direct marker wins outright — no fallback needed.
            if let direct = directSession { return direct.id }
            if let mapped = claudeSessionToLocal[claudeSid] { return mapped }
            // Last-resort fallback: prefer a single cwd match. When
            // multiple sessions share the cwd we still have to pick
            // SOMETHING (otherwise the event vanishes), but we lean on
            // the IDE's currently-selected session in that ambiguity
            // rather than blindly grabbing `sessions.first`.
            let cwdCandidates = sessions.filter {
                !cwd.isEmpty && $0.projectPath == cwd && $0.status != .ended
            }
            let candidate: UUID? = {
                if cwdCandidates.count == 1 { return cwdCandidates.first?.id }
                if let sel = selectedSessionId,
                   cwdCandidates.contains(where: { $0.id == sel }) {
                    return sel
                }
                return cwdCandidates.first?.id
                    ?? selectedSessionId
                    ?? sessions.first(where: { $0.status == .running })?.id
            }()
            if let candidate {
                if !claudeSid.isEmpty,
                   claudeSessionToLocal[claudeSid] == nil,
                   cwdCandidates.count <= 1 {
                    claudeSessionToLocal[claudeSid] = candidate
                }
                return candidate
            }
            return UUID(uuidString: claudeSid) ?? UUID()
        }()

        var emitted: [SessionEvent] = []

        switch eventName {
        case "UserPromptSubmit":
            if let prompt = inner["prompt"] as? String {
                await deliverUserMessage(localSid: sessionId, claudeSid: claudeSid,
                                         text: prompt, source: .hookRelay)
            }
        case "PreToolUse":
            if let toolName = inner["tool_name"] as? String {
                let toolInput = inner["tool_input"] as? [String: Any]
                let summary = Self.unifiedToolTarget(toolName: toolName, toolInput: toolInput)
                await deliverToolActivity(localSid: sessionId, toolName: toolName,
                                          summary: summary, started: true)
                // ARCHITECTURAL SHIFT: hooks no longer raise approvals directly. They
                // stash context so when the PTY-driven poller detects Claude's actual
                // `Do you want to proceed?` prompt, it can build a rich card. This is
                // what kills the "false-positive allow" bug — Claude doesn't actually
                // pause for many tools (Edit on auto-allowed paths, Bash on patterns
                // the user has whitelisted, etc.), so the old "always raise on
                // PreToolUse for risky tools" path produced phantom cards. Now the
                // PTY confirms before any card surfaces.
                if Self.toolNeedsApproval(toolName, bashCommand: summary) {
                    pendingHookCalls[sessionId] = PendingHookCall(
                        toolName: toolName,
                        target: summary ?? toolName,
                        timestamp: Date()
                    )
                }
            }
        case "PostToolUse":
            if let toolName = inner["tool_name"] as? String {
                await deliverToolActivity(localSid: sessionId, toolName: toolName,
                                          summary: nil, started: false)
                // Tool resolved (with or without an approval prompt) — drop the
                // cached hook context so a later, unrelated prompt doesn't borrow
                // this tool's name/target.
                pendingHookCalls.removeValue(forKey: sessionId)
            }
        case "PermissionRequest":
            // PermissionRequest is a STRONGER signal that Claude will pause, but it
            // STILL goes through the PTY confirm gate — we've seen Claude fire this
            // hook even when the user's settings auto-allow the tool, in which case
            // no inline prompt ever shows up. Cache context; let the poller decide.
            if let toolName = inner["tool_name"] as? String {
                let toolInput = inner["tool_input"] as? [String: Any]
                let target = Self.unifiedToolTarget(toolName: toolName, toolInput: toolInput)
                            ?? toolName
                pendingHookCalls[sessionId] = PendingHookCall(
                    toolName: toolName,
                    target: target,
                    timestamp: Date()
                )
            }
        case "Stop", "PostToolBatch":
            // Stop fires when Claude finishes a turn — but the hook may not fire if the user
            // hasn't accepted Claude's hook-permission gate. Either way we read the transcript
            // and route through `deliverAssistantMessage` (which dedupes against the transcript
            // watcher's emission). Also re-measure context from real transcript bytes.
            if let path = inner["transcript_path"] as? String {
                if let assistant = await Self.readLatestAssistantMessage(transcriptPath: path) {
                    await deliverAssistantMessage(localSid: sessionId, claudeSid: claudeSid,
                                                  text: assistant)
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int {
                    await setMeasuredContext(sessionId: sessionId, transcriptBytes: size)
                }
            }
            thinkingSessions.remove(sessionId)
        case "SessionStart":
            // Bind Claude's session_id ↔ local session UUID. We adopt "Claude · <short>" only
            // as a STARTING placeholder; once the user sends their first prompt,
            // `maybeAutoTitleSession` replaces it with text from that prompt — matching how
            // Claude Code's own session list names sessions.
            if !claudeSid.isEmpty {
                claudeSessionToLocal[claudeSid] = sessionId
                if let i = sessions.firstIndex(where: { $0.id == sessionId }),
                   !claudeNamedSessions.contains(sessionId) {
                    let isDefault = sessions[i].title.hasPrefix("Session ")
                                 || sessions[i].title.isEmpty
                    if isDefault {
                        let short = String(claudeSid.prefix(8))
                        sessions[i].title = "Claude · \(short)"
                        await dispatcher.broadcastSessionList()
                    }
                }
            }
            emitted.append(makeEvent(sid: sessionId, type: .sessionStarted, severity: .info,
                                     title: "Session started"))
        case "SessionEnd":
            emitted.append(makeEvent(sid: sessionId, type: .sessionEnded, severity: .info,
                                     title: "Session ended"))
        case "PreCompact":
            emitted.append(makeEvent(sid: sessionId, type: .compactStarted, severity: .notice,
                                     title: "Compacting context"))
        case "PostCompact":
            resetHandoffMarker(sessionId: sessionId)
            emitted.append(makeEvent(sid: sessionId, type: .compactCompleted, severity: .info,
                                     title: "Compaction complete"))
        case "Notification":
            let msg = inner["message"] as? String ?? "Notification"
            // Drop noisy turn-meta notifications that Claude fires at the end of
            // every turn (e.g. "no response requested" — emitted when Claude
            // finished without explicitly asking the user for input). These are
            // hook bookkeeping, not user-facing news; if we surface them as a
            // yellow warning card on iOS the user sees that message INSTEAD of
            // Claude's actual reply right next to it. Real, actionable
            // notifications (permission requests, "waiting for input" prompts)
            // still flow through because they don't match this pattern.
            let lowered = msg.lowercased()
            let isTurnMeta =
                lowered.contains("no response")          ||
                lowered.contains("response not required") ||
                lowered.contains("response was not requested")
            if !isTurnMeta {
                // Decide if this Notification is "attention-worthy": Claude is asking
                // the user to look at the TUI. The hook fires both for permission
                // prompts (which usually ALSO surface through PreToolUse / PermissionRequest
                // and become a real ApprovalRequest) and for plain idle/MCP/"waiting for
                // input" cases. We dedupe against any pending approval for this session
                // in the last 5s so the Approval banner remains the single source of
                // truth when the structured path fired — the attention banner is the
                // *fallback* nudge for everything else.
                let hasFreshApproval = pendingApprovals.contains { req in
                    req.sessionId == sessionId &&
                    Date().timeIntervalSince(req.requestedAt) < 5
                }
                let surfaceAsBanner = !hasFreshApproval
                if surfaceAsBanner {
                    let title = sessions.first(where: { $0.id == sessionId })?.title ?? "Session"
                    MacNotificationService.shared.fireAttention(
                        sessionId: sessionId,
                        sessionTitle: title,
                        message: msg
                    )
                }
                emitted.append(makeEvent(sid: sessionId, type: .warning, severity: .warning,
                                         title: msg,
                                         payload: .warning(WarningPayload(
                                            code: "claude.notification",
                                            title: msg,
                                            attention: surfaceAsBanner))))
            }
        default:
            break
        }

        for event in emitted {
            await dispatcher.emitLiveEvent(event)
        }
    }

    private func makeEvent(sid: UUID, type: SessionEventType, severity: SessionEventSeverity,
                           title: String, summary: String? = nil,
                           payload: SessionEventPayload? = nil) -> SessionEvent {
        let nextSeq = (feed[sid]?.last?.sequence ?? 0) + 1
        return SessionEvent(
            sessionId: sid, sequence: nextSeq,
            type: type, severity: severity,
            source: .hookRelay, title: title, summary: summary, payload: payload
        )
    }

    /// Read the last `assistant` text from a Claude Code transcript JSONL file.
    /// Each line is `{ "type": "user"|"assistant"|"system", "message": { "content": [...] } }`.
    private static func readLatestAssistantMessage(transcriptPath: String) async -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: transcriptPath)),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let lines = str.split(separator: "\n")
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            // Content is an array of blocks. Concatenate text blocks.
            if let content = message["content"] as? [[String: Any]] {
                let texts: [String] = content.compactMap {
                    ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil
                }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            } else if let text = message["content"] as? String {
                return text
            }
        }
        return nil
    }

    // MARK: - File explorer (iOS-driven)

    /// Show NSOpenPanel and adopt the chosen folder as the active project. Runs on the main
    /// actor since it touches AppKit. Broadcasts a fresh ProjectInfo afterward (the dispatcher
    /// re-broadcasts; this just changes the model state).
    /// iOS-side folder picker funneled through `setProjectRootRequest`. Validates the absolute
    /// path is under $HOME (so iOS can never set the root to /etc/) and adopts it as the
    /// project. Broadcast happens via the dispatcher after this returns.
    @MainActor
    func adoptProjectRoot(absolutePath: String) async {
        guard let url = Self.resolveAbsoluteUnderHome(absolutePath) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        // Multi-window flow: iOS picking a project means "open this project's IDE
        // window." The previous behaviour mutated the active workspace's root, which
        // (a) didn't work cleanly when no workspace window was open, and (b) hijacked
        // whatever project the user happened to be working on at the Mac. Routing
        // through `ProjectWindowOpener` opens (or refocuses if already open) a
        // dedicated workspace window for this project — the Mac and iOS converge on
        // the same "window per project" model. Recents register so the picker on both
        // sides reflects the choice.
        RecentProjectsService.shared.registerLocal(at: url)
        ProjectWindowOpener.openProject(at: url)
    }

    @MainActor
    func presentOpenFolderPanelAndAdopt() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Surfaces the (system-localised) "New Folder" button in the
        // panel toolbar so the user can mint a fresh project folder
        // without dropping back to Finder. Same affordance the Welcome
        // scene's Open Project panel uses.
        panel.canCreateDirectories = true
        // Leave `prompt` / `title` unset so NSOpenPanel uses its built-in
        // default ("Open" → localised by macOS to the user's system
        // language). Setting them to literal English would override that
        // localisation.
        // Bring the Mac app forward so the iPhone-tap actually surfaces the dialog visibly.
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    /// List one directory. Two routing modes:
    ///   • A `relativePath` not starting with `/` is resolved against the active project root.
    ///   • An absolute path (`/Users/<me>/...`) is allowed as long as it stays under $HOME, so
    ///     the iOS file explorer can browse anywhere on the Mac the user owns.
    func listDirectory(payload: DirectoryListingRequestPayload) async -> DirectoryListingResponsePayload {
        let resolved: URL?
        if payload.relativePath.hasPrefix("/") {
            resolved = Self.resolveAbsoluteUnderHome(payload.relativePath)
        } else if let root = projectRoot?.url {
            resolved = Self.resolveProjectRelative(root: root, relative: payload.relativePath)
        } else {
            // No project + no absolute path → fall back to home so the explorer can boot.
            resolved = FileManager.default.homeDirectoryForCurrentUser
        }
        guard let resolved else {
            return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                         entries: [], error: "Path is outside the user's home directory")
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            let entries: [DirectoryEntry] = urls
                .map { url in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                    return DirectoryEntry(name: url.lastPathComponent, isDirectory: isDir, sizeBytes: size)
                }
                // Folders first, then files, both alphabetised.
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                         entries: entries, error: nil)
        } catch {
            return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                         entries: [], error: error.localizedDescription)
        }
    }

    /// Read a file. Accepts both project-relative paths and absolute paths under $HOME.
    /// Returns UTF-8 text for text MIME types, otherwise the raw bytes (so iOS can render
    /// images inline). Truncates to `maxBytes`.
    func readFile(payload: FileContentRequestPayload) async -> FileContentResponsePayload {
        let resolved: URL?
        if payload.relativePath.hasPrefix("/") {
            resolved = Self.resolveAbsoluteUnderHome(payload.relativePath)
        } else if let root = projectRoot?.url {
            resolved = Self.resolveProjectRelative(root: root, relative: payload.relativePath)
        } else {
            resolved = nil
        }
        guard let resolved,
              !((try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        else {
            return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                         mimeType: "application/octet-stream",
                         error: "Invalid path")
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: resolved.path)
            let totalSize = (attrs[.size] as? Int) ?? 0
            let truncated = totalSize > payload.maxBytes
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: payload.maxBytes)) ?? Data()

            let ext = resolved.pathExtension.lowercased()
            let utType = UTType(filenameExtension: ext)
            let mime = utType?.preferredMIMEType ?? Self.guessMime(forExt: ext)

            // Treat as text if MIME starts with text/, or it's a known structured-text type, OR
            // we detect a valid UTF-8 decode AND no NUL bytes.
            let isTextMime = mime.hasPrefix("text/") || Self.isProgrammingLanguageType(ext: ext)
            if isTextMime, let s = String(data: data, encoding: .utf8) {
                return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                             mimeType: mime, utf8Text: s, binary: nil,
                             truncated: truncated, error: nil)
            }
            // Heuristic for unknown text files (e.g., .env): try UTF-8 + no-NUL.
            if let s = String(data: data, encoding: .utf8), !data.contains(0) {
                return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                             mimeType: "text/plain", utf8Text: s, binary: nil,
                             truncated: truncated, error: nil)
            }
            return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                         mimeType: mime, utf8Text: nil, binary: data,
                         truncated: truncated, error: nil)
        } catch {
            return .init(requestId: payload.requestId, relativePath: payload.relativePath,
                         mimeType: "application/octet-stream",
                         error: error.localizedDescription)
        }
    }

    /// Resolve a project-relative path safely. Rejects absolute paths and any `..` traversal that
    /// escapes `root`. Returns the resolved URL, or nil if the path is unsafe / outside the root.
    private static func resolveProjectRelative(root: URL, relative: String) -> URL? {
        // Empty/"/" → root itself.
        let cleaned = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate: URL
        if cleaned.isEmpty {
            candidate = root
        } else if relative.hasPrefix("/") {
            return nil   // iOS shouldn't send absolute paths
        } else {
            candidate = root.appendingPathComponent(cleaned)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path == rootStd || resolved.path.hasPrefix(rootStd + "/") else { return nil }
        return resolved
    }

    private static let programmingExts: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "c", "cpp", "h", "hpp",
        "m", "mm", "java", "kt", "scala", "sh", "zsh", "bash", "fish", "lua", "php",
        "html", "css", "scss", "less", "vue", "svelte", "json", "yml", "yaml", "toml",
        "xml", "md", "markdown", "txt", "log", "ini", "cfg", "conf", "env", "gitignore",
        "dockerfile", "makefile", "sql", "graphql", "gql", "proto"
    ]

    private static func isProgrammingLanguageType(ext: String) -> Bool {
        programmingExts.contains(ext.lowercased())
    }

    private static func guessMime(forExt ext: String) -> String {
        if isProgrammingLanguageType(ext: ext) { return "text/plain" }
        return "application/octet-stream"
    }

    /// Resolve an absolute path coming from iOS, gating it under $HOME so iOS can never request
    /// `/etc/passwd` or other system files. Returns nil if outside $HOME.
    private static func resolveAbsoluteUnderHome(_ absolute: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == home.path || candidate.path.hasPrefix(home.path + "/") else { return nil }
        return candidate
    }

    // MARK: - File save (iOS → Mac)

    /// Overwrite a file with new UTF-8 text. Sandboxed under $HOME (and the project root).
    func writeFile(payload: FileWriteRequestPayload) async -> FileWriteResponsePayload {
        let resolved: URL?
        if payload.path.hasPrefix("/") {
            resolved = Self.resolveAbsoluteUnderHome(payload.path)
        } else if let root = projectRoot?.url {
            resolved = Self.resolveProjectRelative(root: root, relative: payload.path)
        } else {
            resolved = nil
        }
        guard let resolved else {
            return .init(requestId: payload.requestId, path: payload.path, success: false,
                         error: "Invalid path")
        }
        do {
            try payload.utf8Text.data(using: .utf8)?.write(to: resolved, options: .atomic)
            return .init(requestId: payload.requestId, path: payload.path, success: true)
        } catch {
            return .init(requestId: payload.requestId, path: payload.path, success: false,
                         error: error.localizedDescription)
        }
    }

    // MARK: - File search (iOS → Mac)

    /// Recursive name + content search rooted at `rootPath` (must be under $HOME). Skips dot-
    /// directories and common build artefact folders (.build, node_modules, .git) so we don't
    /// drown in irrelevant matches. Returns at most `maxResults` hits.
    func searchFiles(payload: FileSearchRequestPayload) async -> FileSearchResponsePayload {
        guard let root = Self.resolveAbsoluteUnderHome(payload.rootPath) else {
            return .init(requestId: payload.requestId, query: payload.query,
                         hits: [], truncated: false, error: "Invalid root path")
        }
        let needle = payload.query
        guard !needle.isEmpty else {
            return .init(requestId: payload.requestId, query: payload.query, hits: [])
        }
        let needleLowercased = needle.lowercased()
        let skipDirs: Set<String> = [
            ".git", ".build", "node_modules", "DerivedData",
            ".next", ".cache", "Pods", "vendor", "tempfiles"
        ]
        let textExtensions: Set<String> = Self.programmingExts
        var hits: [FileSearchHit] = []
        var truncated = false

        // Use FileManager enumerator. Skip large/binary files and skip directories by name.
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])

        while let url = enumerator?.nextObject() as? URL {
            if hits.count >= payload.maxResults { truncated = true; break }
            // Skip noisy directories regardless of depth.
            if skipDirs.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator?.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // Filename match (always considered).
            if url.lastPathComponent.lowercased().contains(needleLowercased) {
                hits.append(.init(path: url.path, isDirectory: isDir,
                                  lineNumber: nil, snippet: nil))
                continue
            }
            // Content match (only on text-y files, only when requested, only files <= 1 MB).
            if !isDir, payload.searchContent {
                let ext = url.pathExtension.lowercased()
                guard textExtensions.contains(ext) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 1_000_000 else { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let lineHit = Self.firstLineMatch(content: content, needle: needle) {
                    hits.append(.init(path: url.path, isDirectory: false,
                                      lineNumber: lineHit.lineNumber,
                                      snippet: lineHit.snippet))
                }
            }
        }
        return .init(requestId: payload.requestId, query: payload.query,
                     hits: hits, truncated: truncated, error: nil)
    }

    private static func firstLineMatch(content: String, needle: String) -> (lineNumber: Int, snippet: String)? {
        let needleLower = needle.lowercased()
        var lineNum = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNum += 1
            if line.lowercased().contains(needleLower) {
                let snippet = String(line.prefix(200))
                return (lineNum, snippet)
            }
        }
        return nil
    }

    // MARK: - Attachment ingest (from iOS)

    /// Write an iOS-uploaded attachment to the active project's `tempfiles/` directory.
    /// iOS then references it via `@tempfiles/<filename>` in a follow-up `userPrompt`,
    /// which Claude reads as a normal file attachment.
    func persistAttachment(filename: String, data: Data) async {
        let projectPath = projectRoot?.url.path ?? NSHomeDirectory()
        let tempDir = URL(fileURLWithPath: projectPath).appendingPathComponent("tempfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let target = tempDir.appendingPathComponent(filename)
        try? data.write(to: target, options: .atomic)
    }

    // MARK: - iOS prompt → Mac PTY

    /// Forwards an iOS user-prompt envelope into the active session's terminal so Claude reads it.
    /// Also emits a `userMessage` event so other paired iOS clients see the bubble appear.
    func handleIncomingUserPrompt(text: String, fromSessionId: UUID, deviceId: UUID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[DNP][UserPrompt] handleIncoming fromSid=\(fromSessionId.uuidString.prefix(8)) terminals=\(terminalSessions.count) selected=\(selectedSessionId?.uuidString.prefix(8) ?? "nil")")

        // Resolve a real local terminal — auto-create one if none exists yet.
        var sid: UUID = (terminalSessions[fromSessionId] != nil)
            ? fromSessionId
            : (selectedSessionId ?? terminalSessions.keys.first ?? fromSessionId)

        // Spawn a terminal only if we have NO record of this session at all. iOS-triggered
        // `requestNewSession` already created the terminal record before sending the prompt,
        // so this path only fires for "iOS sent before any session existed".
        if terminalSessions[sid] == nil {
            print("[DNP][UserPrompt] no terminal for \(sid.uuidString.prefix(8)) — spawning new session")
            let s = await newSession()
            sid = s.id
        }
        print("[DNP][UserPrompt] resolved sid=\(sid.uuidString.prefix(8))")

        // Make the iOS-targeted session the active one so subsequent hook events route here.
        if selectedSessionId != sid { selectedSessionId = sid }

        // Echo the user bubble immediately, regardless of whether we send to the PTY now or
        // later — the user shouldn't wait for Claude to come up to see their own message.
        if !trimmed.isEmpty {
            deliveredUserHashes[sid, default: []].insert(trimmed.hashValue)
            await deliverUserMessage(localSid: sid, claudeSid: "", text: trimmed, source: .ios)
        }

        // Real readiness signal is `term.isRunning` — i.e. the PTY has spawned a
        // child process. The PREVIOUS gate on `claudeSessionId.isEmpty == false`
        // was a deadlock: a fresh session has no `.jsonl` until Claude processes
        // its FIRST input, but the watcher's `onClaudeSessionDiscovered` (which
        // would flush the queue) only fires when the `.jsonl` appears. So the
        // first prompt sat in the queue forever, Claude waited at its empty
        // welcome screen, neither side made progress. The user reproduced this
        // exact pattern in the log:
        //   `claudeReady=false termRunning=true claudeSid=nil`
        //   `QUEUED ... will flush on onClaudeSessionDiscovered` ← never fires
        // Fix: write directly to the PTY any time it's running. The PTY buffers
        // the bytes; once Claude's TUI finishes loading and reads stdin it
        // processes the bracketed-paste correctly. Use a short delay for fresh
        // sessions (no `claudeSessionId` yet) so the paste arrives AFTER the
        // TUI's initial render — empirically 1.4s is enough.
        let session = sessions.first(where: { $0.id == sid })
        let term = terminalSessions[sid]
        let claudeBootstrapped = (session?.claudeSessionId?.isEmpty == false)
        let termRunning = term?.isRunning ?? false
        print("[DNP][UserPrompt] claudeBootstrapped=\(claudeBootstrapped) termRunning=\(termRunning) claudeSid=\(session?.claudeSessionId ?? "nil")")

        // Terminal hasn't even started yet — queue and let `autoLaunch` -> watcher
        // fire `flushPendingPrompts`. This is the only path that still queues.
        guard let term, termRunning else {
            if !trimmed.isEmpty {
                pendingPromptsBySession[sid, default: []].append(trimmed)
                print("[DNP][UserPrompt] QUEUED for \(sid.uuidString.prefix(8)) — terminal not running yet")
            }
            thinkingSessions.insert(sid)
            return
        }

        guard !trimmed.isEmpty else {
            thinkingSessions.insert(sid)
            return
        }

        // Fresh session that hasn't written its first transcript yet → wait for
        // the TUI to finish initial render before pasting, otherwise our paste
        // can land on the splash screen and get lost.
        let preDelayNs: UInt64 = claudeBootstrapped ? 0 : 1_400_000_000
        if preDelayNs > 0 {
            print("[DNP][UserPrompt] fresh session — pre-paste delay \(preDelayNs / 1_000_000)ms")
            try? await Task.sleep(nanoseconds: preDelayNs)
        }
        let pasted = "\u{1B}[200~" + trimmed + "\u{1B}[201~\r"
        print("[DNP][UserPrompt] writing \(pasted.utf8.count) bytes to PTY of \(sid.uuidString.prefix(8))")
        term.sendInput(pasted)
        try? await Task.sleep(nanoseconds: 150_000_000)
        term.sendInput("\r")
        // Extra retry CR for fresh sessions — Claude's input handler can be in
        // a state where the first \r highlights but doesn't submit. A second
        // CR ~600ms later submits whatever's in the prompt buffer; submitting
        // an empty buffer afterwards is a no-op for Claude's REPL.
        if !claudeBootstrapped {
            try? await Task.sleep(nanoseconds: 600_000_000)
            term.sendInput("\r")
        }
        thinkingSessions.insert(sid)
    }

    /// Flush prompts queued against a session that just became ready (Claude wrote its
    /// first transcript line). Cold-start TUIs need a real beat to render their input
    /// prompt — we wait 2.0 s, write the bracketed-paste block + CR, then send a couple of
    /// follow-up CRs at 0.6 s spacing. Submitting the same `\r` more than once is a no-op
    /// once Claude has accepted the prompt; if the first one was lost (Ink reader not yet
    /// attached), the retries land on the next tick and the prompt finally goes through.
    private func flushPendingPrompts(for sessionId: UUID) async {
        guard var queue = pendingPromptsBySession[sessionId], !queue.isEmpty else { return }
        pendingPromptsBySession.removeValue(forKey: sessionId)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let term = terminalSessions[sessionId] else { return }
        while !queue.isEmpty {
            let prompt = queue.removeFirst()
            let pasted = "\u{1B}[200~" + prompt + "\u{1B}[201~\r"
            term.sendInput(pasted)
            // Three rounds of CR retry. By the third tick Claude's reader is definitely
            // up and the carriage return submits whatever's in the input buffer.
            try? await Task.sleep(nanoseconds: 350_000_000)
            term.sendInput("\r")
            try? await Task.sleep(nanoseconds: 600_000_000)
            term.sendInput("\r")
            try? await Task.sleep(nanoseconds: 600_000_000)
            term.sendInput("\r")
            // Gap between consecutive queued prompts so Claude has a chance to start
            // processing the previous one.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// Sessions for which we've sent a user prompt and are still waiting for Claude's response.
    /// iOS uses this to show a "Claude is thinking…" indicator, and the Mac sidebar/tab
    /// `ContextRing` uses it to spin its overlay arc only while Claude is actually processing
    /// (not for the entire lifetime of the PTY-attached session).
    @Published var thinkingSessions: Set<UUID> = []

    /// Per-session timestamp of the last `1\r`/`2\r` typed into the PTY in response to
    /// an approval. Used by `handleApprovalDecision` to differentiate "race of two
    /// duplicate decisions" (skip the second write) from "the user retried because
    /// the first write missed Claude's prompt window" (resend after 2 seconds).
    private var lastApprovalPTYWriteAt: [UUID: Date] = [:]

    func selectedSession() -> Session? {
        guard let id = selectedSessionId else { return sessions.first }
        return sessions.first(where: { $0.id == id })
    }

    func eventsForSelected() -> [SessionEvent] {
        guard let id = selectedSessionId else { return [] }
        return feed[id] ?? []
    }

    // MARK: Project actions

    var projectRootName: String? { projectRoot?.url.lastPathComponent }

    func openProject(at url: URL) {
        projectRoot = FileNode(url: url)
        openFiles.removeAll()
        activeFile = nil
        workspacePane = .terminal
        UserDefaults.standard.set(url.path, forKey: "dnp.lastProjectPath")
        // Welcome / dock-menu uses this list — keep the local-folder entry fresh.
        RecentProjectsService.shared.registerLocal(at: url)
        // GitHub detection — DEFERRED to a background task. Running it inline
        // (`projectGitHub = GitHubProjectInfo.detect(at: url)`) shells out to git via
        // `Process` + `waitUntilExit` and, when this method is invoked from inside a
        // SwiftUI update cycle, that synchronous spin re-enters SwiftUI and trips
        // "AttributeGraph precondition failure: setting value during update" → SIGABRT.
        projectGitHub = nil
        Task.detached(priority: .userInitiated) { [weak self, url] in
            let info = GitHubProjectInfo.detect(at: url)
            await MainActor.run { [weak self] in
                self?.projectGitHub = info
            }
        }
        Task { await dispatcher.broadcastProjectInfo() }
    }

    /// Spawn a new session whose terminal auto-`ssh`'s into a remote host. Used by the
    /// Welcome scene's "Connect to SSH" entry — re-opening an SSH recent calls this so
    /// the user lands directly in the remote shell ready to run Claude. The local file
    /// explorer / context monitor still operate on `projectRoot` (which the caller sets
    /// to the user's home directory before invoking this) — full remote-workspace mode
    /// is a follow-up.
    @MainActor
    func openSSHSession(connection: SSHConnectionService.Connection,
                        displayName: String,
                        in workspace: WorkspaceController) async {
        let session = await newSession(in: workspace)
        guard let term = terminalSessions[session.id] else { return }
        // Update title so the sidebar reads "user@host" instead of the auto-generated name.
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i].title = displayName
        }
        let cmd = SSHConnectionService.interactiveCommand(connection)
        // Run the ssh command via the user's login shell so PATH / agent forwarding work
        // exactly as they do from Terminal.app.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        term.startCommand(shell, args: ["-l", "-c", cmd],
                          workingDirectory: NSHomeDirectory())
    }

    /// Adopt a GitHub repo as a workspace project. Clones to `~/Developer/<repo>` if no local
    /// copy exists yet, otherwise reuses the existing clone. Opens the project in a NEW
    /// `WorkspaceWindow` via `ProjectWindowOpener` rather than swapping the caller's
    /// active window — multi-window architecture treats every project as its own
    /// independent IDE shell, so adopting from GitHub mirrors that flow (the Welcome
    /// scene, the Open Project menu, and dock-menu recents all open new windows too).
    /// The currently-focused window is left on whatever project it was already showing.
    @MainActor
    func adoptGitHubProject(nameWithOwner: String, sshUrl: String? = nil) async -> URL? {
        let dest = Self.defaultClonesRoot.appendingPathComponent(nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            // Already cloned — open the existing clone in a fresh window.
            RecentProjectsService.shared.registerLocal(at: dest)
            ProjectWindowOpener.openProject(at: dest)
            return dest
        }
        // Ensure the parent directory exists, then `gh repo clone` into it.
        try? fm.createDirectory(at: Self.defaultClonesRoot, withIntermediateDirectories: true)
        guard GitHubService.runCommand(["repo", "clone", nameWithOwner, dest.path])?.exit == 0
        else { return nil }
        RecentProjectsService.shared.registerLocal(at: dest)
        ProjectWindowOpener.openProject(at: dest)
        return dest
    }

    /// Where to clone GitHub projects when the user picks "Use as project". Mirrors what most
    /// devs already have — a `~/Developer/<repo-name>` layout.
    static let defaultClonesRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
    }()

    func closeProject() {
        projectRoot = nil
        openFiles.removeAll()
        activeFile = nil
        workspacePane = .terminal
        UserDefaults.standard.removeObject(forKey: "dnp.lastProjectPath")
    }

    func refreshProjectTree() {
        guard let root = projectRoot else { return }
        let fresh = FileNode(url: root.url)
        projectRoot = fresh
    }

    func openFile(_ node: FileNode) {
        guard !node.isDirectory else { return }
        let entry: OpenFile
        if let existing = openFiles.first(where: { $0.node.url == node.url }) {
            entry = existing
        } else {
            entry = OpenFile(node: node, projectRoot: projectRoot?.url)
            openFiles.append(entry)
        }
        activeFile = entry
        workspacePane = .editor(entry)
    }

    func closeFile(_ file: OpenFile) {
        openFiles.removeAll { $0.id == file.id }
        if activeFile?.id == file.id {
            activeFile = openFiles.last
            workspacePane = activeFile.map { .editor($0) } ?? .terminal
        }
    }

    func showTerminal() { workspacePane = .terminal }

    /// Routing: Files / Sessions / Events / Search / Git update the sidebar; Pairing / Settings /
    /// Diagnostics open in the center pane. Click again to return.
    func selectSidebarTab(_ tab: SidebarTab) {
        switch tab {
        case .home:
            // Just go back to the chat session — keep the sidebar's last selection so the
            // user's place in Files / Sessions / Events / Search / Git is preserved.
            workspacePane = .terminal
        case .files, .sessions, .events, .history, .git:
            sidebarTab = tab
        case .pairing:
            workspacePane = (workspacePane == .pairing) ? .terminal : .pairing
        case .settings:
            workspacePane = (workspacePane == .settings) ? .terminal : .settings
        case .diagnostics:
            workspacePane = (workspacePane == .diagnostics) ? .terminal : .diagnostics
        case .github:
            workspacePane = (workspacePane == .github) ? .terminal : .github
        }
    }

    // MARK: Terminal actions (always operate on the currently selected session)

    func startShellInTerminal() {
        Task { @MainActor in
            let cwd = projectRoot?.url.path ?? NSHomeDirectory()
            let term = await ensureCurrentTerminal()
            term.startLoginShell(workingDirectory: cwd)
            workspacePane = .terminal
            sidebarTab = .sessions
        }
    }

    func startClaudeInTerminal() {
        Task { @MainActor in
            guard let path = claude.detectedPath else { return }
            let cwd = projectRoot?.url.path ?? NSHomeDirectory()
            let term = await ensureCurrentTerminal()
            term.startCommand(path, args: [], workingDirectory: cwd)
            workspacePane = .terminal
            sidebarTab = .sessions
        }
    }

    /// Restore last project + open files on launch.
    func restoreLastProject() {
        if let path = UserDefaults.standard.string(forKey: "dnp.lastProjectPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                projectRoot = FileNode(url: url)
            }
        }
    }
}

struct OpenFile: Identifiable, Hashable {
    let id: URL
    let node: FileNode
    let projectRoot: URL?
    init(node: FileNode, projectRoot: URL?) {
        self.id = node.url
        self.node = node
        self.projectRoot = projectRoot
    }
}

enum WorkspacePane: Hashable {
    case terminal
    case editor(OpenFile)
    case pairing
    case settings
    case diagnostics
    case github
}

struct DiagnosticsSnapshot {
    var claudePath: String?
    var claudeVersion: String?
    var ptyAvailable: Bool
    var bridgePort: Int?
    var issues: [String]

    static let empty = DiagnosticsSnapshot(claudePath: nil, claudeVersion: nil, ptyAvailable: false, bridgePort: nil, issues: [])
}
