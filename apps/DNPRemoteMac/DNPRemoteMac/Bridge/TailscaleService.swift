import Foundation

/// Detects a running Tailscale daemon on the Mac and reads its assigned tailnet IPv4 +
/// hostname. The iOS client receives these in `ProjectInfoPayload` and prefers them as the
/// bridge endpoint when the Mac isn't reachable on the LAN — meaning a paired iPhone can
/// reach the Mac from anywhere both devices are signed into the same tailnet.
///
/// We deliberately don't manage Tailscale itself — both sides assume the user has Tailscale
/// up. We just snapshot the daemon's status via the public `tailscale` CLI.
struct TailscaleService {

    /// Standard install paths the Tailscale macOS app drops the CLI binary into. Falls back to
    /// `which tailscale` for users who put it on PATH manually.
    private static let candidateBinaries: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale"
    ]

    /// Result returned to the bridge so it can advertise the tailnet endpoint to iOS.
    struct Status {
        let ipv4: String?
        let hostname: String?
    }

    /// Synchronously query the Tailscale daemon. Returns `Status(nil, nil)` if Tailscale isn't
    /// running or installed — failure is silent so the bridge keeps working on plain LAN.
    ///
    /// **Validation gate**. The Tailscale CLI on macOS occasionally prints diagnostic
    /// strings on stdout instead of returning a non-zero exit code (most commonly the
    /// `"The Tailscale GUI failed to start: …"` output emitted when `tailscaled` isn't
    /// running but the CLI binary still exists). Without validation, that string used to
    /// flow straight through as `ipv4`, get embedded into the `tailscaleFallbackEndpoint`
    /// URL (`tcp://The Tailscale GUI failed to start: …:18733`), and surface on the
    /// paired iPhone as a `Bad endpoint URL` connection error. We now refuse to pass
    /// anything that doesn't structurally look like an IPv4 / hostname so a misbehaving
    /// CLI can't poison the bridge handshake.
    static func currentStatus() -> Status {
        guard let tailscale = locateBinary() else { return Status(ipv4: nil, hostname: nil) }
        let rawIPv4 = run(tailscale, args: ["ip", "-4"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)
        let ipv4 = rawIPv4.flatMap { isPlausibleIPv4($0) ? $0 : nil }
        let hostnameFull = run(tailscale, args: ["status", "--self", "--json"]) ?? ""
        let hostname = parseHostname(fromStatusJSON: hostnameFull)
            .flatMap { isPlausibleHostname($0) ? $0 : nil }
        return Status(ipv4: ipv4, hostname: hostname)
    }

    /// Cheap sanity check — IPv4 must be 4 dotted decimal octets, each 0–255, no
    /// surrounding whitespace, no embedded letters. Anything else (the GUI launch
    /// error, an empty string, a stray prompt) gets dropped by the caller so the
    /// fallback endpoint stays nil rather than a malformed URL.
    private static func isPlausibleIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part), (0...255).contains(n) else { return false }
        }
        return true
    }

    /// Hostname check — Tailscale hostnames are DNS labels (letters, digits, hyphens,
    /// dots). We reject any string with whitespace or characters that would break a
    /// `tcp://<host>:<port>` URL on the iOS side.
    private static func isPlausibleHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 253 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func locateBinary() -> String? {
        for path in candidateBinaries where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: `which tailscale` so users with custom PATH still work.
        guard let p = run("/usr/bin/which", args: ["tailscale"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty
        else { return nil }
        return p
    }

    /// Run a command synchronously, capture stdout. Returns nil on launch failure or non-zero
    /// exit. Tailscale CLI is fast (<100 ms) so blocking the caller briefly is fine.
    ///
    /// Important pipe-handling rules — both fixed here after a hang report:
    ///   1. **Drain stdout in parallel with `waitUntilExit`.** The previous code
    ///      called `readDataToEndOfFile` AFTER `waitUntilExit()`, which deadlocks
    ///      whenever the child writes more than the kernel's pipe buffer (~16 KB
    ///      on macOS): the child blocks on write, `waitUntilExit` blocks waiting
    ///      for the child, the read never starts. Reading on a background queue
    ///      while the child runs guarantees forward progress.
    ///   2. **Discard stderr to /dev/null instead of an unread `Pipe()`.** An
    ///      unread Pipe was the more common deadlock — `tailscale` writes
    ///      progress / error chatter to stderr, which fills the pipe buffer
    ///      because no one ever reads it, and the child stalls on the next
    ///      stderr write. `FileHandle.nullDevice` makes the kernel discard
    ///      stderr writes outright, so the child never blocks on stderr.
    private static func run(_ executable: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        // Concurrent stdout drain — fills a Data buffer without blocking the
        // child's write side.
        var collected = Data()
        let drainQueue = DispatchQueue(label: "dnp.tailscale.drain", qos: .utility)
        let semaphore = DispatchSemaphore(value: 0)
        drainQueue.async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            semaphore.signal()
        }
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        // Wait for the drain to finish (it'll exit when the pipe's write end
        // closes — which the kernel does when the child terminates).
        _ = semaphore.wait(timeout: .now() + .seconds(2))
        guard task.terminationStatus == 0 else { return nil }
        return String(data: collected, encoding: .utf8)
    }

    /// Pull `Self.HostName` out of `tailscale status --self --json`. The JSON shape is
    /// stable (documented in `tailscale-status(8)`), but we parse defensively.
    private static func parseHostname(fromStatusJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfPeer = obj["Self"] as? [String: Any]
        else { return nil }
        if let name = selfPeer["DNSName"] as? String, !name.isEmpty {
            // DNSName is `host.tailnet.ts.net.` — trim trailing dot, fall back to first label.
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        if let host = selfPeer["HostName"] as? String, !host.isEmpty { return host }
        return nil
    }
}
