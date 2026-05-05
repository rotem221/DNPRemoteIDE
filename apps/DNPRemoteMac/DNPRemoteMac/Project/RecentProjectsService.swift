import Foundation
import AppKit

/// Persisted list of projects the user has opened — drives the Welcome scene's recents
/// list, the dock menu, and the File → Open Recent submenu. UserDefaults-backed so it
/// survives app restarts and is per-user.
///
/// Each entry tracks the path, a display name, the kind (local / clone / SSH), the last
/// opened time (so we can sort newest-first), and — for SSH entries — connection details
/// so re-opening kicks off `ssh` automatically without re-entering credentials.
@MainActor
final class RecentProjectsService: ObservableObject {
    static let shared = RecentProjectsService()

    @Published private(set) var entries: [RecentProject] = []

    private let storeKey = "dnp.mac.recentProjects"
    private let maxEntries = 12

    private init() { load() }

    func register(_ entry: RecentProject) {
        // Normalize before dedup so two opens of the same on-disk folder via different
        // URL surface (trailing slash, ./ component, symlink) resolve to the same id +
        // path and dedup correctly. Without this, `Open Recent` could pile up the same
        // project under three near-identical rows.
        let normalized = Self.normalize(entry)
        // Dedup BY PATH (not just id) — if the entry's stored id was generated before
        // normalization shipped, a re-register might still race a stale duplicate.
        // Compare the normalized path within the same kind so different kinds with the
        // same path (an SSH project at /Users/foo and a local one at /Users/foo on a
        // different host) stay distinct.
        var next = entries.filter { existing in
            !(existing.kind == normalized.kind &&
              Self.dedupKey(for: existing) == Self.dedupKey(for: normalized))
        }
        var stamped = normalized
        stamped.lastOpenedAt = Date()
        next.insert(stamped, at: 0)
        // Trim to keep the list manageable — 12 fits the welcome page without scrolling.
        if next.count > maxEntries { next = Array(next.prefix(maxEntries)) }
        entries = next
        save()
    }

    /// Convenience for the main "Open Project" path — local on-disk folder.
    func registerLocal(at url: URL) {
        let normalized = Self.normalizedPath(url.path)
        let display = (url as NSURL).lastPathComponent ?? url.lastPathComponent
        register(RecentProject(
            id: "local:\(normalized)",
            displayName: display,
            path: normalized,
            kind: .local,
            sshHost: nil, sshUser: nil, sshPort: nil, sshIdentityFile: nil,
            gitURL: nil
        ))
    }

    // MARK: - Normalization & dedup

    /// Apply path normalization for local/clone entries. SSH entries are normalized
    /// via their host triple (user@host:port:remotePath) since `path` is already a
    /// remote string.
    private static func normalize(_ entry: RecentProject) -> RecentProject {
        var out = entry
        switch entry.kind {
        case .local:
            let p = normalizedPath(entry.path)
            out.path = p
            out.id = "local:\(p)"
        case .clone:
            let p = normalizedPath(entry.path)
            out.path = p
            out.id = "clone:\(p)"
        case .ssh:
            // SSH `path` is a remote `/path/on/host` — strip trailing slashes only;
            // we deliberately don't resolve symlinks for a remote path we can't see.
            let p = entry.path.hasSuffix("/") && entry.path.count > 1
                ? String(entry.path.dropLast())
                : entry.path
            out.path = p
            let host = entry.sshHost ?? ""
            let user = entry.sshUser ?? ""
            let port = entry.sshPort ?? 22
            out.id = "ssh:\(user)@\(host):\(port):\(p)"
        }
        return out
    }

    /// Resolve `~`, symlinks, `..` / `.` components and trailing slashes so two URL
    /// representations of the same folder collapse to a single string. The actual
    /// on-disk path is the source of truth.
    static func normalizedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var p = url.path
        // Normalize trailing slash (root "/" stays as-is, everything else loses it).
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Returns the value to compare for "is this the same project?" — used by both
    /// the new-entry dedup and the load-time cleanup.
    private static func dedupKey(for entry: RecentProject) -> String {
        switch entry.kind {
        case .local, .clone:
            return normalizedPath(entry.path)
        case .ssh:
            let host = entry.sshHost ?? ""
            let user = entry.sshUser ?? ""
            let port = entry.sshPort ?? 22
            return "\(user)@\(host):\(port):\(entry.path)"
        }
    }

    /// Remove an entry — used by "Remove from list" in the welcome / dock menu.
    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return }
        guard let decoded = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            return
        }
        // One-time cleanup: collapse any duplicates that snuck in before normalization
        // shipped (e.g. `/Users/x/Foo` + `/Users/x/Foo/` + `/Users/x/./Foo` all pointing
        // at the same folder). Keep the most-recent of each (kind + dedupKey) pair.
        let normalizedAll = decoded.map { Self.normalize($0) }
        var seen = Set<String>()
        var collapsed: [RecentProject] = []
        let sortedByRecency = normalizedAll.sorted {
            ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
        }
        for entry in sortedByRecency {
            let key = "\(entry.kind.rawValue):\(Self.dedupKey(for: entry))"
            if seen.insert(key).inserted {
                collapsed.append(entry)
            }
        }
        entries = collapsed
        // If cleanup actually changed anything, persist so we don't redo the work next launch.
        if collapsed.count != decoded.count
            || zip(collapsed, decoded).contains(where: { $0.id != $1.id }) {
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}

/// One persisted recent-project entry. The composite `id` (kind + path/host) is used as
/// the dedup key so re-opening the same folder bumps it to the top instead of creating
/// a duplicate.
struct RecentProject: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    /// Local path. For SSH this is the remote `/path/on/host`, for clones the local
    /// destination after the clone finished.
    var path: String
    var kind: ProjectKind
    var lastOpenedAt: Date?

    // SSH-specific (nil for other kinds)
    var sshHost: String?
    var sshUser: String?
    var sshPort: Int?
    var sshIdentityFile: String?

    // Git-clone-specific (nil for other kinds) — origin URL, captured so the welcome row
    // can show "github.com/owner/repo" subtitle.
    var gitURL: String?
}

enum ProjectKind: String, Codable, Sendable {
    case local
    case clone
    case ssh
}
