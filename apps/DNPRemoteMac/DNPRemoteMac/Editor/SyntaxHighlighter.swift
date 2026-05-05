import Foundation
import AppKit

/// Lightweight regex-based syntax highlighter. Not perfect, but readable in <300 lines.
/// Supports: Swift, JavaScript/TypeScript, Python, JSON, YAML, Markdown, Bash, generic.
enum SyntaxHighlighter {

    enum Language {
        case swift, jsTs, python, json, yaml, markdown, bash, generic
    }

    static func language(for url: URL) -> Language {
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .jsTs
        case "py": return .python
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh": return .bash
        default: return .generic
        }
    }

    // MARK: - Theme (dark)

    static let plain   = NSColor.white.withAlphaComponent(0.92)
    static let comment = NSColor(red: 0.45, green: 0.55, blue: 0.45, alpha: 1)
    static let string  = NSColor(red: 0.95, green: 0.66, blue: 0.42, alpha: 1)
    static let keyword = NSColor(red: 0.74, green: 0.50, blue: 0.95, alpha: 1)
    static let number  = NSColor(red: 0.96, green: 0.80, blue: 0.42, alpha: 1)
    static let typeC   = NSColor(red: 0.42, green: 0.86, blue: 0.84, alpha: 1)
    static let funcC   = NSColor(red: 0.62, green: 0.84, blue: 1.00, alpha: 1)
    static let punct   = NSColor.white.withAlphaComponent(0.55)
    static let mdHead  = NSColor(red: 0.62, green: 0.84, blue: 1.00, alpha: 1)
    static let mdEmph  = NSColor(red: 0.96, green: 0.80, blue: 0.42, alpha: 1)

    // MARK: - Public

    static func highlight(_ text: String, language: Language, baseFont: NSFont) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: plain
        ])
        switch language {
        case .swift:    applyCStyle(attr, keywords: swiftKeywords, types: swiftTypes)
        case .jsTs:     applyCStyle(attr, keywords: jsTsKeywords,  types: jsTypes)
        case .python:   applyPython(attr)
        case .json:     applyJSON(attr)
        case .yaml:     applyYAML(attr)
        case .markdown: applyMarkdown(attr)
        case .bash:     applyBash(attr)
        case .generic:  break
        }
        return attr
    }

    // MARK: - C-family (Swift, JS/TS)

    private static let swiftKeywords: Set<String> = [
        "import","func","class","struct","enum","protocol","extension","actor","let","var",
        "if","else","guard","return","while","for","in","switch","case","default","break","continue",
        "do","try","catch","throws","throw","async","await","public","private","internal","fileprivate",
        "open","static","final","override","init","deinit","self","super","nil","true","false",
        "as","is","where","typealias","associatedtype","some","any","inout","mutating","nonmutating",
        "lazy","weak","unowned","defer","repeat","fallthrough","operator","precedencegroup","subscript"
    ]
    private static let swiftTypes: Set<String> = [
        "Int","Int8","Int16","Int32","Int64","UInt","UInt8","UInt16","UInt32","UInt64",
        "Double","Float","Bool","String","Character","Array","Dictionary","Set","Optional",
        "URL","Date","Data","UUID","TimeInterval","Result","Error","View","NSObject"
    ]
    private static let jsTsKeywords: Set<String> = [
        "function","const","let","var","class","interface","extends","implements","new","return",
        "if","else","while","for","of","in","do","switch","case","default","break","continue",
        "try","catch","finally","throw","async","await","yield","import","export","from","as",
        "true","false","null","undefined","this","super","typeof","instanceof","void","delete",
        "public","private","protected","static","readonly","abstract","type","enum","namespace"
    ]
    private static let jsTypes: Set<String> = [
        "string","number","boolean","object","any","unknown","never","void","Promise","Array","Map","Set"
    ]

    private static func applyCStyle(_ attr: NSMutableAttributedString, keywords: Set<String>, types: Set<String>) {
        let s = attr.string as NSString
        // Strings (double-quoted, single-quoted, backticks)
        regex(in: s, pattern: #""(?:\\.|[^"\\\n])*""#)?.forEach { range in
            attr.addAttribute(.foregroundColor, value: string, range: range)
        }
        regex(in: s, pattern: #"'(?:\\.|[^'\\\n])*'"#)?.forEach { range in
            attr.addAttribute(.foregroundColor, value: string, range: range)
        }
        regex(in: s, pattern: #"`(?:\\.|[^`\\])*`"#)?.forEach { range in
            attr.addAttribute(.foregroundColor, value: string, range: range)
        }
        // Numbers
        regex(in: s, pattern: #"\b\d+(?:\.\d+)?\b"#)?.forEach { range in
            attr.addAttribute(.foregroundColor, value: number, range: range)
        }
        // Identifiers (apply keywords/types last so they win over identifiers)
        regex(in: s, pattern: #"\b[A-Za-z_][A-Za-z_0-9]*\b"#)?.forEach { range in
            let token = s.substring(with: range)
            if keywords.contains(token) {
                attr.addAttribute(.foregroundColor, value: keyword, range: range)
            } else if types.contains(token) || (token.first?.isUppercase ?? false) {
                attr.addAttribute(.foregroundColor, value: typeC, range: range)
            }
        }
        // Function-call sites: ident followed by `(`
        regex(in: s, pattern: #"\b[A-Za-z_][A-Za-z_0-9]*(?=\()"#)?.forEach { range in
            let token = s.substring(with: range)
            if !keywords.contains(token) && !(token.first?.isUppercase ?? false) {
                attr.addAttribute(.foregroundColor, value: funcC, range: range)
            }
        }
        // Comments (// and /* */)
        regex(in: s, pattern: #"//[^\n]*"#)?.forEach { range in
            attr.addAttribute(.foregroundColor, value: comment, range: range)
        }
        regex(in: s, pattern: #"/\*[\s\S]*?\*/"#)?.forEach { range in
            attr.addAttribute(.foregroundColor, value: comment, range: range)
        }
    }

    // MARK: - Python

    private static let pythonKeywords: Set<String> = [
        "def","class","return","import","from","as","if","elif","else","while","for","in","not","and","or",
        "is","None","True","False","try","except","finally","raise","with","yield","async","await","lambda",
        "global","nonlocal","pass","break","continue","del"
    ]
    private static func applyPython(_ attr: NSMutableAttributedString) {
        let s = attr.string as NSString
        regex(in: s, pattern: #""""[\s\S]*?""""#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
        regex(in: s, pattern: #"'''[\s\S]*?'''"#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
        regex(in: s, pattern: #""(?:\\.|[^"\\\n])*""#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
        regex(in: s, pattern: #"'(?:\\.|[^'\\\n])*'"#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
        regex(in: s, pattern: #"\b\d+(?:\.\d+)?\b"#)?.forEach { attr.addAttribute(.foregroundColor, value: number, range: $0) }
        regex(in: s, pattern: #"\b[A-Za-z_][A-Za-z_0-9]*\b"#)?.forEach { range in
            let token = s.substring(with: range)
            if pythonKeywords.contains(token) {
                attr.addAttribute(.foregroundColor, value: keyword, range: range)
            }
        }
        regex(in: s, pattern: #"#[^\n]*"#)?.forEach { attr.addAttribute(.foregroundColor, value: comment, range: $0) }
    }

    // MARK: - JSON

    private static func applyJSON(_ attr: NSMutableAttributedString) {
        let s = attr.string as NSString
        regex(in: s, pattern: #""(?:\\.|[^"\\\n])*"\s*:"#)?.forEach { range in
            // key (without trailing colon)
            let keyRange = NSRange(location: range.location, length: range.length - 1)
            attr.addAttribute(.foregroundColor, value: funcC, range: keyRange)
        }
        regex(in: s, pattern: #""(?:\\.|[^"\\\n])*""#)?.forEach { range in
            // values that aren't keys (we already colored keys)
            if attr.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor != funcC {
                attr.addAttribute(.foregroundColor, value: string, range: range)
            }
        }
        regex(in: s, pattern: #"\b\d+(?:\.\d+)?\b"#)?.forEach { attr.addAttribute(.foregroundColor, value: number, range: $0) }
        regex(in: s, pattern: #"\b(?:true|false|null)\b"#)?.forEach { attr.addAttribute(.foregroundColor, value: keyword, range: $0) }
    }

    // MARK: - YAML

    private static func applyYAML(_ attr: NSMutableAttributedString) {
        let s = attr.string as NSString
        regex(in: s, pattern: #"^[ \t]*[A-Za-z0-9_\-]+(?=:)"#, options: [.anchorsMatchLines])?.forEach {
            attr.addAttribute(.foregroundColor, value: funcC, range: $0)
        }
        regex(in: s, pattern: #"#[^\n]*"#)?.forEach { attr.addAttribute(.foregroundColor, value: comment, range: $0) }
        regex(in: s, pattern: #""(?:\\.|[^"\\\n])*""#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
    }

    // MARK: - Markdown

    private static func applyMarkdown(_ attr: NSMutableAttributedString) {
        let s = attr.string as NSString
        regex(in: s, pattern: #"^#{1,6}\s+[^\n]*"#, options: [.anchorsMatchLines])?.forEach {
            attr.addAttribute(.foregroundColor, value: mdHead, range: $0)
        }
        regex(in: s, pattern: #"```[\s\S]*?```"#)?.forEach {
            attr.addAttribute(.foregroundColor, value: string, range: $0)
        }
        regex(in: s, pattern: #"`[^`\n]+`"#)?.forEach {
            attr.addAttribute(.foregroundColor, value: string, range: $0)
        }
        regex(in: s, pattern: #"\*\*[^*\n]+\*\*"#)?.forEach {
            attr.addAttribute(.foregroundColor, value: mdEmph, range: $0)
        }
    }

    // MARK: - Bash

    private static let bashKeywords: Set<String> = [
        "if","then","else","elif","fi","for","while","do","done","case","esac","function","return",
        "in","local","export","echo","cd","pwd","ls","mkdir","rm","cp","mv","cat","grep","sed","awk"
    ]
    private static func applyBash(_ attr: NSMutableAttributedString) {
        let s = attr.string as NSString
        regex(in: s, pattern: #""(?:\\.|[^"\\\n])*""#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
        regex(in: s, pattern: #"'[^'\n]*'"#)?.forEach { attr.addAttribute(.foregroundColor, value: string, range: $0) }
        regex(in: s, pattern: #"#[^\n]*"#)?.forEach { attr.addAttribute(.foregroundColor, value: comment, range: $0) }
        regex(in: s, pattern: #"\$\{?[A-Za-z_][A-Za-z_0-9]*\}?"#)?.forEach {
            attr.addAttribute(.foregroundColor, value: number, range: $0)
        }
        regex(in: s, pattern: #"\b[A-Za-z_]+\b"#)?.forEach { range in
            let token = s.substring(with: range)
            if bashKeywords.contains(token) { attr.addAttribute(.foregroundColor, value: keyword, range: range) }
        }
    }

    // MARK: - Helpers

    private static func regex(in s: NSString, pattern: String, options: NSRegularExpression.Options = []) -> [NSRange]? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return r.matches(in: s as String, range: NSRange(location: 0, length: s.length)).map { $0.range }
    }
}
