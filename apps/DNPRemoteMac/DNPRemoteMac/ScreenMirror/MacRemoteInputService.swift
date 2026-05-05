import Foundation
import AppKit
import CoreGraphics

/// Synthesises mouse + keyboard events from `RemoteInputPayload` messages received from
/// iOS. Uses `CGEvent` + `CGEventPost` — same primitives Apple's own remote-control
/// utilities use.
///
/// **Permission.** Posting events to other apps requires Accessibility permission
/// (System Settings → Privacy & Security → Accessibility → DNP Remote Mac). We probe
/// once at start and surface the prompt; until granted, events silently no-op.
@MainActor
final class MacRemoteInputService {
    static let shared = MacRemoteInputService()

    /// Last absolute pointer position — kept so a series of relative deltas can
    /// accumulate without us re-reading the system cursor on every frame.
    private var lastCursorPoint: CGPoint = .zero

    private init() {
        lastCursorPoint = NSEvent.mouseLocation.flippedToScreenSpace()
    }

    func apply(_ payload: RemoteInputPayload, displayPointSize: CGSize) {
        switch payload.kind {
        case .mouseMoveAbsolute:
            guard let nx = payload.x, let ny = payload.y else { return }
            let p = CGPoint(
                x: CGFloat(nx) * displayPointSize.width,
                y: CGFloat(ny) * displayPointSize.height
            )
            moveCursor(to: p)

        case .mouseMoveRelative:
            let dx = CGFloat(payload.dx ?? 0)
            let dy = CGFloat(payload.dy ?? 0)
            let p = CGPoint(x: lastCursorPoint.x + dx, y: lastCursorPoint.y + dy)
            moveCursor(to: clamp(p, to: displayPointSize))

        case .mouseLeftClick:
            click(button: .left, double: false)
        case .mouseLeftDoubleClick:
            click(button: .left, double: true)
        case .mouseRightClick:
            click(button: .right, double: false)

        case .mouseScroll:
            let dy = Int32(payload.dy ?? 0)
            guard let evt = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
            else { return }
            evt.post(tap: .cghidEventTap)

        case .keyDown:
            postKey(keyCode: payload.keyCode ?? 0, down: true, modifiers: payload.modifiers ?? 0)
        case .keyUp:
            postKey(keyCode: payload.keyCode ?? 0, down: false, modifiers: payload.modifiers ?? 0)

        case .keyType:
            // Unicode-typed strings — `CGEvent.keyboardSetUnicodeString` lets us send
            // arbitrary UTF-16 in one event without keymap juggling. Mac receives the
            // characters as if the user had typed them.
            guard let text = payload.text, !text.isEmpty else { return }
            for scalar in text.unicodeScalars {
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                else { continue }
                let utf16 = Array(String(scalar).utf16)
                down.keyboardSetUnicodeString(stringLength: utf16.count,
                                              unicodeString: utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count,
                                            unicodeString: utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Helpers

    private func moveCursor(to point: CGPoint) {
        let evt = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                          mouseCursorPosition: point, mouseButton: .left)
        evt?.post(tap: .cghidEventTap)
        lastCursorPoint = point
    }

    private func click(button: CGMouseButton, double: Bool) {
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up:   CGEventType = button == .left ? .leftMouseUp   : .rightMouseUp
        let downEvt = CGEvent(mouseEventSource: nil, mouseType: down,
                              mouseCursorPosition: lastCursorPoint, mouseButton: button)
        let upEvt   = CGEvent(mouseEventSource: nil, mouseType: up,
                              mouseCursorPosition: lastCursorPoint, mouseButton: button)
        if double { downEvt?.setIntegerValueField(.mouseEventClickState, value: 2) }
        downEvt?.post(tap: .cghidEventTap)
        upEvt?.post(tap: .cghidEventTap)
        if double {
            // Second click of the double — same setup, click count = 2.
            let d2 = CGEvent(mouseEventSource: nil, mouseType: down,
                             mouseCursorPosition: lastCursorPoint, mouseButton: button)
            let u2 = CGEvent(mouseEventSource: nil, mouseType: up,
                             mouseCursorPosition: lastCursorPoint, mouseButton: button)
            d2?.setIntegerValueField(.mouseEventClickState, value: 2)
            u2?.setIntegerValueField(.mouseEventClickState, value: 2)
            d2?.post(tap: .cghidEventTap)
            u2?.post(tap: .cghidEventTap)
        }
    }

    private func postKey(keyCode: Int, down: Bool, modifiers: UInt) {
        guard let evt = CGEvent(keyboardEventSource: nil,
                                virtualKey: CGKeyCode(keyCode),
                                keyDown: down) else { return }
        evt.flags = CGEventFlags(rawValue: UInt64(modifiers))
        evt.post(tap: .cghidEventTap)
    }

    private func clamp(_ p: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(p.x, size.width  - 1)),
            y: max(0, min(p.y, size.height - 1))
        )
    }
}

private extension CGPoint {
    /// `NSEvent.mouseLocation` is bottom-left origin; CGEvent expects top-left. Flip.
    func flippedToScreenSpace() -> CGPoint {
        guard let h = NSScreen.main?.frame.height else { return self }
        return CGPoint(x: x, y: h - y)
    }
}
