import Foundation

/// Snapshot of a GitHub-backed project — populated by `MacAppViewModel.openProject(at:)`
/// when the chosen folder is a Git working directory whose `origin` remote points at
/// `github.com`. Drives the GitHub badge + branch chip in the file-explorer header and the
/// workspace toolbar; nil for non-GitHub projects.
struct GitHubProjectInfo: Equatable {
    /// `owner/repo` form — the canonical GitHub identifier.
    let nameWithOwner: String
    /// `https://github.com/<owner>/<repo>` — built from the origin URL for "Open on
    /// github.com" links.
    let webURL: URL?
    /// Branch the working tree currently has checked out. Refreshed each time we open the
    /// project; the file-explorer header re-reads it via `currentBranch(at:)` whenever the
    /// user clicks the chip (cheap shell-out).
    let currentBranch: String?

    /// Inspect `<url>/.git/config` for an `[remote "origin"]` block whose URL contains
    /// `github.com`. If found, extracts owner/repo and (best-effort) reads the current
    /// branch via `git symbolic-ref --short HEAD`. Returns nil for non-GitHub projects.
    static func detect(at url: URL) -> GitHubProjectInfo? {
        let configPath = url.appendingPathComponent(".git/config")
        guard let raw = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }

        // Find any remote whose URL contains github.com.
        // Format we accept (matches both HTTPS and SSH origins):
        //     url = https://github.com/owner/repo.git
        //     url = git@github.com:owner/repo.git
        let pattern = #"url\s*=\s*(?:https://github\.com/|git@github\.com:)([^\s/]+)/([^\s\.]+)(?:\.git)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges >= 3,
              let ownerRange = Range(match.range(at: 1), in: raw),
              let repoRange = Range(match.range(at: 2), in: raw)
        else { return nil }

        let owner = String(raw[ownerRange])
        let repo = String(raw[repoRange]).replacingOccurrences(of: ".git", with: "")
        let nwo = "\(owner)/\(repo)"
        let web = URL(string: "https://github.com/\(nwo)")
        return GitHubProjectInfo(nameWithOwner: nwo,
                                 webURL: web,
                                 currentBranch: currentBranch(at: url))
    }

    /// Cheap synchronous shell-out to `git symbolic-ref --short HEAD`. Returns nil if not on
    /// a branch (e.g. detached HEAD) or the binary isn't on PATH.
    static func currentBranch(at url: URL) -> String? {
        let task = Process()
        task.currentDirectoryURL = url
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "symbolic-ref", "--short", "HEAD"]
        // Same SIGABRT-mitigation pattern as `localBranches(at:)` — hold strong refs to
        // both pipes for the function's lifetime (the previous form created them on a
        // single inline line which kept them alive *here* but the `readDataToEndOfFile`
        // after `waitUntilExit` could still crash if any teardown raced), and read via
        // `try? readToEnd()` (throws-or-nil) instead of the crashing `readDataToEndOfFile`.
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        do { try task.run() } catch { return nil }
        // Read BEFORE waitUntilExit — EOF arrives when the child closes its stdout end
        // (right at exit), so this captures the full branch name and lets us avoid the
        // "pipe deallocated before second-pass read" race.
        let data = (try? outHandle.readToEnd()) ?? Data()
        task.waitUntilExit()
        // Drain stderr too so a verbose git error doesn't fill the buffer and stall exit.
        _ = try? errHandle.readToEnd()
        guard task.terminationStatus == 0 else { return nil }
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    /// List all local branches via `git branch --format=%(refname:short)`. Used by the
    /// branch picker in the workspace toolbar.
    static func localBranches(at url: URL) -> [String] {
        let task = Process()
        task.currentDirectoryURL = url
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "branch", "--format=%(refname:short)"]
        // Hold STRONG references to both pipes for the entire function so neither gets
        // ARC-released while the child is writing — the previous form created the
        // stderr pipe inline (`task.standardError = Pipe()`) without a local; under
        // some scheduling races the Pipe was deallocated mid-run and reading from `out`
        // tripped EXC_BAD_ACCESS on `readDataToEndOfFile()` (the crash the user hit).
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let outHandle = out.fileHandleForReading
        do {
            try task.run()
        } catch {
            return []
        }
        // Read FIRST, then wait. Reading EOF blocks until the child closes its
        // stdout end of the pipe, which it does on exit — so we don't miss output AND
        // we capture it while `out` is guaranteed still alive. Wrap in `try?` so a
        // pipe-closed-early condition returns empty instead of crashing.
        let data = (try? outHandle.readToEnd()) ?? Data()
        task.waitUntilExit()
        // Drain stderr too (otherwise a verbose git error could fill the pipe buffer
        // and block the child's exit); discard the bytes — we just want the pipe drained.
        _ = try? err.fileHandleForReading.readToEnd()
        guard task.terminationStatus == 0 else { return [] }
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Switch the working tree to a different branch via `git checkout <branch>`. Returns
    /// `(success, stderr)` so the caller can surface errors (dirty working tree, no such
    /// branch, etc.) without us having to model them.
    static func checkout(branch: String, at url: URL) -> (success: Bool, error: String?) {
        let task = Process()
        task.currentDirectoryURL = url
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "checkout", branch]
        // Same Pipe-lifetime pattern as the other shell-outs — both pipes held in
        // locals so neither gets ARC-released mid-run, and reads use `try? readToEnd()`
        // instead of the crashing `readDataToEndOfFile()`.
        let err = Pipe()
        let out = Pipe()
        task.standardError = err
        task.standardOutput = out
        let errHandle = err.fileHandleForReading
        let outHandle = out.fileHandleForReading
        do { try task.run() } catch {
            return (false, error.localizedDescription)
        }
        // Drain stderr while child is alive (in case of a verbose error we want it all,
        // and reading-before-wait avoids the post-exit race).
        let errData = (try? errHandle.readToEnd()) ?? Data()
        _ = try? outHandle.readToEnd()
        task.waitUntilExit()
        if task.terminationStatus == 0 { return (true, nil) }
        return (false, String(data: errData, encoding: .utf8))
    }
}
