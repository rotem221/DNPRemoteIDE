import SwiftUI
import AppKit

// MARK: - Action catalogue
//
// `ShortcutAction` enumerates every user-rebindable command in the Mac app.
// Bindings live in `ShortcutsService`; consumers read the current combo by
// id (`shortcuts.combo(for: .newSession)`) and the rebind UI iterates the
// `allCases` to render a row per action.
//
// Adding an action: append a case below, give it a default in
// `ShortcutsService.factoryDefaults`, and (for SwiftUI commands) read the
// service in the View where the `.keyboardShortcut` modifier sits. For
// terminal-only actions like delete-to-start, the bindings are consumed
// directly inside `TerminalContainerView.performKeyEquivalent`.

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case newSession
    case closeProject
    case splitRight
    case commandPalette
    case toggleSettings
    case deleteLineStart      // terminal-only
    case deleteLineEnd        // terminal-only
    case moveLineStart        // terminal-only
    case moveLineEnd          // terminal-only

    var id: String { rawValue }

    /// Human title shown in the Settings list.
    var title: String {
        switch self {
        case .newSession:      return "New Session"
        case .closeProject:    return "Close Project"
        case .splitRight:      return "Split Right (Add Pane)"
        case .commandPalette:  return "Open Command Palette"
        case .toggleSettings:  return "Open Settings"
        case .deleteLineStart: return "Delete to Start of Line"
        case .deleteLineEnd:   return "Delete to End of Line"
        case .moveLineStart:   return "Cursor to Start of Line"
        case .moveLineEnd:     return "Cursor to End of Line"
        }
    }

    /// Section label for grouping in the Settings card.
    var category: Category {
        switch self {
        case .newSession, .closeProject, .splitRight: return .workspace
        case .commandPalette, .toggleSettings:        return .navigation
        case .deleteLineStart, .deleteLineEnd,
             .moveLineStart,   .moveLineEnd:           return .terminal
        }
    }

    enum Category: String, CaseIterable {
        case workspace = "Workspace"
        case navigation = "Navigation"
        case terminal = "Terminal"
    }
}

// MARK: - Key combo

/// A serialisable keyboard shortcut. Mirrors macOS event semantics: a base
/// key (single character or a named special key like `delete`) plus a set
/// of modifier flags. Renders to `⌘⇧D`-style strings for the UI and to
/// `KeyEquivalent` + `EventModifiers` for SwiftUI's `.keyboardShortcut`.
struct KeyCombo: Codable, Equatable, Hashable {
    var key: String          // "n", "delete", "leftarrow", "p"
    var modifiers: Modifiers // [.command, .shift]

    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift   = Modifiers(rawValue: 1 << 1)
        static let option  = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    /// Pretty-print: ⌘⇧D etc. Used in the Settings card and in the
    /// keyboard-recorder's "captured" preview.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += keyGlyph
        return s
    }

    private var keyGlyph: String {
        switch key.lowercased() {
        case "delete":      return "⌫"
        case "forwarddelete": return "⌦"
        case "leftarrow":   return "←"
        case "rightarrow":  return "→"
        case "uparrow":     return "↑"
        case "downarrow":   return "↓"
        case "return":      return "⏎"
        case "tab":         return "⇥"
        case "escape":      return "⎋"
        case "space":       return "␣"
        default:            return key.uppercased()
        }
    }

    /// Translate to SwiftUI primitives so consumers can wire
    /// `.keyboardShortcut(combo.keyEquivalent, modifiers: combo.eventModifiers)`.
    var keyEquivalent: KeyEquivalent {
        switch key.lowercased() {
        case "delete":        return .delete
        case "forwarddelete": return .deleteForward
        case "leftarrow":     return .leftArrow
        case "rightarrow":    return .rightArrow
        case "uparrow":       return .upArrow
        case "downarrow":     return .downArrow
        case "return":        return .return
        case "tab":           return .tab
        case "escape":        return .escape
        case "space":         return .space
        default:
            // Single-character keys ("n", "d", "p", "1"...) map to the
            // character itself. Always lowercase — SwiftUI matches against
            // the base character regardless of shift.
            if let c = key.lowercased().first {
                return KeyEquivalent(c)
            }
            return KeyEquivalent("?")
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift)   { m.insert(.shift) }
        if modifiers.contains(.option)  { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }

    /// True when this combo matches the given AppKit key event. Used by
    /// terminal-side handlers (`TerminalContainerView.performKeyEquivalent`)
    /// to recognise user-overridable terminal commands.
    func matches(event: NSEvent) -> Bool {
        let evMods: NSEvent.ModifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        let want: NSEvent.ModifierFlags = {
            var m: NSEvent.ModifierFlags = []
            if modifiers.contains(.command) { m.insert(.command) }
            if modifiers.contains(.shift)   { m.insert(.shift) }
            if modifiers.contains(.option)  { m.insert(.option) }
            if modifiers.contains(.control) { m.insert(.control) }
            return m
        }()
        guard evMods == want else { return false }
        // Special keys map to function-key codes; characters compare
        // case-insensitively against the event's chars-without-modifiers.
        switch key.lowercased() {
        case "delete":
            return event.keyCode == 51   // kVK_Delete
        case "forwarddelete":
            return event.keyCode == 117  // kVK_ForwardDelete
        case "leftarrow":   return event.keyCode == 123
        case "rightarrow":  return event.keyCode == 124
        case "uparrow":     return event.keyCode == 126
        case "downarrow":   return event.keyCode == 125
        case "return":      return event.keyCode == 36
        case "tab":         return event.keyCode == 48
        case "escape":      return event.keyCode == 53
        case "space":       return event.keyCode == 49
        default:
            return event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
        }
    }

    // MARK: - From AppKit

    /// Capture an `NSEvent` into a `KeyCombo`. Used by the rebind recorder
    /// — the user presses a key combo, we materialise it as a Combo, and
    /// store. Returns nil for unrecorded events (e.g. plain-letter
    /// keystrokes with no modifiers — those would clash with normal text
    /// input).
    static func from(event: NSEvent, allowUnmodified: Bool = false) -> KeyCombo? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var combo = Modifiers()
        if mods.contains(.command) { combo.insert(.command) }
        if mods.contains(.shift)   { combo.insert(.shift) }
        if mods.contains(.option)  { combo.insert(.option) }
        if mods.contains(.control) { combo.insert(.control) }
        if combo.isEmpty && !allowUnmodified { return nil }
        let key: String
        switch event.keyCode {
        case 51:  key = "delete"
        case 117: key = "forwarddelete"
        case 123: key = "leftarrow"
        case 124: key = "rightarrow"
        case 125: key = "downarrow"
        case 126: key = "uparrow"
        case 36:  key = "return"
        case 48:  key = "tab"
        case 53:  key = "escape"
        case 49:  key = "space"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let first = chars.first, first.isLetter || first.isNumber else {
                return nil
            }
            key = String(first)
        }
        return KeyCombo(key: key, modifiers: combo)
    }
}

// MARK: - Service

/// Process-wide shortcut registry. Holds the current binding for every
/// `ShortcutAction`, persists user overrides in UserDefaults, and exposes
/// a `@Published` map so SwiftUI views observing the service rebuild
/// `.keyboardShortcut` modifiers when the user rebinds something.
///
/// Access pattern:
///   `ShortcutsService.shared.combo(for: .newSession)` → current combo.
///   `ShortcutsService.shared.set(.newSession, to: combo)` → persist.
///   `ShortcutsService.shared.reset(.newSession)` → revert to factory.
@MainActor
final class ShortcutsService: ObservableObject {
    static let shared = ShortcutsService()

    @Published private(set) var bindings: [ShortcutAction: KeyCombo] = [:]

    private let storageKey = "dnp.mac.shortcuts.v1"

    private init() {
        load()
    }

    func combo(for action: ShortcutAction) -> KeyCombo {
        bindings[action] ?? Self.factoryDefaults[action]!
    }

    func set(_ action: ShortcutAction, to combo: KeyCombo) {
        bindings[action] = combo
        save()
    }

    func reset(_ action: ShortcutAction) {
        bindings[action] = Self.factoryDefaults[action]
        save()
    }

    func resetAll() {
        bindings = Self.factoryDefaults
        save()
    }

    /// Defaults — picked to match what the user already invoked from the
    /// existing menu/Commands wiring AND the conventional Mac readline
    /// keys for terminal text editing. Stored separately from the
    /// `bindings` map so `reset()` can repopulate without re-deriving.
    static let factoryDefaults: [ShortcutAction: KeyCombo] = [
        .newSession:      KeyCombo(key: "n", modifiers: [.command]),
        .closeProject:    KeyCombo(key: "w", modifiers: [.command, .shift]),
        .splitRight:      KeyCombo(key: "d", modifiers: [.command, .shift]),
        .commandPalette:  KeyCombo(key: "p", modifiers: [.command]),
        .toggleSettings:  KeyCombo(key: ",", modifiers: [.command]),
        .deleteLineStart: KeyCombo(key: "delete", modifiers: [.command]),
        .deleteLineEnd:   KeyCombo(key: "forwarddelete", modifiers: [.command]),
        .moveLineStart:   KeyCombo(key: "leftarrow", modifiers: [.command]),
        .moveLineEnd:     KeyCombo(key: "rightarrow", modifiers: [.command]),
    ]

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            // Merge factory + saved so newly-added actions inherit defaults.
            var merged = Self.factoryDefaults
            for (rawKey, combo) in saved {
                if let action = ShortcutAction(rawValue: rawKey) {
                    merged[action] = combo
                }
            }
            bindings = merged
        } else {
            bindings = Self.factoryDefaults
        }
    }

    private func save() {
        let serialisable = Dictionary(uniqueKeysWithValues:
            bindings.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(serialisable) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
