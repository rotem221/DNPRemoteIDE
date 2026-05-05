import Foundation

/// Detects and launches the Claude Code CLI inside a `PTYRuntimeService`.
/// Never uses `--dangerously-skip-permissions` by default. Does not call private remote-control APIs.
final class ClaudeSessionService: ObservableObject, @unchecked Sendable {

    @Published private(set) var detectedPath: String?
    @Published private(set) var detectedVersion: String?

    init() {
        detectedPath = Self.locateClaudeBinary()
        detectedVersion = detectedPath.flatMap { Self.probeVersion(at: $0) }
    }

    /// Build a launch command — flags that the public Claude Code CLI documents.
    /// Caller passes the result to `PTYRuntimeService.spawn`.
    func launchCommand(
        projectPath: String,
        appendSystemPromptFile: String? = nil,
        allowedTools: [String]? = nil,
        verbose: Bool = false,
        resumeSessionId: String? = nil
    ) -> (command: String, args: [String])? {
        guard let path = detectedPath else { return nil }
        var args: [String] = []
        if let resume = resumeSessionId { args += ["--resume", resume] }
        if verbose { args.append("--verbose") }
        if let prompt = appendSystemPromptFile { args += ["--append-system-prompt", "@\(prompt)"] }
        if let tools = allowedTools, !tools.isEmpty { args += ["--allowed-tools", tools.joined(separator: ",")] }
        // Project root is set via the child's CWD by the caller.
        return (path, args)
    }

    // MARK: - Detection

    static func locateClaudeBinary() -> String? {
        // Collect every executable claude binary we can find — `which`, common system prefixes,
        // npm-global (the recommended user-level npm install path), and the user's `~/.claude`
        // local install. Then pick the one with the HIGHEST version. Stopping at the first hit
        // (the previous behaviour) silently locked us to an outdated 2.0.x in `/usr/local/bin`
        // even when a 2.1+ was installed under `~/.npm-global/bin`.
        let home = NSHomeDirectory()
        var paths: [String] = []
        if let p = which("claude") { paths.append(p) }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude"
        ])
        // Probe every executable, resolve symlinks (npm wrappers are usually links into the
        // same `lib/node_modules/...` install — dedupe by realpath), and rank by semver.
        var seen = Set<String>()
        var best: (path: String, version: [Int])? = nil
        for raw in paths where FileManager.default.isExecutableFile(atPath: raw) {
            let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
            if !seen.insert(resolved).inserted { continue }
            guard let v = probeVersion(at: raw) else { continue }
            let parsed = parseSemver(from: v)
            if best == nil || semverGreater(parsed, best!.version) { best = (raw, parsed) }
        }
        return best?.path
    }

    private static func semverGreater(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    static func probeVersion(at path: String) -> String? {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract `[major, minor, patch]` from a `claude --version` line like
    /// `"2.1.123 (Claude Code)"`. Returns zeros for missing components.
    private static func parseSemver(from text: String) -> [Int] {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \t\n\r()CcLlAaUuDdEeOo")
        var parts: [Int] = []
        while !scanner.isAtEnd, parts.count < 3 {
            if let n = scanner.scanInt() { parts.append(n); _ = scanner.scanString(".") }
            else { _ = scanner.scanCharacter() }
        }
        while parts.count < 3 { parts.append(0) }
        return parts
    }

    private static func which(_ binary: String) -> String? {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [binary]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }
}
