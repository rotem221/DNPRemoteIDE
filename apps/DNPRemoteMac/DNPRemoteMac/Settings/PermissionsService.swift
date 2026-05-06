import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Combine
import UserNotifications

/// Centralised view-model for every macOS Privacy & Security permission
/// DNP Remote Mac depends on. The Settings → Permissions pane binds to
/// `@Published` properties on this singleton, polls `refresh()` on
/// appear, and re-polls whenever the app returns to the foreground —
/// so a user who flips a permission in System Settings sees the
/// in-app status update without having to relaunch.
///
/// **Why a service rather than three independent SwiftUI views**: the
/// status of Accessibility / Screen Recording / Notifications drives
/// real runtime behaviour (the unlock button refuses to send keystrokes
/// without Accessibility, the screen-mirror service silently captures
/// nothing without Screen Recording). Putting the queries behind one
/// object means the runtime gates and the UI badges can both bind to
/// the same source of truth, and refreshing one updates the other.
@MainActor
final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()

    /// One row per permission the app cares about. New permissions
    /// land here as the surface grows (e.g. Camera, Microphone if we
    /// ever need them on the Mac side).
    enum Kind: String, CaseIterable, Identifiable {
        case accessibility
        case screenRecording
        case notifications
        case localNetwork
        case automation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility:    return "Accessibility"
            case .screenRecording:  return "Screen Recording"
            case .notifications:    return "Notifications"
            case .localNetwork:     return "Local Network"
            case .automation:       return "Automation (Apple Events)"
            }
        }

        var symbol: String {
            switch self {
            case .accessibility:    return "accessibility"
            case .screenRecording:  return "rectangle.on.rectangle"
            case .notifications:    return "bell.badge"
            case .localNetwork:     return "wifi"
            case .automation:       return "gearshape.2"
            }
        }

        /// Why DNP Remote needs this — copy is shown directly to the
        /// user in the permissions card so they understand the cost
        /// of leaving it off before clicking "Open Settings".
        var rationale: String {
            switch self {
            case .accessibility:
                return "Lets DNP Remote send mouse and keyboard events to your Mac. Required by Screen Mirror remote control and the Unlock button on the paired iPhone."
            case .screenRecording:
                return "Lets DNP Remote capture your Mac's display so the paired iPhone can see what's happening. Used only while a Screen Mirror session is active."
            case .notifications:
                return "Surfaces pairing requests, approval prompts, and session events as banners when DNP Remote is in the background."
            case .localNetwork:
                return "Lets your paired iPhone reach this Mac over Wi-Fi or your LAN. macOS prompts the first time the bridge starts a connection."
            case .automation:
                return "Lets DNP Remote launch `gh auth login` from the GitHub pane so you can sign in to GitHub without leaving the IDE. macOS prompts the first time the helper runs."
            }
        }

        /// Deep link into the right pane of System Settings. The
        /// `x-apple.systempreferences:` URL scheme is the supported,
        /// non-private way of jumping straight to a panel without
        /// requiring the user to navigate.
        var systemSettingsURL: URL? {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .notifications:
                return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            case .localNetwork:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
            case .automation:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
        }
    }

    /// What the system currently reports about a given permission.
    /// `unknown` covers the cases where macOS does not expose a
    /// queryable API at all (Local Network, Automation) — we surface
    /// it explicitly rather than guessing "granted" so the user is
    /// not lulled into thinking we have a working permission when
    /// in reality we just don't know.
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        case unknown

        var label: String {
            switch self {
            case .granted:        return "Granted"
            case .denied:         return "Required"
            case .notDetermined:  return "Not yet asked"
            case .unknown:        return "System-managed"
            }
        }

        var isOK: Bool { self == .granted || self == .unknown }
    }

    // MARK: - Published state

    @Published private(set) var accessibility: Status = .notDetermined
    @Published private(set) var screenRecording: Status = .notDetermined
    @Published private(set) var notifications: Status = .notDetermined
    @Published private(set) var localNetwork: Status = .unknown
    @Published private(set) var automation: Status = .unknown

    private var foregroundObserver: NSObjectProtocol?

    private init() {
        // Re-poll automatically when the app comes back to the
        // foreground — this is how the user sees in-app status flip
        // to "Granted" right after they've toggled the switch in
        // System Settings without having to find a refresh button.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { @MainActor in self.refresh() }
    }

    deinit {
        if let token = foregroundObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public API

    func status(for kind: Kind) -> Status {
        switch kind {
        case .accessibility:    return accessibility
        case .screenRecording:  return screenRecording
        case .notifications:    return notifications
        case .localNetwork:     return localNetwork
        case .automation:       return automation
        }
    }

    /// Re-poll every probeable permission. Cheap (a couple of system
    /// calls); fine to call from view appear / refresh button / app
    /// foreground.
    func refresh() {
        accessibility = probeAccessibility()
        screenRecording = probeScreenRecording()
        Task { await self.probeNotifications() }
        // localNetwork and automation are intentionally left alone —
        // macOS does not expose a queryable API for either, and we
        // mark them `unknown` rather than guessing.
    }

    /// Open the System Settings pane for `kind`. Falls through silently
    /// if the URL fails to construct (which only happens if Apple
    /// changes the scheme — defensive, not expected).
    func openSystemSettings(for kind: Kind) {
        guard let url = kind.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Trigger a one-shot user-facing prompt for a permission we can
    /// actually request inline. Today only Notifications has a
    /// callable request API; the others must be granted through
    /// System Settings, so the UI routes those to `openSystemSettings`.
    func requestInline(for kind: Kind) async {
        switch kind {
        case .notifications:
            _ = await MacNotificationService.shared.requestAuthorization()
            await probeNotifications()
        case .accessibility:
            // Ask the system to prompt the user. Once the dialog is
            // shown, the user has to drag-drop our app into the
            // Privacy → Accessibility list and toggle it on; until
            // they do, we stay "denied". The prompt is one-shot per
            // process unless the user explicitly resets TCC.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        case .screenRecording:
            // `CGRequestScreenCaptureAccess` shows the Apple-managed
            // permission dialog and returns true once granted.
            // After the call the user typically has to relaunch the
            // app for the entitlement to fully take effect — that
            // restart prompt is shown by the system, not us.
            _ = CGRequestScreenCaptureAccess()
        case .localNetwork, .automation:
            openSystemSettings(for: kind)
        }
    }

    // MARK: - Probes

    private func probeAccessibility() -> Status {
        // `AXIsProcessTrusted()` returns the current state without
        // popping a prompt, which is exactly what we want for a
        // background poll. Apple does not expose a "denied vs not
        // determined" distinction, so we return `denied` either way
        // — the rationale + Open Settings button gives the user a
        // clear path forward regardless.
        return AXIsProcessTrusted() ? .granted : .denied
    }

    private func probeScreenRecording() -> Status {
        if #available(macOS 11.0, *) {
            // `CGPreflightScreenCaptureAccess` is the modern
            // equivalent of `AXIsProcessTrusted` for the Screen
            // Recording permission — same query-without-prompt
            // semantics. Returns true only when the user has
            // explicitly granted permission to this binary.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        return .unknown
    }

    private func probeNotifications() async {
        let center = UNUserNotificationCenter.current()
        let s = await center.notificationSettings()
        let mapped: Status
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            mapped = .granted
        case .denied:
            mapped = .denied
        case .notDetermined:
            mapped = .notDetermined
        @unknown default:
            mapped = .unknown
        }
        notifications = mapped
    }
}

