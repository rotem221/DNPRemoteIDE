import SwiftUI
import AppKit

struct WorkspaceView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            // `WorkspaceToolbar` (session info + bridge pill + Launch Claude
            // button) lived here above the editor tab strip. Removed at the
            // user's request — the title-bar `ProjectTopBar` already shows
            // the project context, sessions are reachable via the sidebar,
            // and the launch action is one ⌘P + "Launch Claude" away. The
            // editor tab strip is now the only chrome above the workspace
            // body, with split-screen and "+" controls inline.
            EditorTabBarView()
                .background(MacTheme.surface)
                .overlay(Divider(), alignment: .bottom)

            Group {
                switch workspace.workspacePane {
                case .terminal:    TerminalSplitContainer()
                case .editor(let file): CodeEditorView(file: file).id(file.id)
                case .pairing:     PairingCenterView()
                case .settings:    MacSettingsView()
                case .diagnostics: DiagnosticsView()
                case .github:      GitHubPaneView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MacTheme.background)
        // ⌘P / ⇧⌘P / ⌘K and the palette overlay both moved up to
        // `MacAppShellView` because the trigger now lives in the title-bar
        // row (`ProjectTopBar`). Preferences flow UP, so anchoring the
        // overlay above the trigger's parent is the only way the dropdown
        // can read the trigger frame and position itself below it.
    }
}

/// Captures the toolbar's palette-trigger frame so the dropdown overlay knows exactly
/// where to anchor itself. Reduce keeps the most recent value (only one trigger).
struct PaletteTriggerFrameKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Tab strip above the workspace center, styled like VS Code / Cursor.
/// Active tab has the **same** background as the editor body and an accent underline,
/// so it visually "lifts" out of the row of inactive tabs.
struct EditorTabBarView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @ObservedObject private var shortcuts = ShortcutsService.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // One tab per running session.
                    ForEach(workspace.sessions) { session in
                        sessionTab(session)
                    }
                    // One tab per open file.
                    ForEach(workspace.openFiles) { file in
                        tab(title: file.node.name, icon: file.node.iconName,
                            selected: workspace.workspacePane == .editor(file), closable: true,
                            onTap: { workspace.workspacePane = .editor(file); workspace.activeFile = file },
                            onClose: { workspace.closeFile(file) })
                    }
                    // Pairing / Settings / Diagnostics / GitHub used to
                    // appear here as their own tabs. Removed at the user's
                    // request — those are app-level panes the user reaches
                    // via the sidebar icon strip, not session-style tabs.
                    // The tab bar now only carries sessions and open files.
                    sessionsTrailingDropCatcher
                }
            }
            // Split-right and split-down sit INLINE — two adjacent
            // chrome buttons rather than a Menu — so the user sees both
            // affordances at a glance and can split in either direction
            // with one click. Both hide once 4 panes are visible
            // (`canAddPane` enforces the cap). Order: split-right →
            // split-down → "+ new session", left-to-right, matching the
            // mental model "extend the layout, then create a session".
            if workspace.selectedSessionId != nil && workspace.canAddPane {
                Button {
                    splitRight()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MacTheme.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("Split right — open another session next to this one")
                // Read the binding from `ShortcutsService` so a Settings →
                // Keyboard shortcuts rebind takes effect on the next render
                // without a relaunch.
                .keyboardShortcut(
                    shortcuts.combo(for: .splitRight).keyEquivalent,
                    modifiers: shortcuts.combo(for: .splitRight).eventModifiers
                )

                Button {
                    splitDown()
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MacTheme.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("Split down — open another session below this one")
            }
            // Persistent + button to spawn a new session WITHOUT splitting.
            // Stays available even when the layout is already at the
            // 4-pane cap so the user can keep creating background
            // sessions that surface in the sidebar's session list.
            Button { Task { await vm.newSession(in: workspace) } } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MacTheme.textSecondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help("New session")
            .padding(.trailing, 4)
        }
        // Pin the tab strip to 46pt so the bottom hairline lines up exactly
        // with the sidebar's `SidebarPanel` header to its left. The
        // sidebar header renders its 1pt divider as a SIBLING of the 44pt
        // header HStack (so total = 45pt), while our editor strip's
        // divider is an `.overlay` painted INSIDE the frame; the extra 2pt
        // here closes that small alignment gap and produces one
        // continuous chrome rail across the sidebar / workspace boundary.
        .frame(height: 46)
        .background(MacTheme.surface)
    }

    /// Enter split-pane mode: grow the host window if needed (so both panes
    /// land above their per-side minimum width on first split, instead of
    /// the user having to drag the window edge before they can read the
    /// secondary terminal), then ask the workspace controller to spawn a
    /// new session for the right-hand pane.
    private func splitRight() {
        ensureHostWindowFitsSplit()
        Task { await workspace.splitWithNewSession(direction: .horizontal) }
    }

    /// Vertical split — stacks a new pane below the focused one. We
    /// don't grow the host window here: vertical splits divide the
    /// existing height, and most workspace windows are tall enough to
    /// accommodate two stacked panes (480pt min × 2 = 960pt) without
    /// touching the window frame. If the window IS too short, the
    /// per-pane min height in `ResizableSplitView` clamps the divider
    /// and the user can resize the window manually.
    private func splitDown() {
        Task { await workspace.splitWithNewSession(direction: .vertical) }
    }

    /// Width threshold that gives both panes ~700pt + the divider — enough
    /// for two readable terminals with the file-explorer sidebar still
    /// visible. If the user's window is narrower, animate it out to this
    /// width before splitting.
    private func ensureHostWindowFitsSplit() {
        // Find the key window (the one the user just clicked into). On
        // multi-window setups, the workspace this view belongs to IS the key
        // window because the click happened in it.
        guard let win = NSApp.keyWindow else { return }
        let target: CGFloat = 1500
        let current = win.frame.width
        guard current < target else { return }
        let screenMax = win.screen?.visibleFrame.width ?? target
        let newWidth = min(target, screenMax - 24)
        var frame = win.frame
        let dx = newWidth - current
        // Anchor the right edge if growing past the right of the screen
        // would clip — otherwise keep the window's left edge fixed so the
        // user perceives the right side opening up.
        let visibleMaxX = win.screen?.visibleFrame.maxX ?? (frame.maxX + dx)
        if frame.maxX + dx > visibleMaxX {
            frame.origin.x = max(win.screen?.visibleFrame.minX ?? 0,
                                  visibleMaxX - newWidth)
        }
        frame.size.width = newWidth
        win.setFrame(frame, display: true, animate: true)
    }

    /// Tail drop catcher rendered at the end of the editor tab strip.
    /// Lets the user drop a dragged session row PAST the last tab to move
    /// it to the end — same affordance as the sidebar's bottom catcher.
    private var sessionsTrailingDropCatcher: some View {
        Color.clear
            .frame(width: 32, height: 44)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let sourceId = UUID(uuidString: raw) else { return false }
                vm.moveSession(sourceId, before: nil)
                return true
            }
    }

    @ViewBuilder
    private func sessionTab(_ session: Session) -> some View {
        let selected = (workspace.workspacePane == .terminal && workspace.selectedSessionId == session.id)
        ZStack(alignment: .bottom) {
            HStack(spacing: 8) {
                ContextRing(snapshot: workspace.contextSnapshots[session.id],
                            status: session.status,
                            isSelected: selected,
                            pendingApprovalCount: session.pendingApprovalCount,
                            isProcessing: vm.thinkingSessions.contains(session.id))
                    .frame(width: 18, height: 18)
                Text(session.title).font(.callout)
                    .foregroundStyle(selected ? MacTheme.textPrimary : MacTheme.textSecondary)
                    .lineLimit(1)
                Button { vm.requestClose(sessionId: session.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(selected ? MacTheme.textSecondary : MacTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close session")
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .background(selected ? MacTheme.background : MacTheme.surface)
            .overlay(alignment: .trailing) {
                Rectangle().frame(width: 0.5).foregroundStyle(MacTheme.border)
            }
            if selected {
                Rectangle().fill(MacTheme.accent).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Route through `switchToSession` so clicking a session
            // tab that isn't part of the current split layout collapses
            // the splits and shows the clicked session full-bleed —
            // otherwise the workspace stayed "stuck" rendering the old
            // panes and the click looked like it had no effect.
            workspace.switchToSession(session.id)
            workspace.workspacePane = .terminal
        }
        // Drag-to-reorder — same payload format `SessionsPanel` uses
        // (UUID string), so the two surfaces share `vm.moveSession`'s
        // ordering and stay in sync. Drop on another tab places this
        // session immediately before it.
        .draggable(session.id.uuidString) {
            SessionTabDragPreview(title: session.title)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let sourceId = UUID(uuidString: raw),
                  sourceId != session.id else { return false }
            vm.moveSession(sourceId, before: session.id)
            return true
        }
    }

    @ViewBuilder
    private func tab(title: String, icon: String, selected: Bool, closable: Bool,
                     onTap: @escaping () -> Void, onClose: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.callout)
                    .foregroundStyle(selected ? MacTheme.accent : MacTheme.textTertiary)
                Text(title).font(.callout)
                    .foregroundStyle(selected ? MacTheme.textPrimary : MacTheme.textSecondary)
                    .lineLimit(1)
                if closable {
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(selected ? MacTheme.textSecondary : MacTheme.textTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .background(selected ? MacTheme.background : MacTheme.surface)
            .overlay(alignment: .trailing) {
                if !selected {
                    Rectangle().frame(width: 0.5).foregroundStyle(MacTheme.border)
                }
            }

            // Accent strip under the active tab.
            if selected {
                Rectangle().fill(MacTheme.accent).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// `WorkspaceToolbar`, `StatusPill`, `ContextChip`, and `ConnectionPill`
// have all been removed. The toolbar that hosted them (session info +
// bridge pill + Launch Claude button) was deleted at the user's request;
// the project name now lives in `ProjectTopBar`, bridge status lives in
// `MacStatusBar`, and Launch Claude is reachable via the command palette
// (⌘P → "Launch Claude in Terminal"). None of these helper structs are
// referenced anywhere else in the codebase.

/// Compact drag preview for a session-tab reorder gesture in the editor
/// tab strip. Mirrors the shape of `SessionDragPreview` (sidebar) so the
/// two reorder UIs feel like the same gesture from two surfaces.
struct SessionTabDragPreview: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MacTheme.accent)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(MacTheme.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(MacTheme.accent.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}
