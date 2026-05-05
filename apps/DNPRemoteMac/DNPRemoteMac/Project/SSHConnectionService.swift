import Foundation

/// Lightweight SSH connection helper for the Welcome scene's "Connect to SSH" entry.
///
/// Scope: this is **not** a Cursor-style remote-workspace integration (which would need a
/// remote agent + SFTP file browsing + remote process orchestration). Instead it delivers
/// the practical 80% case for our app: save the connection details as a recent project,
/// and when re-opened spawn a Terminal session that automatically `ssh`'s into the host
/// using the saved identity file. The user lands in the remote shell, can run Claude
/// there, and the rest of the IDE (file browser, etc.) operates locally for now —
/// remote-workspace mode is a follow-up.
enum SSHConnectionService {

    struct Connection: Hashable, Sendable {
        var host: String
        var user: String
        var port: Int
        var identityFile: String?    // optional path to ~/.ssh/<key>; nil → use default
        var remotePath: String       // working directory on the remote, e.g. "/home/me/proj"
        var displayName: String      // user-facing label (defaults to "<user>@<host>")
    }

    /// Reachability probe — runs `ssh -o BatchMode=yes -o ConnectTimeout=5 user@host echo ok`.
    /// `BatchMode=yes` disables interactive prompts so a missing key fails immediately
    /// instead of hanging waiting for a password. Returns `(ok, log)` so the caller can
    /// surface "Permission denied" / "Could not resolve hostname" verbatim.
    static func probe(_ c: Connection) async -> (ok: Bool, log: String) {
        return await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                process.launchPath = shell
                process.arguments = [
                    "-l", "-c",
                    Self.sshCommand(c, remoteCommand: "echo ok",
                                    extraOptions: ["BatchMode=yes", "ConnectTimeout=5"])
                ]
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    cont.resume(returning: (false, "Failed to launch ssh: \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let log = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: (process.terminationStatus == 0, log))
            }
        }
    }

    /// Build the `ssh` command line the Welcome scene + recents use to launch into the
    /// remote shell. Includes identity-file flag only when set, port flag only when not
    /// the default 22, and a final `cd <remotePath>` chained with the user's login shell
    /// so the user lands in the right directory ready to run Claude.
    static func interactiveCommand(_ c: Connection) -> String {
        let cd = c.remotePath.isEmpty ? "" : "cd \(shellQuote(c.remotePath)) && "
        return sshCommand(c, remoteCommand: "\(cd)exec $SHELL -l", extraOptions: [])
    }

    static func sshCommand(_ c: Connection, remoteCommand: String,
                            extraOptions: [String]) -> String {
        var parts: [String] = ["ssh", "-tt"]
        for opt in extraOptions {
            parts.append("-o")
            parts.append(opt)
        }
        if c.port != 22 {
            parts.append("-p")
            parts.append(String(c.port))
        }
        if let identity = c.identityFile, !identity.isEmpty {
            parts.append("-i")
            parts.append(shellQuote(identity))
        }
        parts.append("\(c.user)@\(c.host)")
        parts.append(shellQuote(remoteCommand))
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.range(of: #"[^A-Za-z0-9_/.\-:@]"#, options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
