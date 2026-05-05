import SwiftUI
import AppKit

/// Settings card listing every `ShortcutAction` with its current binding,
/// grouped by category. Each row shows: title (left) · current combo
/// (right) · Edit + Reset buttons. Clicking Edit puts the row into
/// "recording" mode — the next valid key press is captured into a new
/// `KeyCombo` and persisted via `ShortcutsService`. The visual model is
/// modelled after Cursor / Xcode's Key Bindings panel.
struct ShortcutsCardView: View {
    @ObservedObject var shortcuts: ShortcutsService = .shared
    @State private var recordingAction: ShortcutAction?
    @State private var conflictMessage: String?

    var body: some View {
        SettingsCard(title: "Keyboard shortcuts", icon: "keyboard") {
            HStack(spacing: 8) {
                Text("Click a shortcut to rebind. Click again or press Escape to cancel.")
                    .font(.caption).foregroundStyle(MacTheme.textTertiary)
                Spacer()
                Button("Reset all") { shortcuts.resetAll() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let msg = conflictMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(MacTheme.warning)
                    Text(msg).font(.caption).foregroundStyle(MacTheme.warning)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Divider().background(MacTheme.border).padding(.vertical, 2)
            ForEach(ShortcutAction.Category.allCases, id: \.self) { category in
                let actions = ShortcutAction.allCases.filter { $0.category == category }
                if !actions.isEmpty {
                    categoryHeader(category)
                    ForEach(actions) { action in
                        shortcutRow(action)
                    }
                }
            }
        }
    }

    private func categoryHeader(_ c: ShortcutAction.Category) -> some View {
        Text(c.rawValue.uppercased())
            .font(.caption2.bold())
            .tracking(0.6)
            .foregroundStyle(MacTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    @ViewBuilder
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let combo = shortcuts.combo(for: action)
        let isRecording = (recordingAction == action)
        let isDefault   = combo == ShortcutsService.factoryDefaults[action]
        HStack(spacing: 10) {
            Text(action.title)
                .font(.callout)
                .foregroundStyle(MacTheme.textPrimary)
            Spacer()
            // Combo pill — when recording, swap for the recorder.
            if isRecording {
                ShortcutRecorder(currentDisplay: combo.display) { captured in
                    handleCaptured(captured, for: action)
                } cancel: {
                    recordingAction = nil
                }
                .frame(width: 140)
            } else {
                Button {
                    recordingAction = action
                    conflictMessage = nil
                } label: {
                    Text(combo.display)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(MacTheme.textPrimary)
                        .frame(minWidth: 92, alignment: .center)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(MacTheme.border.opacity(0.5), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Click to rebind \(action.title)")
            }
            // Reset to default — only enabled when the binding has been
            // changed from factory.
            Button {
                shortcuts.reset(action)
                conflictMessage = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isDefault ? MacTheme.textTertiary.opacity(0.4)
                                                : MacTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isDefault)
            .help("Restore default")
        }
        .padding(.vertical, 5)
    }

    /// Apply a captured combo to the recording action, with a basic
    /// conflict check — if another action already uses this combo, surface
    /// a warning AND override the previous binding (Cursor's behaviour:
    /// the latest assignment wins). The user can fix the displaced action
    /// by rebinding it from its row.
    private func handleCaptured(_ combo: KeyCombo, for action: ShortcutAction) {
        let conflict = ShortcutAction.allCases.first {
            $0 != action && shortcuts.combo(for: $0) == combo
        }
        shortcuts.set(action, to: combo)
        recordingAction = nil
        if let conflict = conflict {
            conflictMessage = "Replaced previous binding for “\(conflict.title)”."
        }
    }
}

// MARK: - Recorder

/// Inline key-combo recorder. Becomes first responder when it appears,
/// captures the next valid `keyDown`, and reports the result via the
/// `onCapture` callback. Escape cancels.
private struct ShortcutRecorder: NSViewRepresentable {
    let currentDisplay: String
    let onCapture: (KeyCombo) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onCapture = onCapture
        v.onCancel  = cancel
        v.placeholder = currentDisplay
        return v
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.placeholder = currentDisplay
        nsView.onCapture = onCapture
        nsView.onCancel  = cancel
        nsView.needsDisplay = true
    }

    final class RecorderView: NSView {
        var onCapture: ((KeyCombo) -> Void)?
        var onCancel:  (() -> Void)?
        var placeholder: String = ""

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Auto-focus on appear so the user can press their combo
            // without an extra click. Defer one runloop so the window's
            // first-responder chain is fully wired up.
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            // Escape cancels recording.
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            if let combo = KeyCombo.from(event: event) {
                onCapture?(combo)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let bg = NSColor.controlAccentColor.withAlphaComponent(0.18)
            let border = NSColor.controlAccentColor.withAlphaComponent(0.7)
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 6, yRadius: 6)
            bg.setFill(); path.fill()
            border.setStroke(); path.stroke()
            let label = NSAttributedString(string: "Press a combo…",
                                           attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                   y: (bounds.height - size.height) / 2))
        }
    }
}
