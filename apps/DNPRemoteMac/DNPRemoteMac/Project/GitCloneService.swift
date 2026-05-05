import Foundation

/// Runs `git clone <url> <destination>` and streams progress/errors. Used by the Welcome
/// scene's "Clone from Git" entry. We deliberately spawn `git` directly (NOT `gh repo
/// clone`) so the user can paste any URL — github.com, gitlab.com, self-hosted, ssh://,
/// etc. — without depending on `gh` being signed in for a non-GitHub remote.
///
/// Returns success/failure + the destination URL (which the caller passes to
/// `MacAppViewModel.openProject(at:)` to open the IDE on the freshly-cloned tree).
enum GitCloneService {

    struct Result {
        let success: Bool
        let destination: URL
        /// stderr/stdout combined — surfaced to the user verbatim on failure so a
        /// "fatal: repository not found" or "Permission denied (publickey)" reads as the
        /// real error instead of a generic "clone failed".
        let log: String
    }

    /// Clone `url` into `parentDirectory`. The repo name is derived from the URL's last
    /// component (stripping `.git`) and used as the leaf folder. If the leaf already
    /// exists this errors out — `git clone` won't write into a non-empty directory.
    static func clone(url: String, into parentDirectory: URL) async -> Result {
        let leaf = repoNameFromURL(url)
        let destination = parentDirectory.appendingPathComponent(leaf, isDirectory: true)

        // Make sure the parent exists. `git` creates the leaf itself.
        try? FileManager.default.createDirectory(at: parentDirectory,
                                                  withIntermediateDirectories: true)

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                // Use the user's login `PATH` — Homebrew git, Xcode CLT git, /usr/bin/git
                // are all reachable from a login shell. Without this, sandboxed
                // `Process.run` falls back to a sparse PATH that may not include git.
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                process.launchPath = shell
                process.arguments = [
                    "-l", "-c",
                    "git clone --progress \(Self.shellQuote(url)) \(Self.shellQuote(destination.path)) 2>&1"
                ]
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    cont.resume(returning: Result(
                        success: false,
                        destination: destination,
                        log: "Failed to launch git: \(error.localizedDescription)"
                    ))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let log = String(data: data, encoding: .utf8) ?? ""
                let ok = process.terminationStatus == 0
                cont.resume(returning: Result(success: ok, destination: destination, log: log))
            }
        }
    }

    /// Best-effort URL → leaf-folder mapping. Examples:
    ///   - https://github.com/owner/repo.git → "repo"
    ///   - git@github.com:owner/repo.git     → "repo"
    ///   - /local/path/to/repo               → "repo"
    static func repoNameFromURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let lastSeparator = s.lastIndex(where: { $0 == "/" || $0 == ":" }) ?? s.startIndex
        let after = s.index(after: lastSeparator)
        let leaf = String(s[after...])
        return leaf.isEmpty ? "repo" : leaf
    }

    private static func shellQuote(_ s: String) -> String {
        if s.range(of: #"[^A-Za-z0-9_/.\-:@]"#, options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
