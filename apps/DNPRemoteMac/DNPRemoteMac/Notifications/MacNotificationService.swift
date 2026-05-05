import Foundation
import UserNotifications
import AppKit

/// Local user notifications for the Mac host. Surfaces iOS device connect/disconnect, new
/// pairing requests, and session crashes / errors as banners in the user's Notification
/// Center — useful when the Mac window is in the background, on another Space, or hidden.
///
/// Each category is gated by an `@AppStorage` flag the user controls in Settings, plus a
/// master "Enable notifications" switch that turns the whole subsystem off without losing
/// the per-category preferences.
@MainActor
final class MacNotificationService: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = MacNotificationService()

    enum Category: String {
        case deviceChange = "DNP_MAC_DEVICE"
        case pairing      = "DNP_MAC_PAIRING"
        case sessionError = "DNP_MAC_SESSION_ERROR"
        case approval     = "DNP_MAC_APPROVAL"
        /// Generic "Claude needs attention" — fired for `Notification` hook messages
        /// that don't carry a structured approval (idle prompt, MCP server input,
        /// permission prompts that bypassed our PreToolUse/PermissionRequest path).
        /// No inline actions; tapping the banner just focuses the originating session.
        case attention    = "DNP_MAC_ATTENTION"
        /// Session ended (terminal exited normally, user closed it,
        /// `claude` returned, etc.). Distinct from `sessionError` —
        /// session-end is the expected "Claude finished" outcome,
        /// session-error is an unexpected crash.
        case sessionEnded = "DNP_MAC_SESSION_ENDED"
    }

    enum Action: String {
        case approve = "APPROVE"
        case deny    = "DENY"
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()

    /// Tap handler — view model can register this to switch the active session when the user
    /// clicks a "session error" banner from outside the app.
    var onSessionTap: ((_ sessionId: UUID) -> Void)?

    /// Approve / Deny inline action handler. The Mac view model registers this so a banner
    /// click of "Approve" / "Deny" routes back to the same `handleApprovalDecision` path the
    /// in-app buttons use.
    var onApprovalAction: ((_ approvalId: UUID, _ decision: ApprovalDecision) -> Void)?

    private override init() { super.init() }

    func bootstrap() async {
        center.delegate = self
        registerCategories()
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        let s = await center.notificationSettings()
        self.authorizationStatus = s.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorization()
            return granted
        } catch {
            return false
        }
    }

    /// Open `System Settings → Notifications → DNP Remote Mac` so the user can flip the
    /// system-level toggle when our in-app toggles can't (denied / partially denied state).
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Triggers

    func fireDeviceConnected(deviceName: String) {
        guard masterEnabled, prefBool("dnp.mac.notifyDeviceChanges", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "iPhone connected"
        content.body = "\(deviceName) is now reachable."
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.deviceChange.rawValue
        post(id: "device-connected-\(deviceName)", content: content)
    }

    func fireDeviceDisconnected(deviceName: String) {
        guard masterEnabled, prefBool("dnp.mac.notifyDeviceChanges", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "iPhone disconnected"
        content.body = "\(deviceName) lost connection."
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.deviceChange.rawValue
        post(id: "device-disconnected-\(deviceName)", content: content)
    }

    func firePairingRequest(deviceName: String) {
        guard masterEnabled, prefBool("dnp.mac.notifyPairing", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Pairing request"
        content.body = "\(deviceName) wants to pair with this Mac."
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.pairing.rawValue
        post(id: "pairing-\(deviceName)", content: content)
    }

    /// High-priority approval banner. Uses `.timeSensitive` interruption so the alert
    /// breaks through Focus modes, includes inline **Approve / Deny** buttons (visible by
    /// default in the banner and on the lock screen), and — when the user has enabled the
    /// "bring app to front" toggle — activates the app so the user lands on the approval
    /// card instead of having to switch contexts manually.
    func fireApprovalRequest(approvalId: UUID,
                             sessionId: UUID,
                             sessionTitle: String,
                             summary: String,
                             risk: RiskLevel) {
        guard masterEnabled, prefBool("dnp.mac.notifyApprovals", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Approval needed"
        content.subtitle = sessionTitle
        content.body = summary
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.approval.rawValue
        // Time-sensitive notifications:
        // - Bypass Do Not Disturb / Focus modes
        // - Surface above other notifications in the corner stack
        // - Persist longer in Notification Center
        // High-risk approvals additionally get the `critical` interruption hint where the
        // platform supports it (still under user control via the Focus settings).
        if risk == .high || risk == .critical {
            content.interruptionLevel = .critical
        } else {
            content.interruptionLevel = .timeSensitive
        }
        content.threadIdentifier = "session-\(sessionId.uuidString)"
        content.userInfo = [
            "approvalId": approvalId.uuidString,
            "sessionId":  sessionId.uuidString
        ]
        post(id: "approval-\(approvalId.uuidString)", content: content)

        // Optional: bring the Mac app to the front so the in-app approval card is visible
        // immediately. Off by default — many users prefer the banner-only flow.
        if prefBool("dnp.mac.approvalsBringToFront", default: false) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Dismiss the banner once the request is no longer pending (decided here, on iOS, or
    /// expired). Stops a stale "Approval needed" alert from sitting in the corner.
    func clearApprovalRequest(approvalId: UUID) {
        let key = "approval-\(approvalId.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [key])
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// Generic "Claude needs attention" banner. Fires for the Claude Code `Notification`
    /// hook (idle prompt, "waiting for your input", or permission prompts that didn't
    /// produce a structured ApprovalRequest). Time-sensitive so it crosses Focus modes,
    /// but no inline Approve/Deny — there's nothing to decide here, the user has to look
    /// at the actual TUI / approval card. Caller is expected to dedupe against active
    /// approvals in the same session before invoking this.
    func fireAttention(sessionId: UUID, sessionTitle: String, message: String) {
        guard masterEnabled, prefBool("dnp.mac.notifyAttention", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude needs attention"
        content.subtitle = sessionTitle
        content.body = message
        if soundEnabled { content.sound = .default }
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Category.attention.rawValue
        content.threadIdentifier = "session-\(sessionId.uuidString)"
        content.userInfo = ["sessionId": sessionId.uuidString]
        // Per-session id so a second attention banner replaces a stale one rather than
        // stacking — Claude can fire the Notification hook multiple times in a row when
        // it keeps sitting at an idle prompt.
        post(id: "attention-\(sessionId.uuidString)", content: content)
    }

    /// Drop the attention banner once the user has acted (a real approval surfaced, the
    /// session has resumed, or the app was brought to the front).
    func clearAttention(sessionId: UUID) {
        let key = "attention-\(sessionId.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [key])
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    /// "Session ended" banner. Fires when a Claude session transitions
    /// to its terminal lifecycle state (`.ended`, `.crashed`,
    /// `.disconnected`). Gated by `dnp.mac.notifySessionEnded` (default
    /// OFF — the user opts in explicitly; most sessions ending is
    /// boring). `reason` is rendered into the title so a crash banner
    /// reads differently from a clean exit.
    func fireSessionEnded(sessionId: UUID, sessionTitle: String, reason: String) {
        guard masterEnabled, prefBool("dnp.mac.notifySessionEnded", default: false) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session \(reason)"
        content.subtitle = sessionTitle
        content.body = "The session has finished."
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.sessionEnded.rawValue
        content.threadIdentifier = "session-\(sessionId.uuidString)"
        content.userInfo = ["sessionId": sessionId.uuidString]
        post(id: "session-ended-\(sessionId.uuidString)", content: content)
    }

    func fireSessionError(sessionId: UUID, sessionTitle: String, summary: String) {
        guard masterEnabled, prefBool("dnp.mac.notifyErrors", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session error"
        content.subtitle = sessionTitle
        content.body = summary
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.sessionError.rawValue
        content.threadIdentifier = "session-\(sessionId.uuidString)"
        content.userInfo = ["sessionId": sessionId.uuidString]
        post(id: "session-error-\(UUID().uuidString)", content: content)
    }

    /// Surface a recovered main-thread stall to the user. The watchdog already logged the
    /// event to `memory/crashes/watchdog.log`; this banner is the *visible* signal so the
    /// user knows the IDE was unresponsive even when they only noticed by glancing at iOS.
    /// Gated by the same "errors and crashes" toggle so it can be silenced.
    func fireMainThreadStallRecovered(durationSeconds: TimeInterval) {
        guard masterEnabled, prefBool("dnp.mac.notifyErrors", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "DNP Remote was unresponsive"
        content.body = "Main thread was blocked for ~\(Int(durationSeconds.rounded()))s. The connection may have appeared stale on iOS during this window."
        if soundEnabled { content.sound = .default }
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Category.sessionError.rawValue
        post(id: "stall-\(UUID().uuidString)", content: content)
    }

    func fireSessionCrash(sessionId: UUID, sessionTitle: String, summary: String) {
        guard masterEnabled, prefBool("dnp.mac.notifyErrors", default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session crashed"
        content.subtitle = sessionTitle
        content.body = summary
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Category.sessionError.rawValue
        content.threadIdentifier = "session-\(sessionId.uuidString)"
        content.userInfo = ["sessionId": sessionId.uuidString]
        post(id: "session-crash-\(sessionId.uuidString)", content: content)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground-presentation policy — same rule the user asked for on iOS: while the
    /// IDE is the active app, NO banners and NO sound. The user has the in-app
    /// affordances (the inline approval card / sidebar status / dock-icon badge); a
    /// system banner overlay on top is intrusive. The notification still lands in
    /// Notification Center's history (`.list`). When the app is backgrounded /
    /// minimized this delegate isn't called and the system shows the banner natively.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier

        switch category {
        case Category.sessionError.rawValue, Category.attention.rawValue:
            if let sidStr = info["sessionId"] as? String,
               let sid = UUID(uuidString: sidStr) {
                onSessionTap?(sid)
                NSApp.activate(ignoringOtherApps: true)
            }

        case Category.approval.rawValue:
            guard let idStr = info["approvalId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            switch response.actionIdentifier {
            case Action.approve.rawValue:
                onApprovalAction?(id, .approve)
            case Action.deny.rawValue:
                onApprovalAction?(id, .reject)
            case UNNotificationDefaultActionIdentifier:
                // Banner body tapped (no inline action) — focus the app + originating session.
                if let sidStr = info["sessionId"] as? String,
                   let sid = UUID(uuidString: sidStr) {
                    onSessionTap?(sid)
                }
                NSApp.activate(ignoringOtherApps: true)
            default: break
            }

        default: break
        }
    }

    // MARK: - Helpers

    private var masterEnabled: Bool {
        prefBool("dnp.mac.notifyEnabled", default: true)
    }

    private var soundEnabled: Bool {
        prefBool("dnp.mac.notifySound", default: true)
    }

    private func prefBool(_ key: String, default def: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return def }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func registerCategories() {
        let device = UNNotificationCategory(
            identifier: Category.deviceChange.rawValue,
            actions: [], intentIdentifiers: [], options: []
        )
        let pairing = UNNotificationCategory(
            identifier: Category.pairing.rawValue,
            actions: [], intentIdentifiers: [], options: []
        )
        let sessionError = UNNotificationCategory(
            identifier: Category.sessionError.rawValue,
            actions: [], intentIdentifiers: [], options: []
        )
        // Approval category — inline Allow / Don't Allow buttons mirror Claude Code's
        // TUI wording exactly. The system banner action labels are static (UN can't pick
        // labels per-notification), so we use the most common phrasing — tool-permission
        // approvals dominate the traffic, and "Yes"/"No"-style confirmations still resolve
        // correctly since the underlying response is the same `1\r` / `2\r` keystroke.
        // Don't Allow is `.destructive` so it renders red, matching the in-app affordance.
        let approve = UNNotificationAction(
            identifier: Action.approve.rawValue,
            title: "Allow",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: Action.deny.rawValue,
            title: "Don't Allow",
            options: [.destructive]
        )
        let approval = UNNotificationCategory(
            identifier: Category.approval.rawValue,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        // Attention category — generic "Claude needs attention" banner. No inline
        // actions: it's a wake-up nudge, not a decision point. Tapping the banner
        // focuses the originating session via `onSessionTap`.
        let attention = UNNotificationCategory(
            identifier: Category.attention.rawValue,
            actions: [], intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([device, pairing, sessionError, approval, attention])
    }

    private func post(id: String, content: UNMutableNotificationContent) {
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(req) { _ in }
    }
}
