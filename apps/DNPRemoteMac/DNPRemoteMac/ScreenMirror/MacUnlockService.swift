import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// Handles `MacUnlockRequest` envelopes by waking the display, typing
/// the supplied password into the lock screen, and pressing Return.
///
/// **How it actually unlocks**. The Mac's lock screen is just a
/// password field with focus — anything we type via `CGEvent` lands in
/// it the same way real keystrokes do. The trick is making sure the
/// display is awake first; until it is, key events go nowhere. We use
/// two complementary mechanisms:
///
///   1. `IOPMAssertionDeclareUserActivity` — the supported,
///      sandbox-safe way of telling the power manager "treat this as a
///      user-driven wake event". This wakes the screen if it is
///      asleep, and resets the idle timer if it is already on.
///   2. A short delay (~600ms) before the first keystroke so the
///      lock-screen password field has time to take first-responder
///      focus.
///
/// **Permission**. Synthesising keystrokes that reach the lock-screen
/// process requires Accessibility permission on the Mac
/// (`System Settings → Privacy & Security → Accessibility →
/// DNP Remote Mac`). The host app's screen-mirror feature already
/// prompts for this; if the user has not yet granted it, the events
/// silently no-op and we surface a clear "Accessibility permission is
/// required" reason in the response so the iOS toast guides them.
@MainActor
final class MacUnlockService {
    static let shared = MacUnlockService()

    private init() {}

    struct Outcome {
        let ok: Bool
        let reason: String?
    }

    /// Wake the display, wait briefly, type the password, press Return.
    /// Returns once the keystrokes have been posted; we don't try to
    /// observe whether the system actually unlocked because there is
    /// no public API that surfaces lock-screen state from a sandboxed
    /// host. The response is essentially "we delivered the keystrokes"
    /// — the user gets visual confirmation by looking at their Mac.
    func unlock(password: String) async -> Outcome {
        guard !password.isEmpty else {
            return .init(ok: false, reason: "empty password")
        }

        // Accessibility permission gate. Without this, posting
        // keystrokes to the loginwindow process is silently dropped
        // by the system. We pass `prompt: false` so we don't trigger
        // the permission prompt on every unlock attempt — the host
        // app already prompts once when the user enables screen
        // mirror, and re-prompting here would be a confusing surprise.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        guard AXIsProcessTrustedWithOptions(opts as CFDictionary) else {
            return .init(ok: false, reason: "Accessibility permission required")
        }

        wakeDisplay()

        // 600ms gives the loginwindow / screensaverengine process
        // enough time to take focus of the password field after the
        // wake assertion fires. Empirically anything < ~400ms races
        // and the first one or two characters get dropped.
        try? await Task.sleep(nanoseconds: 600_000_000)

        for scalar in password.unicodeScalars {
            postUnicodeKey(String(scalar))
            // Tiny inter-key delay so the lock-screen process has
            // time to coalesce each event. Without this gap on
            // some Macs the password field receives a truncated
            // string at high typing speeds.
            try? await Task.sleep(nanoseconds: 12_000_000)
        }

        // Return key — virtual key code 36. This submits the
        // password. On macOS Sonoma+ the field auto-submits when it
        // matches, but pressing Return is the universally-supported
        // path and works on both lock-screen and login-window.
        postKey(virtualKey: 36, down: true)
        postKey(virtualKey: 36, down: false)

        return .init(ok: true, reason: nil)
    }

    // MARK: - Helpers

    /// Tell the power manager to treat this moment as user activity,
    /// which wakes the display if asleep and resets the idle timer if
    /// already on. Bridged from the Objective-C IOKit symbol because
    /// `IOPMAssertionDeclareUserActivity` is not exposed via the
    /// auto-generated Swift overlay.
    private func wakeDisplay() {
        var assertionId: IOPMAssertionID = 0
        // `kIOPMAssertionTypePreventUserIdleDisplaySleep` would prevent
        // sleep going forward; `IOPMAssertionDeclareUserActivity` with
        // the "user is active" type is what actually wakes a sleeping
        // display.
        let name = "DNP Remote Mac unlock" as CFString
        let result = IOPMAssertionDeclareUserActivity(
            name,
            kIOPMUserActiveLocal,
            &assertionId
        )
        if result != kIOReturnSuccess {
            // Best-effort wake: if the assertion fails, we still try
            // to type — most often the screen is already on and the
            // assertion is a no-op anyway.
        }
    }

    private func postUnicodeKey(_ s: String) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }
        let utf16 = Array(s.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postKey(virtualKey: CGKeyCode, down: Bool) {
        guard let evt = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: down)
        else { return }
        evt.post(tap: .cghidEventTap)
    }
}
