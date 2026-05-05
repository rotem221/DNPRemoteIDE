import Foundation

/// Maintains a long-term per-project notebook at `<projectPath>/memory/MEMORY.md` plus `notes/*.md`.
/// `MEMORY.md` is an index of one-line entries; bodies live in dedicated files. Every save updates the index.
actor ProjectMemoryService {

    func memoryRoot(for projectPath: String) -> URL {
        let dir = URL(fileURLWithPath: projectPath).appendingPathComponent("memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func appendNote(projectPath: String, title: String, body: String, tags: [String]) async throws -> URL {
        let root = memoryRoot(for: projectPath)
        let stamp = Self.fileStamp(Date())
        let slug = Self.slugify(title)
        let fileName = "\(stamp)-\(slug).md"
        let url = root.appendingPathComponent("notes/\(fileName)")
        var content = "# \(title)\n\n"
        content += "*captured:* \(ISO8601DateFormatter.dnpShared.string(from: Date()))\n"
        if !tags.isEmpty { content += "*tags:* \(tags.joined(separator: ", "))\n" }
        content += "\n---\n\n\(body)\n"
        // `Data(string.utf8)` is non-optional — UTF-8 encoding cannot
        // fail for any Swift `String`, so this avoids the IUO sibling
        // (`String.data(using:)!`) that would otherwise sit in a write
        // path with no real failure mode.
        try Data(content.utf8).write(to: url)
        try await rebuildIndex(projectPath: projectPath)
        return url
    }

    func listNotes(projectPath: String) async throws -> [ProjectMemoryEntry] {
        let dir = memoryRoot(for: projectPath).appendingPathComponent("notes")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.compactMap { fn in
            let url = dir.appendingPathComponent(fn)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let created = (attrs?[.creationDate] as? Date) ?? Date()
            let title = String(fn.dropLast(3))    // strip .md
            return ProjectMemoryEntry(fileName: fn, title: title, createdAt: created, tags: [])
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func rebuildIndex(projectPath: String) async throws {
        let entries = try await listNotes(projectPath: projectPath)
        var md = "# Project memory — \((projectPath as NSString).lastPathComponent)\n\n"
        md += "_Long-term notebook auto-maintained by DNP Remote Mac. One line per note; details in `notes/`._\n\n"
        for e in entries {
            md += "- [\(e.title)](notes/\(e.fileName)) — \(ISO8601DateFormatter.dnpShared.string(from: e.createdAt))\n"
        }
        let url = memoryRoot(for: projectPath).appendingPathComponent("MEMORY.md")
        try Data(md.utf8).write(to: url)
    }

    // MARK: - helpers

    private static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    private static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let scalars = lower.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let joined = String(scalars).split(separator: "-").joined(separator: "-")
        return String(joined.prefix(60))
    }
}
