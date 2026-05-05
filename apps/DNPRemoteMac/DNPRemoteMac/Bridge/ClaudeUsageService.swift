import Foundation

/// Fetches Claude Code's quota usage from `https://api.anthropic.com/api/oauth/usage`
/// and translates the response into our shared `AIUsageSnapshot`. Mirrors the
/// approach Muxy uses: read the user's existing Claude Code OAuth token (env var
/// → `~/.claude/.credentials.json` → macOS Keychain via `/usr/bin/security`),
/// hit the OAuth-beta endpoint with `Bearer <token>`, parse the per-window
/// `utilization` + `resets_at` fields. **No new credentials, no new auth flow,
/// no Anthropic API key.** If the user is signed into Claude Code at all, this
/// works.
@MainActor
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let providerName = "Claude Code"
    private let session: URLSession = .shared

    private init() {}

    /// Fetch a fresh snapshot. Always returns something — on failure the
    /// snapshot has `errorMessage` populated and an empty `windows` array, so
    /// the UI has a single shape to render.
    func fetchSnapshot() async -> AIUsageSnapshot {
        guard let token = readAccessToken() else {
            return AIUsageSnapshot(
                providerName: Self.providerName,
                fetchedAt: Date(),
                windows: [],
                errorMessage: "Sign in to Claude Code on this Mac to enable AI Usage."
            )
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Self.errorSnapshot("Unexpected response type")
            }
            switch http.statusCode {
            case 200:
                return parse(data: data)
            case 401, 403:
                return Self.errorSnapshot("Claude session expired — sign in again")
            default:
                return Self.errorSnapshot("Anthropic returned HTTP \(http.statusCode)")
            }
        } catch {
            return Self.errorSnapshot("Couldn't reach Anthropic: \(error.localizedDescription)")
        }
    }

    // MARK: - Token discovery

    /// Walk the same locations Muxy walks. Most users hit the credentials
    /// file; the env-var path is for headless / CI flows; the Keychain
    /// fallback uses `/usr/bin/security` (no entitlement required) for users
    /// whose Claude Code stores credentials there.
    private func readAccessToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !v.isEmpty {
            return v
        }
        let baseDir = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "\(NSHomeDirectory())/.claude"
        let credentialsPath = "\(baseDir)/.credentials.json"
        if FileManager.default.fileExists(atPath: credentialsPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: credentialsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        // Keychain fallback — shell out to `security` so we don't need a
        // keychain entitlement. The service name matches what Claude Code
        // writes when storing credentials there.
        let user = env["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let raw = readFromKeychain(service: "Claude Code-credentials", account: user),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    private func readFromKeychain(service: String, account: String) -> String? {
        var args = ["find-generic-password"]
        if !account.isEmpty { args += ["-a", account] }
        args += ["-s", service, "-w"]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do { try proc.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Parsing

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dateFormatterNoMS: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private struct WindowDef { let key: String; let label: String }
    private static let windowDefs: [WindowDef] = [
        .init(key: "five_hour",         label: "5h"),
        .init(key: "seven_day",         label: "7d"),
        .init(key: "seven_day_sonnet",  label: "7d Sonnet"),
        .init(key: "seven_day_omelette",label: "7d Omelette"),
    ]

    private func parse(data: Data) -> AIUsageSnapshot {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.errorSnapshot("Couldn't parse usage response")
        }
        var windows: [AIUsageWindow] = []
        for def in Self.windowDefs {
            guard let w = payload[def.key] as? [String: Any] else { continue }
            let percent: Double? = {
                for k in ["utilization", "used_percent", "usedPercent"] {
                    if let v = w[k] as? Double { return max(0, min(100, v)) }
                    if let v = w[k] as? Int    { return max(0, min(100, Double(v))) }
                }
                return nil
            }()
            let resetAt: Date? = {
                for k in ["resets_at", "reset_at", "resetAt", "window_end"] {
                    if let s = w[k] as? String {
                        if let d = Self.dateFormatter.date(from: s) { return d }
                        if let d = Self.dateFormatterNoMS.date(from: s) { return d }
                    }
                }
                return nil
            }()
            guard percent != nil || resetAt != nil else { continue }
            let detail = percent.map { String(format: "%.1f%% used", $0) }
            windows.append(AIUsageWindow(
                label: def.label,
                percent: percent,
                resetAt: resetAt,
                detail: detail
            ))
        }
        return AIUsageSnapshot(
            providerName: Self.providerName,
            fetchedAt: Date(),
            windows: windows,
            errorMessage: nil
        )
    }

    private static func errorSnapshot(_ message: String) -> AIUsageSnapshot {
        AIUsageSnapshot(
            providerName: providerName,
            fetchedAt: Date(),
            windows: [],
            errorMessage: message
        )
    }
}
