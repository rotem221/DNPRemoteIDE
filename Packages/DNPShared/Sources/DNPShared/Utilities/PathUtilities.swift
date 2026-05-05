import Foundation

/// Cross-platform helpers for working with project filesystem paths.
///
/// Both apps need to compare paths originating from different surfaces
/// (NSOpenPanel pick, Bonjour discovery, persisted session record, iOS
/// recents broadcast, hook env). Surface forms differ in trailing
/// slashes, `~` expansion, `.`/`..` segments, and unresolved symlinks.
/// Centralising the canonicalisation here means every comparison —
/// `WorkspaceController.sessions` filter, iOS recent-projects dedup,
/// Mac transcript watcher cwd→sessionId binding — uses the same key,
/// preventing the cross-project session leakage we hit in production.
public enum PathUtilities {

    /// Canonicalise a project filesystem path for use as a comparison
    /// key. Steps, in order:
    ///
    /// 1. **Tilde expansion** — `~/Foo` → `/Users/<name>/Foo`.
    /// 2. **Standardise** via `URL.standardizedFileURL` — resolves `.`
    ///    and `..` segments and removes redundant separators. (Note:
    ///    standardising does NOT resolve symlinks; that requires
    ///    `resolvingSymlinksInPath`. We intentionally avoid that hop
    ///    here because it touches the filesystem, which we want to
    ///    keep cheap for hot-path callers like `sessions` filters.)
    /// 3. **Trim a single trailing slash** so `/foo/bar/` and
    ///    `/foo/bar` collapse to the same key.
    public static func normalizedProjectPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        var p = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// True when `a` and `b` refer to the same project root after
    /// normalisation. Convenience wrapper for the common check.
    public static func projectPathsMatch(_ a: String, _ b: String) -> Bool {
        normalizedProjectPath(a) == normalizedProjectPath(b)
    }
}
