import Foundation
import AppKit
import Combine
import CoreGraphics

/// Tracks whether the Mac is currently sitting at the lock screen / a
/// password-protected screensaver. iOS uses this signal to hide the
/// "Unlock Mac" button on the screen-mirror page when the desktop is
/// already accessible — sending the password into a logged-in session
/// would just type random characters into whichever window has focus.
///
/// **How we detect lock state**
///
/// Two complementary sources, both supported public APIs:
///   1. `CGSessionCopyCurrentDictionary()` — returns a snapshot of the
///      current Quartz session.  Reading the `CGSSessionScreenIsLocked`
///      key gives the boolean we need at any moment, used both for
///      the initial state at app launch and as a sanity-check refresh
///      when the bridge re-broadcasts ProjectInfo.
///   2. `DistributedNotificationCenter` — `com.apple.screenIsLocked` /
///      `com.apple.screenIsUnlocked` fire whenever the lock status
///      flips (login window, screensaver, password-protected screen
///      sleep). They're the only Apple-supported event-based hook for
///      lock state without going through private APIs, and they fire
///      synchronously on the main run loop so we can react in real
///      time instead of polling.
///
/// **Why a singleton**: every consumer (the screen-mirror frame
/// loop, the bridge dispatcher's projectInfo broadcast, future
/// notification gates) needs the *same* live value. A single owner
/// of the observers also keeps us from racing on lock/unlock
/// transitions — only one notification handler runs per event,
/// flipping the flag, and everyone reads off `@Published`.
@MainActor
final class MacLockMonitorService: ObservableObject {
    static let shared = MacLockMonitorService()

    /// Latest known lock state. Drives the `isLocked` field in every
    /// outgoing `ProjectInfoPayload`. The default is `false` to match
    /// the most common case at app launch (the user opened the IDE
    /// from a logged-in session); the first observer/poll will
    /// correct it within a few hundred milliseconds if we're wrong.
    @Published private(set) var isLocked: Bool = false

    /// Fires after every change so callers (`MacAppViewModel`) can
    /// trigger a fresh `broadcastProjectInfo` without subscribing to
    /// the `@Published` directly — keeps the bridge surface tiny and
    /// avoids the `Combine`-on-MainActor-from-non-isolated-callback
    /// dance.
    var onLockStateChanged: ((Bool) -> Void)?

    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    private init() {}

    /// Snapshot the current state and arm the lock/unlock observers.
    /// Idempotent — calling `start()` more than once just re-reads
    /// the snapshot without stacking up additional observers.
    func start() {
        readCurrent()
        installObserversIfNeeded()
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        if let token = lockObserver { center.removeObserver(token); lockObserver = nil }
        if let token = unlockObserver { center.removeObserver(token); unlockObserver = nil }
    }

    /// Synchronously read the current lock state.  Cheap and exposed
    /// publicly so the bridge dispatcher can also poll right before
    /// it builds a `ProjectInfoPayload` — guards against a missed
    /// notification (e.g. process suspended while screen was locked
    /// from another input source).
    func readCurrent() {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No session info available means there's likely no
            // graphical session at all (server install, headless).
            // Treat as "unlocked" — iOS will simply show its
            // unlock affordance, same as before this feature shipped.
            isLocked = false
            return
        }
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) == true
        applyLocked(locked)
    }

    private func installObserversIfNeeded() {
        let center = DistributedNotificationCenter.default()
        if lockObserver == nil {
            lockObserver = center.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyLocked(true) }
            }
        }
        if unlockObserver == nil {
            unlockObserver = center.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyLocked(false) }
            }
        }
    }

    private func applyLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        onLockStateChanged?(locked)
    }
}
