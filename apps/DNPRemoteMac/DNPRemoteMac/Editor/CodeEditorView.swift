import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

/// Source code viewer powered by CodeEditApp's `SourceEditor` (CodeEditSourceEditor v0.15+).
/// Tree-Sitter syntax highlighting, line-number gutter, multi-cursor, find/replace, code folding.
/// Same engine that powers the open-source CodeEdit IDE.
struct CodeEditorView: View {
    @EnvironmentObject var vm: MacAppViewModel
    let file: OpenFile
    @State private var content: String
    @State private var loadError: String?
    @State private var wordWrap: Bool = false
    @State private var state: SourceEditorState = SourceEditorState(cursorPositions: [])
    /// Whether the inline diff banner is expanded. Default collapsed so opening a
    /// file Claude touched doesn't shove the editor down — the user clicks the
    /// chip to see the green/red diff.
    @State private var diffExpanded: Bool = false

    /// Load synchronously in init. `CodeEditSourceEditor`'s `SourceEditor` reads the binding's
    /// `wrappedValue` **only** during `makeNSViewController`. If we used `.task { ... }` the
    /// editor would mount with `""` and never refresh — which is exactly what looked like
    /// "files showing empty content".
    init(file: OpenFile) {
        self.file = file
        let r = Self.loadSync(url: file.node.url, isBinary: file.node.isProbablyBinary)
        _content = State(initialValue: r.text)
        _loadError = State(initialValue: r.error)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(MacTheme.border)
            // Inline diff banner — appears only when Claude has just edited THIS
            // file and the diff is still cached on the VM. Collapsed by default
            // (single-line chip with `+N / −M`); expand to see the green/red lines.
            if let diff = recentDiff, !diff.isEmpty {
                DiffBanner(diff: diff, expanded: $diffExpanded)
                Divider().background(MacTheme.border)
            }
            Group {
                if let err = loadError {
                    errorView(err)
                } else if file.node.isProbablyBinary {
                    binaryView
                } else {
                    editor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MacTheme.background)
    }

    /// Lookup of the latest diff for THIS file — keyed by the same standardized
    /// path the codeEdit watcher uses, so a diff stamped from a Claude session
    /// resolves cleanly when the user opens the file in the editor.
    private var recentDiff: String? {
        let key = file.node.url.standardizedFileURL.path
        return vm.lastDiffByFile[key]
    }

    private var editor: some View {
        SourceEditor(
            $content,
            language: detectedLanguage,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: Self.darkTheme,
                    useThemeBackground: true,
                    font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    lineHeightMultiple: 1.3,
                    wrapLines: wordWrap,
                    tabWidth: 4
                ),
                behavior: .init(isEditable: false, isSelectable: true)
            ),
            state: $state
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: file.node.iconName).foregroundStyle(MacTheme.textSecondary)
            Text(file.node.name).font(.callout.bold()).foregroundStyle(MacTheme.textPrimary)
            Text(relativePath).font(.caption).foregroundStyle(MacTheme.textTertiary).lineLimit(1)
            Spacer()
            if !file.node.isProbablyBinary && loadError == nil {
                Toggle(isOn: $wordWrap) { Text("Wrap").font(.caption) }
                    .toggleStyle(.switch).controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MacTheme.surface)
    }

    private var relativePath: String {
        guard let root = file.projectRoot?.path else { return file.node.url.path }
        let p = file.node.url.path
        if p.hasPrefix(root) { return String(p.dropFirst(root.count + 1)) }
        return p
    }

    // MARK: - Empty / error / binary

    private var binaryView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.fill").font(.largeTitle).foregroundStyle(MacTheme.textTertiary)
            Text("Binary file — preview not available").foregroundStyle(MacTheme.textSecondary)
            Text(byteSizeString).font(.caption.monospacedDigit()).foregroundStyle(MacTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(MacTheme.warning)
            Text("Couldn't open this file").foregroundStyle(MacTheme.textPrimary)
            Text(message).font(.caption).foregroundStyle(MacTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var byteSizeString: String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: file.node.url.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        return Self.byteFormatter.string(fromByteCount: Int64(size))
    }

    /// Static — body re-renders on every editor state change, and a fresh
    /// `ByteCountFormatter` per render is unnecessary heap churn.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f
    }()

    // MARK: - Loading

    /// Synchronous load run in `init`. Cheap for files under 5 MB — typical source code is well below that.
    private static func loadSync(url: URL, isBinary: Bool) -> (text: String, error: String?) {
        if isBinary { return ("", nil) }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            if size > 5 * 1024 * 1024 {
                return ("", "File is larger than 5 MB.")
            }
            let data = try Data(contentsOf: url, options: [.alwaysMapped])
            if let s = String(data: data, encoding: .utf8) { return (s, nil) }
            if let s = String(data: data, encoding: .isoLatin1) { return (s, nil) }
            return ("", "Unsupported encoding.")
        } catch {
            return ("", error.localizedDescription)
        }
    }

    // MARK: - Language detection

    private var detectedLanguage: CodeLanguage {
        CodeLanguage.detectLanguageFrom(url: file.node.url)
    }

    // MARK: - Theme (dark, hand-tuned)

    private static let darkTheme: EditorTheme = {
        let plain   = NSColor.white.withAlphaComponent(0.92)
        let comment = NSColor(red: 0.45, green: 0.55, blue: 0.45, alpha: 1)
        let string  = NSColor(red: 0.95, green: 0.66, blue: 0.42, alpha: 1)
        let keyword = NSColor(red: 0.74, green: 0.50, blue: 0.95, alpha: 1)
        let number  = NSColor(red: 0.96, green: 0.80, blue: 0.42, alpha: 1)
        let typeC   = NSColor(red: 0.42, green: 0.86, blue: 0.84, alpha: 1)
        let funcC   = NSColor(red: 0.62, green: 0.84, blue: 1.00, alpha: 1)
        let variable = NSColor(red: 0.85, green: 0.93, blue: 1.00, alpha: 1)

        return EditorTheme(
            text:           EditorTheme.Attribute(color: plain),
            insertionPoint: funcC,
            invisibles:     EditorTheme.Attribute(color: NSColor.white.withAlphaComponent(0.18)),
            background:     NSColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1),
            lineHighlight:  NSColor.white.withAlphaComponent(0.04),
            selection:      NSColor(red: 0.50, green: 0.78, blue: 1.00, alpha: 0.30),
            keywords:       EditorTheme.Attribute(color: keyword),
            commands:       EditorTheme.Attribute(color: funcC),
            types:          EditorTheme.Attribute(color: typeC),
            attributes:     EditorTheme.Attribute(color: NSColor(red: 0.96, green: 0.66, blue: 0.42, alpha: 1)),
            variables:      EditorTheme.Attribute(color: variable),
            values:         EditorTheme.Attribute(color: number),
            numbers:        EditorTheme.Attribute(color: number),
            strings:        EditorTheme.Attribute(color: string),
            characters:     EditorTheme.Attribute(color: string),
            comments:       EditorTheme.Attribute(color: comment)
        )
    }()
}

// MARK: - Inline diff banner

/// Sits between the toolbar and the editor when Claude has just edited this file.
/// Collapsed: a one-line chip showing `+N / −M` so the editor isn't crowded.
/// Expanded: a Cursor-style diff with green/red line backgrounds — same renderer
/// the right-pane feed uses (`DiffPreviewView` in `SessionFeedPaneView.swift`),
/// referenced by name here so we don't fork the styling.
private struct DiffBanner: View {
    let diff: String
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chip
            if expanded {
                DiffPreviewView(diff: diff)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(MacTheme.surfaceAlt.opacity(0.6))
    }

    private var chip: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacTheme.warning)
                Text("Edited by Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                stats
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(MacTheme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        let added   = diff.split(separator: "\n").filter { $0.hasPrefix("+") }.count
        let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") }.count
        return HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(Color(red: 0.40, green: 0.85, blue: 0.50))
            }
            if removed > 0 {
                Text("−\(removed)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
            }
        }
    }
}
