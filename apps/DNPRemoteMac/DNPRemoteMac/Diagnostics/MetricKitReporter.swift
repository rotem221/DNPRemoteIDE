import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// MetricKit diagnostic-payload subscriber. Apple delivers
/// `MXDiagnosticPayload`s once per day with crash logs, hangs, CPU /
/// disk-write exception reports — all collected automatically by the
/// system, with no per-app instrumentation. We persist a pretty-
/// printed JSON snapshot of each payload alongside the in-process
/// `CrashReporter` output so support flows have one folder to grab.
///
/// Pairs with `CrashReporter`:
/// - **CrashReporter** captures live, in-process: signals, uncaught
///   exceptions, recoverable PTY/Claude exits. Fast, lossy, narrow.
/// - **MetricKitReporter** captures system-collected, post-mortem:
///   real crash backtraces, hang reports, disk-write exceptions.
///   Latent (24h delay), reliable, broad.
///
/// Together they give a complete picture without a third-party SDK.
@MainActor
final class MetricKitReporter: NSObject {

    static let shared = MetricKitReporter()

    private(set) var diagnosticsDir: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DNPRemoteMac/memory/crashes/metrickit",
                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var installed = false

    /// Subscribe the shared instance to `MXMetricManager`. Idempotent
    /// so calling it on every `applicationDidFinishLaunching` is safe.
    func install() {
        guard !installed else { return }
        installed = true
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }
}

#if canImport(MetricKit)
extension MetricKitReporter: MXMetricManagerSubscriber {

    /// Daily metrics — performance percentiles, launch durations,
    /// memory, etc. Persisted as JSON for future trend analysis.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        Task { @MainActor in
            for payload in payloads {
                self.write(payload.jsonRepresentation(),
                           prefix: "metrics")
            }
        }
    }

    /// Crash + hang + CPU/disk exception reports. The most valuable
    /// payload — full crash backtrace + binary image list, which we
    /// don't have anywhere else without a third-party crash service.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in
            for payload in payloads {
                self.write(payload.jsonRepresentation(),
                           prefix: "diagnostic")
            }
        }
    }

    private func write(_ data: Data, prefix: String) {
        let stamp = ISO8601DateFormatter.dnpShared.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = diagnosticsDir.appendingPathComponent("\(stamp)-\(prefix).json")
        try? data.write(to: url)
    }
}
#endif
