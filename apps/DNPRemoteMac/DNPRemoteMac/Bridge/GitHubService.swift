import Foundation

/// Detects whether the user has the `gh` CLI installed and is signed into GitHub. Surfaced in
/// the Mac status bar (so the user can tell at a glance whether Claude's `Bash gh ...` calls
/// will succeed) and used as the data source for the GitHub management panel.
///
/// We deliberately don't run `gh auth login` from inside the app — that flow has to launch
/// a browser tab and accept a device-flow code, which is awkward to wrap. Instead we offer a
/// "Sign in via Terminal" button that runs `gh auth login --web` in a new Terminal window.
struct GitHubService {

    private static let candidateBinaries: [String] = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]

    struct Status {
        /// `gh` CLI binary location, if installed.
        let ghPath: String?
        /// `true` if `gh auth status` succeeded — the user is signed in.
        let signedIn: Bool
        /// Logged-in account name (e.g., `octocat`). Nil when signed out.
        let user: String?
        /// The hostname the user is signed into (`github.com` for the public service).
        let host: String?
        /// Comma-joined list of OAuth scopes granted to the current token.
        let scopes: String?

        var isInstalled: Bool { ghPath != nil }
    }

    /// Snapshot the current GitHub auth state. Synchronous — `gh auth status` returns in
    /// well under 100 ms even when offline. Status bar polls this every 8 s.
    static func currentStatus() -> Status {
        guard let gh = locateBinary() else {
            return Status(ghPath: nil, signedIn: false, user: nil, host: nil, scopes: nil)
        }
        // `gh auth status` writes its human output to STDERR and exits 0 when signed in,
        // 1 when signed out. We capture both streams.
        let (out, err, code) = run(gh, args: ["auth", "status"])
        let combined = (err.isEmpty ? out : err)
        if code != 0 {
            return Status(ghPath: gh, signedIn: false, user: nil, host: nil, scopes: nil)
        }
        return parseAuthStatus(text: combined, ghPath: gh)
    }

    /// Run an arbitrary `gh` subcommand. Returns the captured stdout + stderr. Used by the
    /// management panel for `gh repo list`, `gh pr list`, etc. without re-locating the binary.
    static func runCommand(_ args: [String]) -> (stdout: String, stderr: String, exit: Int32)? {
        guard let gh = locateBinary() else { return nil }
        return run(gh, args: args)
    }

    // MARK: - Private

    private static func locateBinary() -> String? {
        for path in candidateBinaries where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // PATH fallback for users with a custom install location.
        let (out, _, code) = run("/usr/bin/which", args: ["gh"])
        guard code == 0,
              let line = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first
        else { return nil }
        return String(line)
    }

    private static func run(_ executable: String, args: [String]) -> (stdout: String, stderr: String, exit: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        // Drain BOTH pipes on background queues while the child runs. Reading
        // pipes only AFTER `waitUntilExit()` (the previous behaviour) deadlocks
        // any child that writes more than the kernel pipe buffer (~16 KB on
        // macOS) — `gh` does this routinely with verbose error output and the
        // user reported a freeze that traced back to the unread pipe stalling
        // the whole main thread. Concurrent drain → no buffer ever fills → no
        // hang.
        var outData = Data()
        var errData = Data()
        let queue = DispatchQueue(label: "dnp.gh.drain", qos: .utility, attributes: .concurrent)
        let group = DispatchGroup()
        group.enter()
        queue.async {
            while true {
                let chunk = outPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                outData.append(chunk)
            }
            group.leave()
        }
        group.enter()
        queue.async {
            while true {
                let chunk = errPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                errData.append(chunk)
            }
            group.leave()
        }
        do { try task.run() } catch {
            return ("", "\(error.localizedDescription)", -1)
        }
        task.waitUntilExit()
        // Pipes close their write end when the child exits, which terminates
        // the drain loops. Wait briefly so reads complete; cap at 2s so a
        // misbehaving child can't wedge the caller forever.
        _ = group.wait(timeout: .now() + .seconds(2))
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                task.terminationStatus)
    }

    /// Parse the `gh auth status` human output. Format (as of gh 2.x) looks like:
    ///   github.com
    ///     ✓ Logged in to github.com as octocat (oauth_token)
    ///     ✓ Token: gho_********************
    ///     ✓ Token scopes: 'gist', 'read:org', 'repo', 'workflow'
    private static func parseAuthStatus(text: String, ghPath: String) -> Status {
        let signedIn = text.contains("Logged in to") || text.contains("✓")
        let user: String? = {
            // "Logged in to github.com as <name>" — pull the token after "as ".
            guard let range = text.range(of: "Logged in to .* as ", options: .regularExpression)
            else { return nil }
            let tail = text[range.upperBound...]
            // Take chars up to whitespace or "(".
            let chars = tail.prefix { !$0.isWhitespace && $0 != "(" }
            let s = String(chars)
            return s.isEmpty ? nil : s
        }()
        let host: String? = {
            guard let range = text.range(of: "Logged in to ([^ ]+)", options: .regularExpression)
            else { return "github.com" }
            let segment = String(text[range])
            return segment.replacingOccurrences(of: "Logged in to ", with: "")
        }()
        let scopes: String? = {
            guard let range = text.range(of: "Token scopes: .*", options: .regularExpression)
            else { return nil }
            let segment = String(text[range])
                .replacingOccurrences(of: "Token scopes: ", with: "")
                .replacingOccurrences(of: "'", with: "")
            return segment
        }()
        return Status(ghPath: ghPath, signedIn: signedIn, user: user,
                      host: host, scopes: scopes)
    }
}
