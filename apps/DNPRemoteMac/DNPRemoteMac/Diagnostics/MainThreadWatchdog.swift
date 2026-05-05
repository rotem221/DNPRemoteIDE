import Foundation
import AppKit

/// Detects when the Mac IDE's main thread is unresponsive — the failure mode the user
/// described as "the IDE is in fact stuck while iOS still shows it as connected".
///
/// **Mechanism:** a background dispatch queue posts a no-op block to `DispatchQueue.main`
/// every second. The block stamps a "last main ack" timestamp on the watchdog's own queue.
/// If the main thread is busy (long synchronous file I/O, runaway SwiftUI render loop,
/// blocked Swift Task, hung PTY callback), the queued block can't run and the
/// last-ack age balloons.
///
/// At a 5-second stall threshold the watchdog:
/// 1. Writes a diagnostic line to `memory/crashes/watchdog.log` (survives reboots so we
///    can see it after a hang).
/// 2. On recovery (when the main thread starts processing blocks again), fires a
///    `MacNotificationService` banner — telling the user "the IDE was unresponsive for
///    Ns" so a silent hang is visible in retrospect even after it self-resolves.
///
/// This complements the iOS-side staleness detection: iOS surfaces the *symptom* (stale
/// connection) within seconds; the Mac watchdog identifies the *cause* (main thread
/// blocked) and the duration so we can correlate hangs with later debugging.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "dnp.mac.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastMainAck: Date = .distantPast
    private var stalled: Bool = false
    private var stallStartedAt: Date?

    /// Stalls shorter than this are background noise (transient SwiftUI render bursts,
    /// brief disk syncs). 5 seconds is the threshold used by the macOS spindump system
    /// daemon and matches what users perceive as "frozen".
    private let stallThreshold: TimeInterval = 5

    /// File where stalls are recorded — append-only, line-per-event so it can be tailed.
    private(set) lazy var logURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DNPRemoteMac/memory/crashes",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watchdog.log")
    }()

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.lastMainAck = Date()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    private func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMainAck)

        // Edge into stall: log once at the moment we cross the threshold.
        if !stalled, elapsed > stallThreshold {
            stalled = true
            stallStartedAt = lastMainAck
            append(line: "stalled at=\(now.iso8601) elapsed=\(Int(elapsed))s")
        }

        // Post a probe block. If main is wedged, the closure stays queued and our
        // `lastMainAck` doesn't advance. If main is healthy, it's processed in <16ms and
        // the recovery branch below runs.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async {
                let ackedAt = Date()
                let priorAck = self.lastMainAck
                self.lastMainAck = ackedAt

                if self.stalled {
                    self.stalled = false
                    let stallSeconds = ackedAt.timeIntervalSince(self.stallStartedAt ?? priorAck)
                    self.stallStartedAt = nil
                    self.append(line: "recovered at=\(ackedAt.iso8601) stalled_for=\(Int(stallSeconds))s")
                    // Surface to the user — they often miss the symptom in real time
                    // because they're looking at iOS. A "recovered after Ns" banner makes
                    // the post-mortem obvious without checking logs.
                    DispatchQueue.main.async {
                        MacNotificationService.shared.fireMainThreadStallRecovered(
                            durationSeconds: stallSeconds
                        )
                    }
                }
            }
        }
    }

    private func append(line: String) {
        let stamped = "[\(Date().iso8601)] \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? data.write(to: logURL)
            return
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        }
    }
}

private extension Date {
    var iso8601: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: self)
    }
}
