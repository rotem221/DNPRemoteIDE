import Foundation

/// Tails Claude Code's per-project transcript JSONL files so we can deliver assistant replies to
/// the iOS feed without depending on hooks. Hooks remain wired (and produce richer events for
/// PreToolUse/PostToolUse/etc) but Claude's hook-permission gate means they may not fire on a
/// fresh project — the transcript file is the source of truth and is always written, so polling
/// it guarantees we see every assistant response.
///
/// Transcripts live at `~/.claude/projects/<encoded-project-path>/<claude-session-uuid>.jsonl`.
/// Encoding rule: replace every `/` and ` ` (space) in the project's absolute path with `-`.
@MainActor
final class TranscriptWatcher {

    /// Per-local-session bookkeeping.
    private struct State {
        var projectDir: URL
        /// Snapshot of every `.jsonl` filename in `projectDir` at the moment this session was
        /// registered. The watcher will only bind to a transcript file that is NOT in this set —
        /// guaranteeing we lock onto our own session's transcript and never accidentally mirror
        /// another session's content into this session's bubble feed.
        var existingFilesAtRegistration: Set<String>
        /// The transcript file we've claimed for this session. Once set, never changes — old
        /// behaviour was to flip to the dir's newest file, which caused content from session B
        /// to leak into session A whenever B's transcript was modified after A's.
        var transcriptURL: URL?
        var lastReadByteOffset: UInt64 = 0
        /// Claude assigns each transcript line a stable `uuid`. We track the ones we've already
        /// emitted so a re-read or hook-driven duplicate doesn't double up the iOS feed.
        var emittedLineIds: Set<String> = []
    }

    private var states: [UUID: State] = [:]
    private var pollTask: Task<Void, Never>?

    /// Called for each new assistant message detected. `(localSessionId, claudeSessionId, text)`.
    var onAssistantMessage: ((UUID, String, String) -> Void)?
    /// Called for each user message typed directly into the Mac terminal (so iOS can mirror it).
    /// `(localSessionId, claudeSessionId, text)`. Tool-result rows are filtered out — only real
    /// user prose is surfaced.
    var onUserMessage: ((UUID, String, String) -> Void)?
    /// Called when Claude invokes a tool. `(localSessionId, toolName, summary, isCompletion)`.
    /// `started=true` for `tool_use` rows, `started=false` for the corresponding `tool_result`.
    var onToolActivity: ((UUID, String, String?, Bool) -> Void)?
    /// Called when Claude invokes a code-editing tool (Edit / MultiEdit / Write). Carries the
    /// file path + the unified diff of the change so iOS can render coloured `+`/`-` lines.
    /// `(localSessionId, filePath, linesAdded, linesRemoved, diffPreview, kind)`.
    var onCodeEdit: ((UUID, String, Int, Int, String, String) -> Void)?
    /// Called for extended-thinking text blocks Claude emits mid-turn. `(localSessionId, text)`.
    var onThinking: ((UUID, String) -> Void)?
    /// Called when an assistant message includes a `usage` block. Tokens here are authoritative
    /// (not heuristic) — they're the model's own count of what it just consumed. Caller maps
    /// this to a `ContextSnapshot` with `.measured` confidence.
    /// `(localSessionId, inputTokens, cacheReadTokens, cacheCreateTokens, outputTokens, model)`.
    var onUsage: ((UUID, Int, Int, Int, Int, String?) -> Void)?
    /// Called whenever the transcript file's identity for a session is first observed —
    /// callers use this to bind Claude's session_id ↔ local session UUID for hook routing.
    var onClaudeSessionDiscovered: ((UUID, String) -> Void)?
    /// Called when Claude Code writes its own `ai-title` line for the session — that's the
    /// short summary it generates after the first turn (e.g. "Debug macOS diagnostics
    /// page login freeze"). Per user instruction, when Claude provides a title we adopt
    /// it verbatim and stop overriding from the prompt-derived auto-title path.
    /// `(localSessionId, aiTitle)`.
    var onAITitle: ((UUID, String) -> Void)?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 600_000_000)   // 600 ms
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
    }

    /// Register a local session so its project directory will be polled. Idempotent.
    /// Snapshots the set of `.jsonl` filenames present BEFORE Claude starts so the watcher can
    /// later pick the newly-created transcript (the one Claude writes for THIS session) instead
    /// of one belonging to a different session running in the same project directory.
    func register(sessionId: UUID, projectPath: String) {
        let encoded = Self.encodeProjectPath(projectPath)
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)

        if states[sessionId] == nil {
            let existing = Self.jsonlFilenames(in: projectDir)
            states[sessionId] = State(
                projectDir: projectDir,
                existingFilesAtRegistration: existing
            )
        } else {
            states[sessionId]?.projectDir = projectDir
        }
    }

    /// True if the first line of this JSONL file declares `"isSidechain": true` — i.e. it's
    /// a Claude-Code Task-tool sub-agent transcript, not the user's main session. We read
    /// only the head of the file (first 1 KB) since the marker is always on the first line.
    private static func isSidechainTranscript(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)) ?? Data()
        guard let str = String(data: head, encoding: .utf8) else { return false }
        // Cheap substring check — JSON canonical form has no spaces around `:`. Catches the
        // common variant Claude writes; full JSON parse would be overkill here.
        let firstLine = str.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? str
        return firstLine.contains("\"isSidechain\":true")
            || firstLine.contains("\"isSidechain\": true")
    }

    private static func jsonlFilenames(in dir: URL) -> Set<String> {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return Set(urls.filter { $0.pathExtension == "jsonl" }.map { $0.lastPathComponent })
    }

    func unregister(sessionId: UUID) {
        states.removeValue(forKey: sessionId)
    }

    // MARK: - Internals

    private func tick() async {
        for sid in states.keys {
            await poll(sessionId: sid)
        }
    }

    private func poll(sessionId: UUID) async {
        guard var st = states[sessionId] else { return }

        // Have we claimed a transcript file for this session yet? If not, look for one that
        // appeared AFTER registration (i.e. a jsonl that wasn't there when we started watching).
        if st.transcriptURL == nil {
            let current = Self.jsonlFilenames(in: st.projectDir)
            // Newly-appeared files = current minus the snapshot we took at registration.
            let newFiles = current.subtracting(st.existingFilesAtRegistration)
            // Sort newest-first so we pick the most-recently-modified new file.
            let candidates = newFiles
                .map { st.projectDir.appendingPathComponent($0) }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                                .contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }

            // Skip files whose first line marks them as `isSidechain: true` — those are
            // Claude-Code's Task-tool sub-agent transcripts (the ones with literal "Warmup"
            // user messages). Binding to one of those would mirror the sub-agent conversation
            // into the user's chat instead of leaving the new session empty.
            let mainSession = candidates.first(where: { !Self.isSidechainTranscript($0) })

            guard let bound = mainSession else { return }   // wait for Claude to create its jsonl
            st.transcriptURL = bound
            st.lastReadByteOffset = 0                  // start from the beginning of OUR file
            st.emittedLineIds.removeAll()
            states[sessionId] = st

            let claudeSid = bound.deletingPathExtension().lastPathComponent
            onClaudeSessionDiscovered?(sessionId, claudeSid)
            return
        }

        // We're pinned to one transcript — never flip to a different file even if other
        // sessions in the same project write more recent content. That was the bug.
        guard let newest = st.transcriptURL,
              FileManager.default.fileExists(atPath: newest.path)
        else { return }

        // Read bytes that arrived since last tick.
        let size = (try? FileManager.default.attributesOfItem(atPath: newest.path)[.size] as? UInt64) ?? 0
        guard size > st.lastReadByteOffset else { return }

        guard let fh = try? FileHandle(forReadingFrom: newest) else { return }
        defer { try? fh.close() }
        let startOffset = st.lastReadByteOffset
        do { try fh.seek(toOffset: startOffset) } catch { return }
        let newData = (try? fh.readToEnd()) ?? Data()

        // Only consume bytes up to the LAST newline. Anything after it is an
        // in-progress JSONL line — Claude may still be flushing the final
        // assistant turn (the summary at the end of a long response is the most
        // common offender). If we naively advance past those bytes, the partial
        // line fails JSON parse on this tick, and on the next tick we read from
        // past the partial → the row vanishes from the iOS feed forever. The
        // observed bug: Claude's closing summary missing on iOS while every
        // earlier message and tool call mirrored fine.
        guard let lastNL = newData.lastIndex(where: { $0 == 0x0A }) else {
            // Nothing newline-terminated yet — leave the offset untouched and
            // try again on the next tick when more bytes have landed.
            return
        }
        let completeByteCount = newData.distance(from: newData.startIndex, to: lastNL) + 1
        let completeData = newData.prefix(completeByteCount)
        st.lastReadByteOffset = startOffset + UInt64(completeByteCount)

        if let str = String(data: Data(completeData), encoding: .utf8) {
            for raw in str.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }
                let lineId = (obj["uuid"] as? String) ?? UUID().uuidString
                if st.emittedLineIds.contains(lineId) { continue }
                // Defense in depth — even if a sidechain line slips into a transcript we
                // claimed as the main session, never surface it to iOS.
                if (obj["isSidechain"] as? Bool) == true { continue }

                let claudeSid = (obj["sessionId"] as? String)
                               ?? newest.deletingPathExtension().lastPathComponent
                let kind = obj["type"] as? String ?? ""

                switch kind {
                case "assistant":
                    guard let message = obj["message"] as? [String: Any] else { continue }
                    let text = Self.extractText(from: message)
                    if !text.isEmpty {
                        st.emittedLineIds.insert(lineId)
                        onAssistantMessage?(sessionId, claudeSid, text)
                    }
                    // Surface every tool_use block (Bash, Read, Edit, Glob, Grep, Task, ...) so
                    // iOS can show a card per running step. Edit/Write/MultiEdit ALSO emit a
                    // codeEdit event with a unified diff so iOS renders coloured + / - lines.
                    for toolUse in Self.extractToolUses(from: message) {
                        st.emittedLineIds.insert("\(lineId)#tool#\(toolUse.id)")
                        onToolActivity?(sessionId, toolUse.name, toolUse.summary, true)
                        if let edit = toolUse.codeEdit {
                            onCodeEdit?(sessionId, edit.filePath, edit.linesAdded,
                                        edit.linesRemoved, edit.diffPreview, edit.kind)
                        }
                    }
                    // Extended thinking content — render as thinking text on iOS.
                    let thinking = Self.extractThinking(from: message)
                    if !thinking.isEmpty {
                        onThinking?(sessionId, thinking)
                    }
                    // Pull authoritative token counts from `usage` so the context indicator
                    // reflects what Claude actually counted, not a transcript-bytes heuristic.
                    if let usage = message["usage"] as? [String: Any] {
                        let input = (usage["input_tokens"] as? Int) ?? 0
                        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                        let output = (usage["output_tokens"] as? Int) ?? 0
                        let model = message["model"] as? String
                        onUsage?(sessionId, input, cacheRead, cacheCreate, output, model)
                    }
                case "user":
                    guard let message = obj["message"] as? [String: Any] else { continue }
                    // Skip tool_result rows — those carry tool output, not user prose. Mark
                    // any tool_result we see as a "completed" toolActivity for iOS.
                    if let toolResultId = Self.toolResultId(from: message) {
                        st.emittedLineIds.insert("\(lineId)#toolresult#\(toolResultId)")
                        onToolActivity?(sessionId, toolResultId, nil, false)
                        continue
                    }
                    let text = Self.extractText(from: message)
                    if !text.isEmpty {
                        st.emittedLineIds.insert(lineId)
                        onUserMessage?(sessionId, claudeSid, text)
                    }
                case "ai-title":
                    // Claude writes this once per session after generating its own title
                    // for the conversation (e.g. "Debug macOS diagnostics page login
                    // freeze"). The same line can repeat as Claude refines its summary,
                    // so dedupe by (lineId, title) — the lineId guard up top would skip
                    // a re-emission only if the row's `uuid` is identical.
                    if let title = obj["aiTitle"] as? String,
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        st.emittedLineIds.insert(lineId)
                        onAITitle?(sessionId, title)
                    }
                default:
                    continue
                }
            }
        }
        states[sessionId] = st
    }

    private func newestTranscript(in dir: URL) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let jsonl = urls.filter { $0.pathExtension == "jsonl" }
        return jsonl
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    /// Claude encodes a project path by replacing `/` and spaces with `-`. The leading slash
    /// becomes a leading `-`, e.g. `/Users/foo/My Project` → `-Users-foo-My-Project`.
    /// Public so the dispatcher can locate the same on-disk file when reconstructing
    /// historic events for the iOS backfill.
    static func encodeProjectPath(_ path: String) -> String {
        var s = path
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: " ", with: "-")
        return s
    }

    /// Pull plain text out of a Claude transcript message object, joining all `text` content
    /// blocks (skipping tool_use, tool_result, and other non-text blocks).
    private static func extractText(from message: [String: Any]) -> String {
        if let content = message["content"] as? [[String: Any]] {
            let texts: [String] = content.compactMap {
                ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil
            }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let text = message["content"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Extract concatenated extended-thinking text from an assistant message.
    private static func extractThinking(from message: [String: Any]) -> String {
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        let texts: [String] = content.compactMap {
            ($0["type"] as? String) == "thinking" ? ($0["thinking"] as? String) : nil
        }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diff metadata extracted from an Edit/Write/MultiEdit tool_use block.
    struct CodeEditExtraction {
        let filePath: String
        let linesAdded: Int
        let linesRemoved: Int
        let diffPreview: String     // unified-diff style with leading +/- per line
        let kind: String            // "edit" | "write" | "multiedit"
    }

    private struct ToolUseBlock {
        let id: String
        let name: String
        let summary: String?
        /// Populated when this tool_use is Edit/Write/MultiEdit — the diff that drives the
        /// coloured codeEdit card on iOS.
        let codeEdit: CodeEditExtraction?
    }

    /// Pull every `tool_use` block out of an assistant message. Builds a short summary string
    /// from the most likely `input` field for that tool — `command` for Bash, `file_path` for
    /// Read/Edit/Write, `pattern` for Grep — and additionally builds a unified diff for the
    /// code-editing tools so iOS can render coloured + / - lines.
    private static func extractToolUses(from message: [String: Any]) -> [ToolUseBlock] {
        guard let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard (block["type"] as? String) == "tool_use" else { return nil }
            let id = (block["id"] as? String) ?? UUID().uuidString
            let name = (block["name"] as? String) ?? "tool"
            let input = block["input"] as? [String: Any]
            let summary = summarize(toolName: name, input: input)
            let edit = extractCodeEdit(toolName: name, input: input)
            return ToolUseBlock(id: id, name: name, summary: summary, codeEdit: edit)
        }
    }

    /// Build a unified diff for Edit / Write / MultiEdit invocations. Diff is computed via
    /// the `LineDiff` helper (Hirschberg's algorithm-lite — small inputs make it cheap).
    private static func extractCodeEdit(toolName: String, input: [String: Any]?) -> CodeEditExtraction? {
        guard let input = input else { return nil }
        let path = (input["file_path"] as? String)
                ?? (input["path"] as? String)
                ?? "(unknown)"
        switch toolName {
        case "Edit":
            guard let oldStr = input["old_string"] as? String,
                  let newStr = input["new_string"] as? String else { return nil }
            let diff = LineDiff.unifiedDiff(old: oldStr, new: newStr)
            return CodeEditExtraction(filePath: path,
                                      linesAdded: diff.adds, linesRemoved: diff.removes,
                                      diffPreview: diff.text, kind: "edit")
        case "Write":
            // Write replaces the entire file. Treat all lines as additions so iOS shows the
            // file body in green.
            guard let content = input["content"] as? String else { return nil }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let diff = lines.map { "+" + $0 }.joined(separator: "\n")
            return CodeEditExtraction(filePath: path,
                                      linesAdded: lines.count, linesRemoved: 0,
                                      diffPreview: diff, kind: "write")
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            var combined = ""
            var totalAdds = 0
            var totalRemoves = 0
            for (i, e) in edits.enumerated() {
                guard let o = e["old_string"] as? String,
                      let n = e["new_string"] as? String else { continue }
                let d = LineDiff.unifiedDiff(old: o, new: n)
                if i > 0 { combined += "\n@@ ──────── @@\n" }
                combined += d.text
                totalAdds += d.adds
                totalRemoves += d.removes
            }
            return CodeEditExtraction(filePath: path,
                                      linesAdded: totalAdds, linesRemoved: totalRemoves,
                                      diffPreview: combined, kind: "multiedit")
        default:
            return nil
        }
    }

    /// If the user-row is a tool_result, return its tool_use_id (so we can pair completion to
    /// the originating tool_use card on iOS).
    private static func toolResultId(from message: [String: Any]) -> String? {
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                if (block["type"] as? String) == "tool_result",
                   let id = block["tool_use_id"] as? String {
                    return id
                }
            }
        }
        return nil
    }

    private static func summarize(toolName: String, input: [String: Any]?) -> String? {
        guard let input = input else { return nil }
        // TodoWrite gets a structured multi-line summary so iOS can render
        // a proper checklist card instead of a generic "Tool" row.
        // Format: one line per todo, `<status>\t<content>`. Status is one
        // of `pending` / `in_progress` / `completed` (Claude's own enum).
        if toolName == "TodoWrite",
           let todos = input["todos"] as? [[String: Any]], !todos.isEmpty {
            let lines = todos.compactMap { todo -> String? in
                guard let content = (todo["content"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { return nil }
                let status = (todo["status"] as? String) ?? "pending"
                return "\(status)\t\(content)"
            }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        // Rank order of "the field that says what this call is doing".
        let preferred = ["command", "file_path", "path", "pattern", "query", "url", "description"]
        for key in preferred {
            if let s = input[key] as? String, !s.isEmpty {
                return s
            }
        }
        // Fallback: first string value in the input.
        for (_, v) in input {
            if let s = v as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
