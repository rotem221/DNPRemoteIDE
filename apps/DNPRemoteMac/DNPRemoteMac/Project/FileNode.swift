import Foundation
import AppKit

/// A node in the project's file tree. Lazy: children are loaded on first access.
final class FileNode: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    private var loadedChildren: [FileNode]?

    init(url: URL) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
    }

    /// Children, loaded lazily. Returns `nil` for files (so OutlineGroup hides the disclosure).
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let cached = loadedChildren { return cached }
        let kids = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]))
            .map { urls in
                urls.sorted { lhs, rhs in
                    let li = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false) ?? false
                    let ri = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false) ?? false
                    if li != ri { return li && !ri }
                    return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
                }
                .map { FileNode(url: $0) }
            } ?? []
        loadedChildren = kids
        return kids
    }

    /// Force a refresh on next access.
    func invalidate() { loadedChildren = nil }

    /// SF Symbol icon for the file or folder.
    var iconName: String {
        guard !isDirectory else { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "ts", "tsx", "jsx": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "doc.text"
        case "md", "markdown": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.fill"
        case "sh", "zsh", "bash": return "terminal"
        case "":      return "doc"
        default:       return "doc.text"
        }
    }

    /// Quick test: is this a binary we shouldn't try to render as text?
    var isProbablyBinary: Bool {
        let ext = url.pathExtension.lowercased()
        return ["png","jpg","jpeg","gif","heic","webp","pdf","zip","gz","tar",
                "ipa","app","dmg","mov","mp4","mp3","wav","ttf","otf","woff",
                "exe","bin","class","jar","so","dylib","framework"].contains(ext)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
