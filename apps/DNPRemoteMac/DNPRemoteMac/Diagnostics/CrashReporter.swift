import Foundation

/// Captures uncaught Swift exceptions and POSIX signals (SIGABRT/SIGSEGV/SIGBUS) and writes
/// `memory/crashes/<timestamp>.json`. Calls into the Mac app's crash sink when available.
final class CrashReporter: @unchecked Sendable {

    static let shared = CrashReporter()
    private var installed = false

    private(set) var crashesDir: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DNPRemoteMac/memory/crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func installSignalHandlers() {
        guard !installed else { return }
        installed = true
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signum in
                CrashReporter.shared.recordSignal(signum)
                // Re-raise so the system can produce a normal crash log.
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
        NSSetUncaughtExceptionHandler { ex in
            CrashReporter.shared.recordException(ex)
        }
    }

    /// Record a non-fatal recoverable crash (e.g. PTY died, Claude exited with non-zero).
    func recordRecoverable(kind: CrashKind, sessionId: UUID?, message: String, stack: String? = nil) {
        let report = CrashReport(sessionId: sessionId, kind: kind, message: message, stackTrace: stack)
        write(report)
    }

    private func recordSignal(_ sig: Int32) {
        let name = String(cString: strsignal(sig))
        let report = CrashReport(kind: .signalReceived, message: "Received signal \(sig) (\(name))", stackTrace: nil)
        write(report)
    }

    private func recordException(_ ex: NSException) {
        let stack = ex.callStackSymbols.joined(separator: "\n")
        let report = CrashReport(kind: .uncaughtSwiftException, message: ex.reason ?? ex.name.rawValue, stackTrace: stack)
        write(report)
    }

    private func write(_ report: CrashReport) {
        let stamp = ISO8601DateFormatter.dnpShared.string(from: report.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let url = crashesDir.appendingPathComponent("\(stamp)-\(report.id.uuidString).json")
        if let data = try? DNPCoders.encode(report) {
            try? data.write(to: url)
        }
    }
}
