import SwiftUI
import AppKit

/// Top-level container for the workspace's terminal area. Recursively
/// renders the workspace's `paneTree` — leaves become `SessionPaneView`s,
/// splits become `ResizableSplitView`s with a draggable divider whose
/// orientation matches the split's `direction`.
///
/// Single-pane mode (`paneTree == nil`) bypasses the recursion entirely
/// and just renders `TerminalPaneView` fullbleed, exactly as before, so
/// the trivial path stays free of split chrome.
struct TerminalSplitContainer: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    var body: some View {
        Group {
            if let tree = workspace.paneTree {
                PaneTreeView(tree: tree)
                    .background(MacTheme.groupedBackground)
                    .onChange(of: workspace.sessions.map(\.id)) { _, _ in
                        // A session list mutation may have removed a leaf
                        // — re-prune so the layout doesn't render against
                        // a closed session.
                        workspace.pruneTreeIfStale()
                    }
            } else {
                // Single-pane mode — no split chrome, no per-pane header
                // overhead. Same view we used to render unconditionally.
                TerminalPaneView()
            }
        }
    }
}

/// Recursive renderer for `PaneTree`. Pure function over the tree —
/// every render reads the current tree out of the workspace, no local
/// per-node state. The fraction is bound through a custom `Binding`
/// that writes back into the tree at the matching split node.
private struct PaneTreeView: View {
    @EnvironmentObject var workspace: WorkspaceController
    let tree: PaneTree

    var body: some View {
        switch tree {
        case .leaf(let id):
            SessionPaneView(sessionId: id)
        case .split(let direction, let leading, let trailing, let fraction):
            // Bind the fraction directly into the workspace's tree.
            // We identify "which split node this view represents" by
            // capturing both subtrees by value at render time — full
            // subtree equality is unambiguous even for nested same-axis
            // splits (the prior `firstLeaf + direction` heuristic could
            // update two fractions from one drag in `[A | B] | C`).
            let frac = Binding<CGFloat>(
                get: { fraction },
                set: { newValue in
                    guard let t = workspace.paneTree else { return }
                    workspace.paneTree = t.settingFraction(newValue,
                                                            forSplitWithLeading: leading,
                                                            trailing: trailing)
                }
            )
            ResizableSplitView(direction: direction,
                               fraction: frac,
                               // Per-pane floor lowered from 280 to 200 so
                               // the workspace can host a horizontal split
                               // inside the new 640pt-wide window minimum
                               // (44 icon-strip + 0 collapsed sidebar +
                               // 200 + 6 divider + 200 = 450, well under
                               // 640). Vertical splits get the same floor
                               // so a 440pt-tall window can still split
                               // top/bottom (36 top bar + 200 + 6 + 200 +
                               // ~30 status = 472 — slightly over, so the
                               // split clamp will keep the divider parked
                               // at the upper limit until the user grows
                               // the window, exactly the right behaviour).
                               leadingMin: 200,
                               trailingMin: 200) {
                PaneTreeView(tree: leading)
            } trailing: {
                PaneTreeView(tree: trailing)
            }
        }
    }
}

/// One terminal pane — either single-pane mode or a leaf in a split tree.
/// Wraps `TerminalEmulatorView` with a thin header strip showing the
/// session title + a session-picker menu (so the user can swap which
/// session this pane displays without leaving split mode) + per-pane
/// "Split right", "Split down", and close (✕) controls.
///
/// The close button hides when the workspace is in single-pane mode —
/// closing the only pane would leave the workspace empty, which the
/// user gets to from the session list / "Close session" menu, not
/// from a split-pane affordance.
struct SessionPaneView: View {
    let sessionId: UUID

    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    private var isFocused: Bool {
        workspace.selectedSessionId == sessionId
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
                .frame(height: 30)
                .background(MacTheme.surface)
                .overlay(Divider(), alignment: .bottom)
            terminalBody
        }
        // Tap anywhere in the pane to focus it for keyboard shortcuts —
        // "Split right" / "Split down" route through the focused leaf.
        .contentShape(Rectangle())
        .onTapGesture {
            if workspace.selectedSessionId != sessionId {
                workspace.selectedSessionId = sessionId
            }
        }
        // Subtle focus ring on the active pane when there are multiple
        // panes — helps the user see which one will receive the next
        // split / close action. Hidden in single-pane mode.
        .overlay(
            Rectangle()
                .strokeBorder(MacTheme.accent.opacity(workspace.isSplitActive && isFocused ? 0.55 : 0),
                              lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var session: Session? {
        workspace.sessions.first(where: { $0.id == sessionId })
    }

    @ViewBuilder
    private var paneHeader: some View {
        HStack(spacing: 8) {
            sessionPickerMenu
            Spacer()

            // Per-pane split controls. `canAddPane` guards the 4-pane
            // cap — we hide the buttons rather than disabling them so
            // the header stays visually clean in the saturated case.
            if workspace.canAddPane {
                Button {
                    workspace.selectedSessionId = sessionId
                    Task { await workspace.splitWithNewSession(direction: .horizontal) }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MacTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Split right")

                Button {
                    workspace.selectedSessionId = sessionId
                    Task { await workspace.splitWithNewSession(direction: .vertical) }
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MacTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Split down")
            }

            // Close button — routes through `requestClose` so the same
            // "Close <session title>?" warning the sidebar uses appears
            // here too. The user can opt out of the prompt globally via
            // Settings → General → "Skip close confirmation"; that
            // setting is checked inside `requestClose` so a single
            // toggle gates every close path consistently. Once the
            // session is gone, `pruneTreeIfStale` collapses the leaf
            // out of the tree automatically.
            //
            // Hidden in single-pane mode so a stray click doesn't end
            // the only visible session — closing it that way is
            // intentional and goes through the sidebar's session list.
            if workspace.isSplitActive {
                Button {
                    vm.requestClose(sessionId: sessionId)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MacTheme.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(MacTheme.surfaceAlt, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close session")
            }
        }
        .padding(.horizontal, 10)
    }

    /// Session-picker menu split out of `paneHeader` because Swift's
    /// generic-builder type-checker chokes on the combined Menu(label+content)
    /// + ForEach + conditional disabled() expression in one body.
    private var sessionPickerMenu: some View {
        Menu {
            sessionPickerItems
            Divider()
            Button {
                Task {
                    let new = await vm.newSession(in: workspace)
                    retarget(to: new.id)
                }
            } label: {
                Label("New session here", systemImage: "plus")
            }
        } label: {
            sessionPickerLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var sessionPickerItems: some View {
        let live = workspace.sessions.filter { $0.status != .ended }
        // Other panes in the same tree can't display the same session
        // twice — disable rows already rendered elsewhere.
        let usedElsewhere = Set(
            (workspace.paneTree?.leaves ?? []).filter { $0 != sessionId }
        )
        ForEach(live) { s in
            let isCurrent = s.id == sessionId
            let disabled = usedElsewhere.contains(s.id)
            Button {
                retarget(to: s.id)
            } label: {
                Label(s.title,
                      systemImage: isCurrent ? "checkmark" : "terminal")
            }
            .disabled(disabled)
        }
    }

    private var sessionPickerLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
            Text(session?.title ?? "—")
                .font(.callout.weight(.medium))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(MacTheme.textTertiary)
        }
    }

    /// Replace this pane's session by swapping the leaf in the tree, or
    /// — in single-pane mode — just retargeting the workspace's
    /// `selectedSessionId`.
    private func retarget(to id: UUID) {
        if let tree = workspace.paneTree {
            workspace.paneTree = tree.replacing(sessionId, with: .leaf(id))
            if workspace.selectedSessionId == sessionId {
                workspace.selectedSessionId = id
            }
        } else {
            workspace.selectedSessionId = id
        }
    }

    private var statusDotColor: Color {
        guard let s = session else { return MacTheme.textTertiary }
        switch s.status {
        case .running:           return MacTheme.success
        case .waitingForApproval: return MacTheme.warning
        case .crashed, .disconnected: return MacTheme.danger
        case .ended:             return MacTheme.textTertiary
        default:                  return MacTheme.accent
        }
    }

    @ViewBuilder
    private var terminalBody: some View {
        if let term = vm.terminalSessions[sessionId] {
            TerminalEmulatorView(session: term)
                .id(sessionId)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MacTheme.groupedBackground)
        } else {
            VStack {
                Spacer()
                Text("Session not running")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MacTheme.groupedBackground)
        }
    }
}

/// Generic two-child split view supporting BOTH orientations. The same
/// component used to be horizontal-only (mirroring AppKit's `HSplitView`);
/// it now switches between an HStack and a VStack based on the
/// `direction` parameter and pushes the appropriate `NSCursor` on hover
/// (resize-left-right vs resize-up-down).
///
/// Why a custom implementation instead of SwiftUI's `HSplitView`/
/// `VSplitView`: those work but have historically dropped frames during
/// drag, don't expose their split fraction, and ignore `.animation()`
/// modifiers. A small custom version reads more cleanly, gives us full
/// control of the cursor, and stores the split as a normalised fraction
/// so the layout reflows naturally when the host window itself resizes.
struct ResizableSplitView<Leading: View, Trailing: View>: View {
    let direction: PaneOrientation
    @Binding var fraction: CGFloat
    let leadingMin: CGFloat
    let trailingMin: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    private let dividerSize: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = direction == .horizontal ? geo.size.width : geo.size.height
            let maxLeading = max(leadingMin,
                                 total - trailingMin - dividerSize)
            let proposed = total * fraction
            let leadingExtent: CGFloat = min(maxLeading, max(leadingMin, proposed))
            let trailingExtent = max(trailingMin, total - leadingExtent - dividerSize)

            switch direction {
            case .horizontal:
                HStack(spacing: 0) {
                    leading.frame(width: leadingExtent)
                    divider(total: total, leadingExtent: leadingExtent)
                    trailing.frame(width: trailingExtent)
                }
            case .vertical:
                VStack(spacing: 0) {
                    leading.frame(height: leadingExtent)
                    divider(total: total, leadingExtent: leadingExtent)
                    trailing.frame(height: trailingExtent)
                }
            }
        }
    }

    private func divider(total: CGFloat, leadingExtent: CGFloat) -> some View {
        Rectangle()
            .fill(MacTheme.border)
            .frame(width: direction == .horizontal ? dividerSize : nil,
                   height: direction == .vertical ? dividerSize : nil)
            .overlay(dragGripper)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (direction == .horizontal
                        ? NSCursor.resizeLeftRight
                        : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard total > leadingMin + trailingMin + dividerSize else { return }
                        let delta = direction == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let next = leadingExtent + delta
                        let clamped = max(leadingMin,
                                          min(total - trailingMin - dividerSize, next))
                        fraction = clamped / total
                    }
            )
    }

    /// 3-dot drag affordance — orientation matches the divider so the
    /// gripper always reads as "you can drag along the long edge."
    private var dragGripper: some View {
        Group {
            switch direction {
            case .horizontal:
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(MacTheme.textTertiary.opacity(0.6))
                            .frame(width: 2, height: 2)
                    }
                }
            case .vertical:
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(MacTheme.textTertiary.opacity(0.6))
                            .frame(width: 2, height: 2)
                    }
                }
            }
        }
    }
}
