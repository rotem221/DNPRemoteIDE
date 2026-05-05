import Foundation

// MARK: - Screen mirror

/// iOS → Mac. Asks the Mac to start sending screen frames at the requested target rate.
/// The Mac caps at its own configured maximum so a malicious client can't DoS the Mac
/// with a 240fps request.
public struct ScreenMirrorStartPayload: Codable, Hashable, Sendable {
    /// Frames-per-second the iOS client wants. Mac clamps to a sane band (default 5).
    public let targetFPS: Int
    /// Max long-edge pixels the iOS client wants. Mac clamps + downscales — keeps the
    /// JPEG-over-JSON bandwidth reasonable on shared LAN / Tailscale.
    public let maxLongEdge: Int
    public init(targetFPS: Int = 5, maxLongEdge: Int = 1280) {
        self.targetFPS = targetFPS
        self.maxLongEdge = maxLongEdge
    }
}

public struct ScreenMirrorStopPayload: Codable, Hashable, Sendable {
    public init() {}
}

/// Mac → iOS. One captured screen frame. JPEG bytes are base64-encoded into JSON for
/// pragmatic transport over the existing signed-envelope bridge — at 5fps × 1280-long
/// the inflation is ~33% of a small JPEG, manageable on any modern radio.
public struct ScreenMirrorFramePayload: Codable, Hashable, Sendable {
    public let jpegBase64: String
    /// Pixel size of the JPEG (post-downscale on the Mac). iOS uses this to map touch
    /// coordinates back to display coordinates when synthesising mouse moves.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Logical (point) size of the captured display — Mac uses this so iOS can express
    /// pointer positions in points instead of pixels (matches CGEvent expectations).
    public let displayPointWidth: Int
    public let displayPointHeight: Int
    /// Capture timestamp on Mac wall clock — iOS skips frames with stale timestamps.
    public let capturedAt: Date
    /// Mouse cursor position at capture time, in 0-1 fractions of the display points.
    /// Optional for backwards compatibility with older clients/builds. iOS draws a
    /// virtual cursor sprite at this position so the user can see where the pointer
    /// is even when the OS-level capture omits the system cursor (varies by macOS
    /// version + Screen-Recording permission state).
    public let cursorX: Double?
    public let cursorY: Double?

    public init(jpegBase64: String,
                pixelWidth: Int, pixelHeight: Int,
                displayPointWidth: Int, displayPointHeight: Int,
                capturedAt: Date,
                cursorX: Double? = nil, cursorY: Double? = nil) {
        self.jpegBase64 = jpegBase64
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.displayPointWidth = displayPointWidth
        self.displayPointHeight = displayPointHeight
        self.capturedAt = capturedAt
        self.cursorX = cursorX
        self.cursorY = cursorY
    }
}

// MARK: - Remote input (iOS → Mac)

/// One synthetic input event the iOS client is asking the Mac to perform via CGEvent.
/// All values are normalized so the iOS client doesn't need to know the Mac's display
/// dimensions: positions are 0-1 fractions of the display point size; mouse deltas are
/// also in points. The Mac scales back up via `displayPointWidth/Height` from the most
/// recent frame.
public struct RemoteInputPayload: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Hashable, Sendable {
        case mouseMoveAbsolute   // x/y are 0-1 fractions of display
        case mouseMoveRelative   // dx/dy are point deltas
        case mouseLeftClick
        case mouseLeftDoubleClick
        case mouseRightClick
        case mouseScroll         // dy in points (positive = up)
        case keyDown             // keyCode (Carbon virtual keycode)
        case keyUp
        case keyType             // text — Mac issues a sequence of keyDown/keyUp via UCKeyTranslate
    }

    public let kind: Kind
    /// Normalised x/y for `mouseMoveAbsolute`. nil for other kinds.
    public let x: Double?
    public let y: Double?
    /// Point deltas for `mouseMoveRelative` / `mouseScroll`.
    public let dx: Double?
    public let dy: Double?
    /// Carbon virtual keycode for keyDown/keyUp.
    public let keyCode: Int?
    /// Modifier mask — bitfield of NSEvent.ModifierFlags.rawValue (cmd / shift / etc.).
    public let modifiers: UInt?
    /// Text for `keyType`.
    public let text: String?

    public init(kind: Kind,
                x: Double? = nil, y: Double? = nil,
                dx: Double? = nil, dy: Double? = nil,
                keyCode: Int? = nil, modifiers: UInt? = nil,
                text: String? = nil) {
        self.kind = kind
        self.x = x; self.y = y
        self.dx = dx; self.dy = dy
        self.keyCode = keyCode; self.modifiers = modifiers
        self.text = text
    }
}

// MARK: - Cursor stream (Mac → iOS)

/// Cursor-only update streamed at ~30Hz from the Mac while the screen mirror
/// is active. Decoupling cursor from frames is what gives the iOS preview a
/// smooth pointer even when the frame rate is held at 5–8fps for bandwidth
/// — the same trick the DNP Remote Vibe Coding reference uses
/// (`screen_cursor` WS message). Both fields are 0–1 fractions of the
/// captured display, top-left origin.
public struct ScreenMirrorCursorPayload: Codable, Hashable, Sendable {
    public let cursorX: Double
    public let cursorY: Double
    public init(cursorX: Double, cursorY: Double) {
        self.cursorX = cursorX
        self.cursorY = cursorY
    }
}
