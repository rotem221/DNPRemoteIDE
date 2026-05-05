import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Captures the main display, downscales, JPEG-encodes, and hands frames to the
/// dispatcher for transmission to iOS. Driven by a simple `DispatchSourceTimer` at the
/// configured FPS — pragmatic MVP, no ScreenCaptureKit / VideoToolbox setup.
///
/// **Permissions.** Calling `CGWindowListCreateImage` triggers macOS's TCC prompt for
/// Screen Recording on first use. Without permission, the call returns nil and frames
/// don't ship. The user has to grant once via System Settings → Privacy & Security →
/// Screen Recording.
///
/// **Bandwidth.** JPEG quality 0.55, long-edge clamped to client's request (1280 default).
/// At 5fps that's typically 80-150 KB/sec on busy displays — fine for LAN and Tailscale.
@MainActor
final class MacScreenMirrorService {
    static let shared = MacScreenMirrorService()

    /// Caller installs this when starting; it's how frames reach the dispatcher.
    var onFrame: ((ScreenMirrorFramePayload) -> Void)?

    private var timer: DispatchSourceTimer?
    /// Separate, faster cursor-only timer running at ~30Hz so the iOS
    /// preview shows a smooth cursor even when frames are held at 5–8fps for
    /// bandwidth. Same model the DNP Remote Vibe Coding reference uses.
    private var cursorTimer: DispatchSourceTimer?
    private(set) var isCapturing = false
    private var targetFPS: Int = 5
    /// Live read by `captureFrame` from the timer's background queue, written from
    /// MainActor in `start(...)`. `MainActor.assumeIsolated` was the previous reader
    /// and tripped `EXC_BREAKPOINT` because the timer queue is NOT the main actor.
    /// `_settings` carries an `OSAllocatedUnfairLock`-guarded snapshot so the
    /// background reader never crosses an actor boundary.
    let settings = MirrorSettingsBox()
    private var _settings: MirrorSettingsBox { settings }

    private init() {}

    func start(targetFPS: Int, maxLongEdge: Int) {
        // Clamp client-requested rate / size to sane caps. The `maxLongEdge`
        // ceiling dropped from 1920 to 1280 here — at 1920 the JPEG payloads
        // saturate even Tailscale enough to make iOS feel "stuck and not
        // live", which is exactly the user's report. 1280 is sharp on
        // iPhone screens and roughly halves the per-frame byte budget vs.
        // 1920 (1280² / 1920² ≈ 0.44).
        self.targetFPS = max(1, min(targetFPS, 15))
        let clampedLong = max(360, min(maxLongEdge, 1280))
        _settings.setMaxLongEdge(clampedLong)
        guard prefBool("dnp.mac.screenMirrorEnabled", default: false) else { return }
        // Mid-stream reconfig: if already capturing AND the user changed FPS, rebuild
        // the timer so the new interval takes effect immediately. (Without this the
        // previous build would silently keep the old rate.)
        if isCapturing {
            scheduleTimer()
            scheduleCursorTimer()
            return
        }
        isCapturing = true
        scheduleTimer()
        scheduleCursorTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        cursorTimer?.cancel()
        cursorTimer = nil
        isCapturing = false
    }

    private func scheduleTimer() {
        timer?.cancel()
        let interval = 1.0 / Double(self.targetFPS)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: interval)
        let settings = _settings  // `Sendable` — captured into the nonisolated handler safely.
        t.setEventHandler { [weak self] in self?.captureFrame(settings: settings) }
        t.resume()
        timer = t
    }

    /// Cursor-only timer running at ~30Hz. Each tick reads the live cursor
    /// position and pushes a tiny `ScreenMirrorCursorPayload` through
    /// `cursorSink` — `dispatcher` signs + sends. Independent of frame
    /// cadence so the iOS preview can show a smooth pointer even at low
    /// FPS. Runs on a background dispatch queue (NSEvent.mouseLocation is
    /// thread-safe; no MainActor hop required).
    private func scheduleCursorTimer() {
        cursorTimer?.cancel()
        let interval: TimeInterval = 1.0 / 30.0   // ~33ms / 30Hz
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: interval)
        let settings = _settings
        t.setEventHandler { Self.tickCursor(settings: settings) }
        t.resume()
        cursorTimer = t
    }

    private static func tickCursor(settings: MirrorSettingsBox) {
        guard let sink = settings.cursorSink else { return }
        // Compute cursor position fractions the same way captureFrame does
        // — live read from `NSEvent.mouseLocation`, top-left origin, 0–1.
        let displayID = CGMainDisplayID()
        let frameRect = CGDisplayBounds(displayID)
        guard frameRect.width > 0, frameRect.height > 0 else { return }
        let pt = NSEvent.mouseLocation
        let cx = max(0, min(pt.x / frameRect.width, 1))
        let flippedY = frameRect.height - pt.y
        let cy = max(0, min(flippedY / frameRect.height, 1))
        sink(.init(cursorX: Double(cx), cursorY: Double(cy)))
    }

    /// Grab one frame off the main display, downscale, JPEG-encode, and emit. Runs on
    /// the timer's background queue — `onFrame` callback hops to MainActor itself if
    /// it needs to.
    private nonisolated func captureFrame(settings: MirrorSettingsBox) {
        // Drop this tick if a previous frame is still in flight on the wire — otherwise
        // a slow encode/send (3-4MB base64 JPEGs at high quality saturate the pipe at
        // 15fps) piles up and the iOS user sees a stale "frozen" frame while the queue
        // drains. Always-fresh > always-complete for screen mirror.
        guard settings.tryBeginFrame() else { return }
        defer { settings.endFrame() }

        // `NSScreen.main` is `@MainActor`-isolated on modern SDKs; reading it here
        // would crash the same way the old `MainActor.assumeIsolated` block did.
        // `CGMainDisplayID()` + `CGDisplayBounds` give us the same rect from a
        // background queue, no actor hop required.
        let displayID = CGMainDisplayID()
        let frameRect = CGDisplayBounds(displayID)
        guard frameRect.width > 0, frameRect.height > 0 else { return }
        // Switched from `CGDisplayCreateImage(displayID)` to
        // `CGWindowListCreateImage(...)`. The former returned the SAME stale frame
        // repeatedly on macOS 14/15 in several TCC permission states (or returned
        // nil silently), which is why iOS saw a frozen image and the user reported
        // "stuck, not showing a good live image". The reference project (DNP
        // Remote Vibe Coding) uses the window-list variant and it streams cleanly
        // — same API surface here, with `.bestResolution` for crisp pixels.
        // The OS-rendered cursor still isn't reliably composited into the
        // capture, so we keep drawing the virtual cursor on iOS using the
        // `cursorX`/`cursorY` fractions we ship alongside each frame.
        guard let image = CGWindowListCreateImage(
            frameRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else {
            print("[DNP][ScreenMirror] CGWindowListCreateImage returned nil — Screen Recording permission missing? System Settings → Privacy & Security → Screen Recording.")
            return
        }

        // Cursor position in display POINTS, top-left origin. NSEvent.mouseLocation
        // is bottom-left, so we flip Y. This call is thread-safe — it just reads
        // the current event-system cursor position.
        let cursorPoint = NSEvent.mouseLocation
        let cursorXFraction = max(0, min(cursorPoint.x / frameRect.width, 1))
        // Flip Y: AppKit puts origin at bottom-left; iOS frame uses top-left.
        let flippedY = frameRect.height - cursorPoint.y
        let cursorYFraction = max(0, min(flippedY / frameRect.height, 1))

        let pxW = image.width
        let pxH = image.height
        let longEdge = max(pxW, pxH)
        let targetLong = settings.currentMaxLongEdge()
        let scale: CGFloat = longEdge > targetLong
            ? CGFloat(targetLong) / CGFloat(longEdge)
            : 1.0
        let scaledW = Int(CGFloat(pxW) * scale)
        let scaledH = Int(CGFloat(pxH) * scale)

        // Downscale via CGContext if needed.
        let scaledImage: CGImage = {
            if scale == 1.0 { return image }
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
            guard let ctx = CGContext(
                data: nil, width: scaledW, height: scaledH,
                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return image }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: scaledW, height: scaledH))
            return ctx.makeImage() ?? image
        }()

        // JPEG-encode at quality 0.42 — dropped from 0.55 to halve the
        // typical payload size and unlock smoother streaming. The signed
        // BridgeEnvelope adds CPU + base64 + JSON overhead per frame, so
        // a ~25–35% smaller JPEG translates roughly 1:1 into faster
        // delivery and less queueing in the WebSocket. Cursor smoothness
        // is now decoupled from this stream (separate 30Hz channel), so
        // a bit of compression noise on the bitmap doesn't affect pointer
        // feel at all.
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.42]
        CGImageDestinationAddImage(dest, scaledImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        let base64 = (data as Data).base64EncodedString()
        let payload = ScreenMirrorFramePayload(
            jpegBase64: base64,
            pixelWidth: scaledW, pixelHeight: scaledH,
            displayPointWidth: Int(frameRect.width),
            displayPointHeight: Int(frameRect.height),
            capturedAt: Date(),
            cursorX: cursorXFraction,
            cursorY: cursorYFraction
        )
        // The previous form `Task { @MainActor in self.onFrame?(payload) }` forced
        // every frame through the main thread, which serialized JSON encoding +
        // Ed25519 signing on the same actor that drives view updates. Result: at
        // any quality above "low", the iOS image went stale and the IDE UI got
        // sluggish. We hop directly off the timer queue to the bridge — the
        // dispatcher's setup code captures a background-safe sender closure into
        // `nonisolatedFrameSink` so this path never touches MainActor.
        if let sink = settings.frameSink {
            sink(payload)
        } else {
            Task { @MainActor in self.onFrame?(payload) }
        }
    }

    private func prefBool(_ key: String, default def: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return def }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// Tiny lock-guarded box for the one piece of state the timer's nonisolated capture
/// closure needs to read each frame. `final class` + lock is `Sendable`-safe and lets
/// us update the value from MainActor without dragging actor isolation into the timer
/// queue. The original code reached into MainActor via `assumeIsolated`, which is the
/// expression that tripped `EXC_BREAKPOINT (subcode=0x101803...)` whenever the timer
/// fired — `assumeIsolated` is a runtime assertion, NOT a hop, and it was wrong.
final class MirrorSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var maxLongEdge: Int = 1280
    private var frameInFlight = false
    /// Background-safe frame sink installed by `BridgeDispatcher` at stream-start
    /// time. When present, captureFrame routes every frame through here and skips
    /// the MainActor hop entirely — that hop was serialising JSON encoding +
    /// Ed25519 signing on the same actor that drives the IDE UI, which is what
    /// made the iOS preview "freeze" and the Mac feel laggy under mirror load.
    private var _frameSink: (@Sendable (ScreenMirrorFramePayload) -> Void)?
    /// Same idea but for the high-frequency cursor stream — 30Hz position
    /// updates that decouple cursor smoothness from frame cadence.
    private var _cursorSink: (@Sendable (ScreenMirrorCursorPayload) -> Void)?

    func setMaxLongEdge(_ v: Int) {
        lock.lock(); defer { lock.unlock() }
        maxLongEdge = v
    }

    func currentMaxLongEdge() -> Int {
        lock.lock(); defer { lock.unlock() }
        return maxLongEdge
    }

    var frameSink: (@Sendable (ScreenMirrorFramePayload) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _frameSink }
        set { lock.lock(); defer { lock.unlock() }; _frameSink = newValue }
    }

    var cursorSink: (@Sendable (ScreenMirrorCursorPayload) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _cursorSink }
        set { lock.lock(); defer { lock.unlock() }; _cursorSink = newValue }
    }

    /// Returns true if no frame is currently being encoded/sent — caller should
    /// pair with `endFrame()` in a defer block. Used to drop ticks that would
    /// otherwise pile up behind a slow send.
    func tryBeginFrame() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if frameInFlight { return false }
        frameInFlight = true
        return true
    }

    func endFrame() {
        lock.lock(); defer { lock.unlock() }
        frameInFlight = false
    }
}
