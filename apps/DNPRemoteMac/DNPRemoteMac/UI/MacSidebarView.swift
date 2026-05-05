import SwiftUI

/// Sidebar = a fixed 44pt icon strip (`MacSidebarIconStrip`) + a collapsible content panel
/// (`MacSidebarContent`). The two render side-by-side from `MacAppShellView`, with ONLY
/// the content panel inside the NSSplitView pane — the icon strip stays put regardless of
/// whether the user opens or closes the panel, exactly like Xcode's left-strip behavior.
/// `MacSidebarView` here is kept as a back-compat composition for any preview / test that
/// still embeds the whole sidebar in one view.
struct MacSidebarView: View {
    var body: some View {
        HStack(spacing: 0) {
            MacSidebarIconStrip()
            if true { MacSidebarContent() }
        }
    }
}

/// The persistent 44pt left strip — icons + chevron. Always visible. NEVER affected by the
/// sidebar's expand/collapse state. Lives outside the NSSplitView in `MacAppShellView` so
/// the toggle never moves it, never resizes it, and never re-renders it during a divider
/// drag.
struct MacSidebarIconStrip: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @ObservedObject private var orderService = SidebarOrderService.shared

    var body: some View {
        VStack(spacing: 4) {
            // Brand mark used to live here — moved up to the title bar
            // (`ProjectTopBar`) so the wordmark sits on the chrome row
            // alongside the project name + traffic lights, matching the
            // standard macOS app-header pattern. The strip now starts
            // directly with the first tab.
            ForEach(orderService.topOrder) { tab in
                iconButton(tab, group: .top)
            }
            Spacer()
            ForEach(orderService.bottomOrder) { tab in
                iconButton(tab, group: .bottom)
            }
            // Hairline separator — the sidebar-toggle below is a chrome
            // control, not a navigation tab, so we visually divide it
            // from the bottom cluster (Settings is the last tab above
            // this line). 16pt wide so it reads as a discrete divider
            // rather than reaching the strip's full width.
            Rectangle()
                .fill(MacTheme.border.opacity(0.55))
                .frame(width: 16, height: 1)
                .padding(.top, 4)
                .padding(.bottom, 2)
            SidebarToggleButton()
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        // Animate row reorders so dragging icon A onto icon B's slot makes
        // the rest of the strip slide instead of snapping discontinuously.
        .animation(.snappy(duration: 0.22), value: orderService.topOrder)
        .animation(.snappy(duration: 0.22), value: orderService.bottomOrder)
        .background(.ultraThinMaterial)
    }

    private func iconButton(_ tab: SidebarTab, group: SidebarOrderService.Group) -> some View {
        SidebarIconButton(tab: tab, group: group, vm: vm, workspace: workspace)
    }
}

/// Dedicated open/close button for the sidebar's content panel — the wider
/// pane that hosts Files / Sessions / Events / etc. and slides open beside
/// the 44pt icon strip. Sits at the very bottom of the strip, BELOW the
/// "Settings" cluster, separated by a thin hairline so it reads as chrome
/// (not as another tab). Re-tapping the active tab still toggles the panel
/// for users who learned that gesture; this button just makes the same
/// action discoverable.
///
/// Visual contract — same as the rest of the strip after the recent polish
/// pass: no rounded background chip, no border, only the icon's tint
/// changes between idle / hover / active. A `symbolEffect(.bounce)` fires
/// on every flip so the click reads as a positive state change rather
/// than a silent snap.
struct SidebarToggleButton: View {
    @EnvironmentObject var workspace: WorkspaceController
    @State private var hovering = false

    var body: some View {
        let isOpen = workspace.sidebarExpanded
        Image(systemName: "sidebar.left")
            .font(.system(size: 16, weight: .medium))
            // Mirrors `SidebarIconButton`'s tint logic: full accent when
            // "active" (sidebar open), partial accent on hover so the
            // cursor-follows-the-icon affordance is visible before click,
            // textSecondary at rest.
            .foregroundStyle(isOpen
                             ? MacTheme.accent
                             : (hovering ? MacTheme.accent.opacity(0.85)
                                          : MacTheme.textSecondary))
            // Bounce on every toggle so the user gets explicit feedback
            // — the actual content pane snaps (NSSplitView design choice
            // documented in `applyDividerLayout`), so the bounce is what
            // sells the click as "yes, that did something".
            .symbolEffect(.bounce, options: .speed(1.6), value: isOpen)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .onTapGesture {
                // `withAnimation` here drives the icon's tint crossfade
                // (the accent ↔ secondary transition) along with any
                // SwiftUI views downstream that observe `sidebarExpanded`.
                // The split-view itself snaps regardless — see
                // `applyDividerLayout` for why.
                withAnimation(.snappy(duration: 0.22)) {
                    workspace.sidebarExpanded.toggle()
                }
            }
            .onHover { hovering = $0 }
            .help(isOpen ? "Hide sidebar" : "Show sidebar")
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.18), value: isOpen)
            .accessibilityLabel(isOpen ? "Hide sidebar" : "Show sidebar")
    }
}

/// Static brand mark used in the title bar (and historically at the top of the sidebar
/// icon strip). Non-interactive. Rendered with `.original` rendering mode so the
/// artwork's own colors show through unchanged. Size is parameterized so the same view
/// can sit in the 36pt title-bar (smaller) or any other host that needs a different
/// scale without forking the asset binding.
struct DNPSidebarLogoMark: View {
    var size: CGFloat = 24
    var body: some View {
        Image("SidebarLogo")
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Single icon-strip button. Lives as a real `View` (not a static function) so
/// SwiftUI can persist `@State private var hovering` across renders — that's how
/// the soft hover highlight stays visible while the cursor sits on the icon, and
/// disappears the instant it leaves. Native macOS sidebars (Xcode, Finder, Music)
/// all do this; without it the icon strip felt static and "dead" on hover.
struct SidebarIconButton: View {
    let tab: SidebarTab
    let group: SidebarOrderService.Group
    @ObservedObject var vm: MacAppViewModel
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject private var orderService = SidebarOrderService.shared
    @State private var hovering = false
    /// Becomes true once the cursor has been over the icon for ≥1s —
    /// drives the in-app tooltip popover. Reset to false the instant the
    /// cursor leaves so the tooltip can't linger.
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        let active = MacSidebarHelpers.isActive(tab, vm: vm, workspace: workspace)
        ZStack(alignment: .topTrailing) {
            ZStack {
                // No background fill in any state. Selection AND hover are
                // both communicated purely through the icon's color so the
                // strip stays minimal — no square wash, no rounded chip,
                // just an icon that brightens on hover and locks at full
                // accent when the slot is selected.
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .medium))
                    // Icon priority: active wins over hover so a hovered-
                    // selected item stays at full accent rather than dimming
                    // to the hover preview tone.
                    .foregroundStyle(active
                                     ? MacTheme.accent
                                     : (hovering ? MacTheme.accent.opacity(0.85)
                                                  : MacTheme.textSecondary))
            }
            .frame(width: 36, height: 36)
            // Smooth crossfade between idle / hover / active so the wash
            // doesn't pop in and out abruptly when the user sweeps the
            // cursor over the strip.
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.18), value: active)
            if let badge = MacSidebarHelpers.badge(for: tab, vm: vm, workspace: workspace), badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(MacTheme.warning, in: Capsule())
                    .offset(x: 4, y: -2)
            }
        }
        .frame(width: 36, height: 36)
        // Use `Rectangle` content-shape on the whole 36×36 frame so taps,
        // drags AND drops register on the empty whitespace around the
        // 16pt SF Symbol — without this, the dead area between the icon
        // and the chip's border ate gestures.
        .contentShape(Rectangle())
        // Plain tap → switch the workspace tab. Replaces the previous
        // `Button { … }` wrapper, which was intercepting the press
        // gesture on the bottom cluster and blocking `.draggable` from
        // ever engaging — the visible bug the user reported.
        .onTapGesture {
            MacSidebarHelpers.handleTabTap(tab, vm: vm, workspace: workspace)
        }
        .onHover { isHovering in
            hovering = isHovering
            tooltipTask?.cancel()
            if isHovering {
                // Show the in-app tooltip after exactly 1 second of hover.
                tooltipTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        // The tooltip popover — appears to the right of the strip so it
        // doesn't cover other icons. Plain text on a translucent capsule.
        // Note: native `.help(tab.title)` was REMOVED — the system
        // tooltip's ~2s default delay was racing this 1s popover and
        // making the user see what felt like a 2-second tooltip.
        .popover(isPresented: $showTooltip, arrowEdge: .trailing) {
            Text(tab.title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .allowsHitTesting(false)
        }
        // Drag-reorder only when this tab is reorderable. Home and the
        // entire bottom cluster (GitHub / Pairing / Diagnostics /
        // Settings) opt out — those positions are pinned. Reorderable
        // tabs (Files / Sessions / Events / History / Git) get the live
        // swap-on-hover + drop-to-commit gestures.
        .modifier(ReorderGesturesIfNeeded(
            tab: tab,
            group: group,
            orderService: orderService
        ))
        .onDisappear { tooltipTask?.cancel() }
    }
}

/// Conditional drag-reorder gesture applier. Refused for pinned tabs
/// (Home + bottom cluster) so they neither initiate a drag nor accept a
/// drop — the only way to keep their slot fixed regardless of where
/// other reorderable tabs end up. Reorderable tabs get the full live-
/// reorder gesture stack: `.onDrag` writes the source into the order
/// service for `isTargeted` to read, drop confirms, and the closures
/// reject any move whose source OR target is non-reorderable as a
/// belt-and-suspenders defence (the UI already prevents this, but a
/// stale drag payload from a swap-mode flip could still try).
private struct ReorderGesturesIfNeeded: ViewModifier {
    let tab: SidebarTab
    let group: SidebarOrderService.Group
    let orderService: SidebarOrderService

    func body(content: Content) -> some View {
        if tab.isReorderable {
            content
                .dropDestination(for: String.self) { items, _ in
                    SidebarOrderService.shared.draggingTab = nil
                    guard let raw = items.first,
                          let source = SidebarTab(rawValue: raw),
                          source.isReorderable,
                          source != tab else { return false }
                    withAnimation(.snappy(duration: 0.22)) {
                        orderService.move(source, before: tab, group: group)
                    }
                    return true
                } isTargeted: { isOver in
                    guard isOver,
                          let source = SidebarOrderService.shared.draggingTab,
                          source.isReorderable,
                          source != tab else { return }
                    withAnimation(.snappy(duration: 0.18)) {
                        orderService.move(source, before: tab, group: group)
                    }
                }
                .onDrag {
                    SidebarOrderService.shared.draggingTab = tab
                    return NSItemProvider(object: tab.rawValue as NSString)
                } preview: {
                    SidebarIconDragPreview(tab: tab)
                }
        } else {
            // Pinned tab — leave content untouched. No `.onDrag` means
            // the cursor can't initiate a drag from this icon at all,
            // and no `.dropDestination` means dropping ANOTHER tab onto
            // this slot is rejected by AppKit (cursor shows the "no"
            // icon), so the pinned slot is genuinely immovable.
            content
        }
    }
}

/// Compact drag-preview chip rendered while a sidebar icon is being
/// reordered. Mirrors the look of `SessionDragPreview` and friends so the
/// reorder gesture reads consistently across every drag-reorder surface.
private struct SidebarIconDragPreview: View {
    let tab: SidebarTab

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MacTheme.accent)
            Text(tab.title)
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

/// Persistent ordering of the sidebar icon strip. Two independent groups
/// so the top cluster (Home / Files / Sessions / Events / History / Git)
/// and the bottom cluster (GitHub / Pairing / Diagnostics / Settings) can
/// be reordered without ever colliding — drag-reorder is constrained to
/// within the SAME group by `SidebarIconButton.dropDestination`.
///
/// The order is shared across every open project window via the
/// `.shared` singleton + `@Published` observation, so a drag in window A
/// updates the strip in window B on the next render. Reorders persist
/// to UserDefaults the moment they happen; "Reset" wipes the keys and
/// snaps both groups back to `SidebarTab.defaultTopItems` /
/// `defaultBottomItems`.
// Not `@MainActor`-isolated so static accessors like `SidebarTab.topItems`
// — which read `SidebarOrderService.shared.topOrder` — stay callable from
// any context. All mutations land via the SwiftUI drag-reorder /
// Settings-reset code paths, which run on the main actor anyway, so the
// `@Published` writes still happen on a single thread in practice.
final class SidebarOrderService: ObservableObject {
    static let shared = SidebarOrderService()

    enum Group { case top, bottom }

    @Published private(set) var topOrder: [SidebarTab]
    @Published private(set) var bottomOrder: [SidebarTab]

    /// Tab currently being dragged in the sidebar — set by `.onDrag` at
    /// drag start and read by sibling rows' `isTargeted` callbacks so we
    /// can swap positions in real time as the cursor moves over each
    /// neighbour. SwiftUI doesn't expose the drag payload from inside
    /// `isTargeted`, hence this side channel. Reset to nil after the
    /// drop completes (success or cancel) to clean up.
    var draggingTab: SidebarTab?

    private static let topKey = "dnp.mac.sidebar.topOrder"
    private static let bottomKey = "dnp.mac.sidebar.bottomOrder"

    private init() {
        let savedTop = UserDefaults.standard.array(forKey: Self.topKey) as? [String] ?? []
        let savedBottom = UserDefaults.standard.array(forKey: Self.bottomKey) as? [String] ?? []
        self.topOrder = Self.merge(saved: savedTop, defaults: SidebarTab.defaultTopItems)
        self.bottomOrder = Self.merge(saved: savedBottom, defaults: SidebarTab.defaultBottomItems)
    }

    /// Reorder `source` so it lands immediately before `target`. If both
    /// belong to `group` the call is a single-op move; otherwise it's a
    /// no-op (cross-cluster drops are rejected at the UI layer too).
    func move(_ source: SidebarTab, before target: SidebarTab, group: Group) {
        switch group {
        case .top:
            move(source, before: target, in: &topOrder)
            persist(topOrder, key: Self.topKey)
        case .bottom:
            move(source, before: target, in: &bottomOrder)
            persist(bottomOrder, key: Self.bottomKey)
        }
    }

    /// Wipe persisted ordering and snap both groups back to the
    /// hard-coded factory order. The Settings "Reset sidebar order"
    /// button calls this; the singleton's `@Published` properties trigger
    /// a re-render in every open window on the next runloop tick.
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.topKey)
        UserDefaults.standard.removeObject(forKey: Self.bottomKey)
        topOrder = SidebarTab.defaultTopItems
        bottomOrder = SidebarTab.defaultBottomItems
    }

    private func move(_ source: SidebarTab, before target: SidebarTab,
                       in array: inout [SidebarTab]) {
        // Defence-in-depth: never move a pinned tab and never drop ON a
        // pinned tab's slot. The UI's `ReorderGesturesIfNeeded` already
        // refuses to wire drag/drop for pinned tabs, but a stale
        // `draggingTab` from a previous gesture could in theory leak
        // into a fresh drop and try to move Home — this guard stops
        // that cold.
        guard source.isReorderable, target.isReorderable else { return }
        guard let from = array.firstIndex(of: source),
              array.contains(target),
              source != target else { return }
        let item = array.remove(at: from)
        if let to = array.firstIndex(of: target) {
            array.insert(item, at: to)
        } else {
            array.append(item)
        }
    }

    private func persist(_ order: [SidebarTab], key: String) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: key)
    }

    /// Combine the persisted order with the current factory list:
    ///   • drop persisted entries whose factory tab no longer exists
    ///     (e.g. an old `.search` value left over from a prior version);
    ///   • append any factory tabs that weren't in the persisted list,
    ///     so an app update that adds a new tab never leaves the user
    ///     looking at a half-empty rail.
    private static func merge(saved: [String], defaults: [SidebarTab]) -> [SidebarTab] {
        let validSaved = saved.compactMap(SidebarTab.init(rawValue:))
                              .filter { defaults.contains($0) }
        // Preserve user's saved order, then append any new defaults at end.
        let missing = defaults.filter { !validSaved.contains($0) }
        return validSaved + missing
    }
}

/// Owner-only namespace for icon-strip helpers — `MacSidebarContent` and
/// `MacSidebarIconStrip` share these but live in separate structs. Helpers are scoped to
/// **this window's** workspace (per-window state lives on `WorkspaceController`); the
/// `vm` reference is still passed through because some sub-views down the tree (e.g. the
/// session row's terminal status) read globally-pooled session data.
@MainActor
enum MacSidebarHelpers {
    // `iconButton` factory was removed — `MacSidebarIconStrip` instantiates
    // `SidebarIconButton` directly so it can pass the icon's group (top vs
    // bottom) through to the drag-reorder logic.

    static func handleTabTap(_ tab: SidebarTab,
                              vm: MacAppViewModel,
                              workspace: WorkspaceController) {
        switch tab {
        case .home:
            workspace.workspacePane = .terminal
        case .files, .sessions, .events, .history, .git:
            if workspace.sidebarTab == tab && workspace.sidebarExpanded {
                workspace.sidebarExpanded = false
            } else {
                workspace.sidebarTab = tab
                workspace.sidebarExpanded = true
            }
        case .pairing:
            workspace.workspacePane = (workspace.workspacePane == .pairing) ? .terminal : .pairing
        case .settings:
            workspace.workspacePane = (workspace.workspacePane == .settings) ? .terminal : .settings
        case .diagnostics:
            workspace.workspacePane = (workspace.workspacePane == .diagnostics) ? .terminal : .diagnostics
        case .github:
            workspace.workspacePane = (workspace.workspacePane == .github) ? .terminal : .github
        }
    }

    static func isActive(_ tab: SidebarTab,
                          vm: MacAppViewModel,
                          workspace: WorkspaceController) -> Bool {
        switch tab {
        case .home:                                    return workspace.workspacePane == .terminal
        case .files, .sessions, .events, .history, .git: return workspace.sidebarTab == tab && workspace.sidebarExpanded
        case .pairing:                                 return workspace.workspacePane == .pairing
        case .settings:                                return workspace.workspacePane == .settings
        case .diagnostics:                             return workspace.workspacePane == .diagnostics
        case .github:                                  return workspace.workspacePane == .github
        }
    }

    /// Sidebar badge — counts are SCOPED to the workspace's project so window B doesn't
    /// inflate window A's pending-approval count, and vice versa.
    static func badge(for tab: SidebarTab,
                       vm: MacAppViewModel,
                       workspace: WorkspaceController) -> Int? {
        switch tab {
        case .events:
            // No badge for Events — the per-session event count is already
            // displayed inside the panel header (see `SessionFeedPaneView`'s
            // trailing slot), and showing the same number here duplicates the
            // History badge whenever the project has only one session. This
            // slot is reserved for genuinely "needs attention" cues, which
            // for the per-session feed is just the panel itself opening.
            return nil
        case .history:
            // Sum across every session in this workspace's project so the
            // badge reflects the total project-wide event count, not just
            // the currently-selected session.
            return workspace.feed.values.reduce(0) { $0 + $1.count }
        case .sessions: return workspace.pendingApprovals.count
        default:        return nil
        }
    }
}

/// The collapsible content panel — Files / Sessions / Events / Git. Rendered as the
/// LEADING pane of the NSSplitView. When the user collapses the sidebar, this is the
/// only thing that disappears; the icon strip remains.
struct MacSidebarContent: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Solid surface fill — was `.ultraThinMaterial`, but the
            // material's blur introduced a faint vertical gradient-like
            // tint when the panel slid open (the blur samples the layer
            // beneath, which itself fades to the chrome darker tone).
            // A flat `surface` color renders as a clean uniform panel,
            // matching the workspace pane on the other side of the split.
            .background(MacTheme.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.sidebarTab {
        case .home:     EmptyView()        // Home collapses the panel — never reached.
        case .files:    FileExplorerView()
        case .sessions: SessionsPanel()
        case .events:   SessionFeedPaneView()
        case .history:  ProjectHistoryPaneView()
        case .git:      GitPanel()
        case .github, .pairing, .settings, .diagnostics: EmptyView()
        }
    }
}

// MARK: - Shared sidebar panel chrome

/// Common chrome wrapped around every sidebar tab's body so Files / Sessions / Events /
/// Search / Git all look identical: same header padding, same icon + title typography, same
/// trailing action slot, same hairline divider beneath the header. Each panel just supplies
/// its title, icon, optional accessory, and content.
struct SidebarPanel<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(title: String,
         icon: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(MacTheme.accent)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 14)
            // Pin to 44pt for a consistent sidebar header height. The
            // workspace pane to the right used to have a `WorkspaceToolbar`
            // at the same height; that toolbar has since been removed in
            // favor of the title-bar `ProjectTopBar`, but we keep this
            // header at 44pt because it still feels right and matches the
            // `EditorTabBarView` chrome row on the workspace side.
            .frame(height: 44)

            Divider().background(MacTheme.border.opacity(0.5))

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Sessions panel

struct SessionsPanel: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    var body: some View {
        SidebarPanel(
            title: "Sessions",
            icon: "rectangle.stack",
            trailing: {
                Button { Task { await vm.newSession(in: workspace) } } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain).help("New session")
            },
            content: {
                if workspace.sessions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(workspace.sessions) { session in
                                SessionRowMac(session: session,
                                              selected: workspace.selectedSessionId == session.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { workspace.switchToSession(session.id) }
                                    // Drag payload is the session UUID as a
                                    // string so the drop handler on every row
                                    // can decode it deterministically.
                                    .draggable(session.id.uuidString) {
                                        SessionDragPreview(title: session.title)
                                    }
                                    // Per-row drop target — accepting a
                                    // dragged session id reorders the global
                                    // sessions array so this row's position
                                    // is the new home of the dragged session.
                                    // Live `isTargeted` highlights the row a
                                    // drag is hovering over so the user can
                                    // see exactly where the drop will land.
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let raw = items.first,
                                              let sourceId = UUID(uuidString: raw),
                                              sourceId != session.id else { return false }
                                        withAnimation(.snappy(duration: 0.22)) {
                                            vm.moveSession(sourceId, before: session.id)
                                        }
                                        return true
                                    } isTargeted: { hovering in
                                        // Mark this row as the live drop
                                        // target so its top-edge insertion
                                        // line (drawn inside `SessionRowMac`)
                                        // shows / hides smoothly while the
                                        // user drags across the list.
                                        workspace.dropTargetSessionId = hovering
                                            ? session.id
                                            : (workspace.dropTargetSessionId == session.id
                                               ? nil
                                               : workspace.dropTargetSessionId)
                                    }
                            }
                        }
                        // Animate inserts / removals / moves of the row
                        // sequence so reordering doesn't snap discontinuously
                        // — rows slide into their new positions instead.
                        .animation(.snappy(duration: 0.22), value: workspace.sessions.map(\.id))
                        .padding(.horizontal, 8).padding(.vertical, 8)
                        // A bottom drop catcher so the user can drop a row
                        // PAST the last entry to move it to the end of the
                        // list — without this the only way to reorder onto
                        // the trailing edge would be hovering exactly over
                        // the last row's lower half, which is fiddly.
                        .overlay(alignment: .bottom) {
                            Color.clear
                                .frame(height: 16)
                                .contentShape(Rectangle())
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first,
                                          let sourceId = UUID(uuidString: raw) else { return false }
                                    withAnimation(.snappy(duration: 0.22)) {
                                        vm.moveSession(sourceId, before: nil)
                                    }
                                    return true
                                }
                        }
                    }
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.title)
                .foregroundStyle(MacTheme.textTertiary)
            Text("No sessions").font(.callout).foregroundStyle(MacTheme.textSecondary)
            Text("Click + to start a new one.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Per-window sidebar — show the project's sessions, scoped via `workspace.sessions`.
extension SessionsPanel {
    var projectSessions: [Session] { workspace.sessions }
}

struct SessionRowMac: View {
    let session: Session
    let selected: Bool
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Leading accent stripe — only visible on the selected row.
            // 3pt wide rounded bar that "owns" the selection state and
            // makes the active session pop against its neighbors, the same
            // affordance Finder/Mail use to mark a sidebar selection.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(selected ? MacTheme.accent : Color.clear)
                .frame(width: 3, height: 28)
            ContextRing(snapshot: vm.contextSnapshots[session.id],
                        status: session.status,
                        isSelected: selected,
                        pendingApprovalCount: session.pendingApprovalCount,
                        isProcessing: vm.thinkingSessions.contains(session.id))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                Text(session.projectName)
                    .font(.caption2)
                    .foregroundStyle(selected ? MacTheme.textSecondary : MacTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.pendingApprovalCount > 0 {
                Text("\(session.pendingApprovalCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(MacTheme.warning, in: Capsule())
            }
            if session.status != .ended && (hovering || selected) {
                Button { vm.requestClose(sessionId: session.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MacTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(MacTheme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(MacTheme.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain).help("Close session")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        // Edge-to-edge flat fill — same look the file explorer uses for
        // its rows (no border, no corner radius). Selected and hovered
        // share the soft accent tint; the selected state is then
        // distinguished by the leading accent stripe + bold title above
        // (the same affordance native macOS sidebars use), so the row
        // reads as "active" without needing extra chrome.
        .background(rowBackground)
        // Drop-indicator line. When this row is the live drop target of
        // a reorder drag, paint a 2pt accent rectangle along its top
        // edge so the user can see exactly where the dragged session
        // will land when they release. The animation gives the line a
        // soft fade-in / fade-out as the drag moves between rows.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MacTheme.accent)
                .frame(height: 2)
                .opacity(workspace.dropTargetSessionId == session.id ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.12), value: workspace.dropTargetSessionId)
        .opacity(session.status == .ended ? 0.55 : 1)
    }

    /// Mirrors `FileExplorerView`'s row-background priority so sessions
    /// and file rows feel like one design system: a soft accent tint for
    /// either hover OR selection, transparent otherwise. The selected
    /// state still pops thanks to the leading accent stripe and the
    /// bolder title — same pattern Finder/Mail use in their sidebars.
    private var rowBackground: Color {
        if selected { return MacTheme.accent.opacity(0.14) }
        if hovering { return MacTheme.accent.opacity(0.08) }
        return .clear
    }
}

/// Compact drag preview rendered while the user is reordering a session
/// row in the sidebar. Reads as a small floating chip with the session
/// title — visually lighter than dragging the entire row, which would
/// leave a heavy "ghost" hovering across the sidebar.
private struct SessionDragPreview: View {
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

struct ContextRing: View {
    let snapshot: ContextSnapshot?
    let status: SessionStatus
    /// True when this row/tab represents the currently-active session in the
    /// workspace. Suppresses the red "needs attention" badge — the user is
    /// already looking at this session, no need to nudge them.
    var isSelected: Bool = false
    /// Count of approvals waiting on a human decision for this session. >0
    /// while NOT selected → red attention dot, regardless of run status.
    var pendingApprovalCount: Int = 0
    /// True only while Claude is actively processing the user's last prompt —
    /// drives the spinning arc overlay. Sourced from `MacAppViewModel.thinkingSessions`
    /// (set on user prompt, cleared on assistant message / Stop hook), NOT from the
    /// session's lifecycle status — a `.running` session can still be idle waiting
    /// for the user to type, and we don't want the ring spinning forever in that case.
    var isProcessing: Bool = false

    /// Only display the percent ring when we have a real, transcript-measured snapshot.
    /// Optimistic estimates ("99%" on a brand-new session) are misleading.
    private var hasMeasuredContext: Bool {
        snapshot?.confidence == .measured
    }

    /// Compaction is a Mac-driven processing phase that doesn't touch
    /// `thinkingSessions`, so include it explicitly so the spinner reflects
    /// "the system is busy" during PreCompact/PostCompact too.
    private var isSpinning: Bool {
        if isProcessing { return true }
        if status == .compacting { return true }
        return false
    }

    /// Red attention dot appears when the user is NOT looking at this session AND
    /// it has either pending approvals OR has finished/crashed since they last saw
    /// it. Selecting the session clears the badge automatically (because
    /// `isSelected` flips true) — no per-session "viewed" state needed.
    private var needsAttention: Bool {
        guard !isSelected else { return false }
        if pendingApprovalCount > 0 { return true }
        switch status {
        case .ended, .crashed, .disconnected: return true
        case .waitingForApproval: return true
        default: return false
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle().strokeBorder(MacTheme.border, lineWidth: 2)
                // Display CONSUMED context (0 → 100) so the ring grows as the
                // session progresses. Numerically and visually consistent with
                // how Claude Code's own /context command reports usage:
                // an empty ring at session start, a full ring near the limit.
                if hasMeasuredContext, let used = snapshot?.percentUsed {
                    Circle()
                        .trim(from: 0, to: max(0.02, used))
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.4), value: used)
                    Text("\(Int((used * 100).rounded()))")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(MacTheme.textPrimary)
                } else {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                }
                // Spinner overlay — only while Claude is actually processing (or compacting).
                // Sits ON TOP of the percent ring so the user sees both "X% context left"
                // AND "still working." When Claude is idle/awaiting input the overlay is
                // torn down so the ring reads as a calm static state.
                if isSpinning {
                    RunningSpinnerOverlay()
                }
            }
            // Attention badge: small red dot in the top-right corner. Drawn
            // OUTSIDE the inner ZStack so it isn't masked by the ring shape.
            // Hidden when the user is on this session.
            if needsAttention {
                Circle()
                    .fill(MacTheme.danger)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(MacTheme.surface, lineWidth: 1.5))
                    .offset(x: 3, y: -3)
                    .accessibilityHidden(true)
            }
        }
    }
    private var ringColor: Color {
        guard let h = snapshot?.health else { return MacTheme.textTertiary }
        switch h {
        case .healthy: return MacTheme.success
        case .moderate: return MacTheme.accent
        case .low: return MacTheme.warning
        case .critical: return MacTheme.danger
        case .unknown: return MacTheme.textTertiary
        }
    }
    private var statusColor: Color {
        switch status {
        case .running: return MacTheme.success
        case .waitingForApproval: return MacTheme.warning
        case .crashed, .disconnected: return MacTheme.danger
        case .ended: return MacTheme.textTertiary
        default: return MacTheme.accent
        }
    }
}

/// Continuous-rotation arc overlay shown on top of `ContextRing` while the
/// session is actively processing. Owns its own `@State` so the rotation
/// lifecycle is structural — created when `isRunning` flips true, torn down
/// (and the animation stopped) when it flips false. Same pattern the iOS
/// `SpinningGear` uses, which is the cleanest way to avoid leftover rotation
/// state when SwiftUI re-renders the parent.
private struct RunningSpinnerOverlay: View {
    @State private var angle: Double = 0
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.30)
            .stroke(MacTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

// MARK: - Search & Git placeholder panels

struct SearchPanel: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var query: String = ""
    @State private var hits: [FileSearchHit] = []
    @State private var isSearching = false
    @State private var truncated = false
    @State private var lastError: String?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        SidebarPanel(
            title: "Search",
            icon: "magnifyingglass",
            trailing: {
                if isSearching { ProgressView().controlSize(.mini) }
            },
            content: {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                    body2
                }
            }
        )
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(MacTheme.textTertiary)
            TextField("Search files & contents…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
                .onChange(of: query) { _, _ in scheduleSearch() }
            if !query.isEmpty {
                Button { query = ""; hits = []; lastError = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    @ViewBuilder
    private var body2: some View {
        if workspace.projectRoot == nil {
            Text("Open a folder to enable project-wide search.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
                .padding(.horizontal, 14)
        } else if let err = lastError {
            Text(err).font(.caption).foregroundStyle(MacTheme.danger).padding(.horizontal, 14)
        } else if hits.isEmpty && !query.isEmpty && !isSearching {
            Text("No matches.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary).padding(.horizontal, 14)
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if truncated {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MacTheme.warning)
                        Text("Showing first 200 results").font(.caption2)
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                }
                ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                    Button { open(hit: hit) } label: {
                        HitRow(hit: hit, query: query)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// Debounces typing — fires the actual search 350 ms after the last keystroke.
    private func scheduleSearch() {
        debounceTask?.cancel()
        let snapshot = query
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled, snapshot == query { runSearch() }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = workspace.projectRoot?.url.path, !q.isEmpty else {
            hits = []; lastError = nil; truncated = false; return
        }
        isSearching = true
        lastError = nil
        let payload = FileSearchRequestPayload(rootPath: root, query: q,
                                               maxResults: 200, searchContent: true)
        Task { @MainActor in
            let response = await vm.searchFiles(payload: payload)
            // Discard if the user kept typing while we ran.
            guard q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            isSearching = false
            hits = response.hits
            truncated = response.truncated
            lastError = response.error
        }
    }

    private func open(hit: FileSearchHit) {
        let url = URL(fileURLWithPath: hit.path)
        if hit.isDirectory {
            // Search-result directory tap: open as a NEW project window. The current
            // window's project doesn't change — multi-window flow means each window is
            // pinned to its picked project; if the user wants this directory as a
            // project, it gets its own window via `WindowGroup(for:URL.self)`.
            ProjectWindowOpener.openProject(at: url)
        } else {
            let node = FileNode(url: url)
            workspace.openFile(node)
        }
    }
}

/// One row in the search results — filename + parent path + first matching line snippet.
private struct HitRow: View {
    let hit: FileSearchHit
    let query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hit.isDirectory ? "folder.fill" : "doc")
                .font(.caption)
                .foregroundStyle(hit.isDirectory ? MacTheme.accent : MacTheme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((hit.path as NSString).lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                Text((hit.path as NSString).deletingLastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(MacTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let line = hit.lineNumber, let snippet = hit.snippet {
                    Text("L\(line):  \(snippet)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(MacTheme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
        .contentShape(Rectangle())
    }
}

/// Source Control sidebar panel — replaces the old placeholder. Renders
/// the project's current branch (with refresh button) and a live list of
/// changed files (modified / staged / untracked / deleted), parsed from
/// `git status --porcelain`. Each file row shows a single-letter status
/// glyph and the path relative to the project root; tapping opens that
/// file in the editor. The list refreshes on appear, on tab switch back,
/// and via the Refresh button.
struct GitPanel: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var branch: String?
    @State private var entries: [GitStatusEntry] = []
    @State private var isLoading = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        SidebarPanel(
            title: "Source Control",
            icon: "arrow.triangle.branch",
            trailing: {
                HStack(spacing: 6) {
                    if isLoading { ProgressView().controlSize(.mini) }
                    Button { refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh git status")
                }
            },
            content: {
                if workspace.projectRoot == nil {
                    placeholder("Open a folder to see git status.")
                } else if branch == nil && entries.isEmpty && !isLoading {
                    placeholder("Not a git repository.")
                } else {
                    body2
                }
            }
        )
        .onAppear { refresh() }
        .onChange(of: workspace.projectRoot?.url) { _, _ in refresh() }
        .onDisappear { refreshTask?.cancel() }
    }

    @ViewBuilder
    private var body2: some View {
        VStack(alignment: .leading, spacing: 0) {
            branchHeader
            Divider().background(MacTheme.border.opacity(0.5))
            if entries.isEmpty {
                placeholder(isLoading ? "Loading…" : "Working tree clean.")
            } else {
                summaryStrip
                Divider().background(MacTheme.border.opacity(0.5))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            GitStatusRow(entry: entry) { openFile(entry) }
                        }
                    }
                }
            }
        }
    }

    private var branchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MacTheme.accent)
            Text(branch ?? "—")
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var summaryStrip: some View {
        let modified = entries.filter { $0.kind == .modified }.count
        let added    = entries.filter { $0.kind == .added }.count
        let deleted  = entries.filter { $0.kind == .deleted }.count
        let untracked = entries.filter { $0.kind == .untracked }.count
        return HStack(spacing: 10) {
            if modified  > 0 { summaryChip(label: "M",  count: modified,  tint: MacTheme.warning) }
            if added     > 0 { summaryChip(label: "A",  count: added,     tint: MacTheme.success) }
            if deleted   > 0 { summaryChip(label: "D",  count: deleted,   tint: MacTheme.danger)  }
            if untracked > 0 { summaryChip(label: "??", count: untracked, tint: MacTheme.textTertiary) }
            Spacer(minLength: 0)
            Text("\(entries.count) changed")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MacTheme.textTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func summaryChip(label: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MacTheme.textSecondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(tint.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title)
                .foregroundStyle(MacTheme.textTertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(MacTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openFile(_ entry: GitStatusEntry) {
        guard let root = workspace.projectRoot?.url else { return }
        let url = root.appendingPathComponent(entry.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        workspace.openFile(FileNode(url: url))
    }

    private func refresh() {
        guard let root = workspace.projectRoot?.url else {
            branch = nil; entries = []; return
        }
        refreshTask?.cancel()
        isLoading = true
        refreshTask = Task.detached(priority: .userInitiated) {
            let br = GitStatusService.currentBranch(at: root)
            let st = GitStatusService.status(at: root)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.branch = br
                self.entries = st
                self.isLoading = false
            }
        }
    }
}

/// Single row in the Source Control file list. Status glyph + path,
/// tinted by `kind`; click opens the file in the editor.
private struct GitStatusRow: View {
    let entry: GitStatusEntry
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(entry.kind.glyph)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(entry.kind.tint)
                    .frame(width: 18, alignment: .leading)
                Text(entry.path)
                    .font(.callout)
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(hovering ? MacTheme.accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.path)
    }
}

/// One row of `git status --porcelain` output. `path` is relative to
/// the project root; `kind` is normalised to a small enum so the UI
/// can colour-code without re-parsing the two-letter status code.
struct GitStatusEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let kind: Kind

    enum Kind: Hashable {
        case modified, added, deleted, renamed, untracked, conflicted

        var glyph: String {
            switch self {
            case .modified:   return "M"
            case .added:      return "A"
            case .deleted:    return "D"
            case .renamed:    return "R"
            case .untracked:  return "??"
            case .conflicted: return "U"
            }
        }
        var tint: Color {
            switch self {
            case .modified:   return MacTheme.warning
            case .added:      return MacTheme.success
            case .deleted:    return MacTheme.danger
            case .renamed:    return MacTheme.accent
            case .untracked:  return MacTheme.textTertiary
            case .conflicted: return MacTheme.danger
            }
        }
    }
}

/// Shell-out helpers for the GitPanel. Same `Process + Pipe` pattern
/// the project already uses for `GitHubProjectInfo.currentBranch` —
/// strong refs on the pipes, read BEFORE waitUntilExit, drain stderr.
enum GitStatusService {
    /// `git symbolic-ref --short HEAD` → branch name, or nil if detached
    /// HEAD / not a git repo.
    static func currentBranch(at url: URL) -> String? {
        run(["git", "symbolic-ref", "--short", "HEAD"], at: url)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    /// `git status --porcelain=v1 -z` → list of `GitStatusEntry`. Uses
    /// the NUL-separated v1 format so paths with spaces / quotes don't
    /// need extra unescaping.
    static func status(at url: URL) -> [GitStatusEntry] {
        guard let raw = run(["git", "status", "--porcelain=v1", "-z"], at: url),
              !raw.isEmpty else { return [] }
        var out: [GitStatusEntry] = []
        // Each record: "XY path\0", with rename records carrying an
        // extra "old\0" trailer we skip.
        var iterator = raw.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = iterator.next() {
            guard record.count > 3 else { continue }
            let codeRaw = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            let kind = parseKind(codeRaw)
            // Skip the rename "old path" trailer — git emits the new path
            // first then the old path with the same nul separator.
            if codeRaw.first == "R" || codeRaw.dropFirst().first == "R" {
                _ = iterator.next()
            }
            out.append(GitStatusEntry(path: path, kind: kind))
        }
        return out
    }

    private static func parseKind(_ code: String) -> GitStatusEntry.Kind {
        if code == "??" { return .untracked }
        let chars = Array(code)
        let staged = chars.first ?? " "
        let work   = chars.count > 1 ? chars[1] : " "
        // Conflicts: any combination involving "U" / "A"+"A" / "D"+"D".
        if staged == "U" || work == "U" || (staged == "A" && work == "A") || (staged == "D" && work == "D") {
            return .conflicted
        }
        if staged == "R" || work == "R" { return .renamed }
        if staged == "A" || work == "A" { return .added }
        if staged == "D" || work == "D" { return .deleted }
        return .modified
    }

    /// Same `Process + Pipe` recipe as `GitHubProjectInfo.currentBranch`:
    /// strong refs on the pipes, read BEFORE waitUntilExit, drain stderr.
    /// Returns nil if the binary isn't on PATH or git exits non-zero.
    private static func run(_ args: [String], at url: URL) -> String? {
        let task = Process()
        task.currentDirectoryURL = url
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = args
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        do { try task.run() } catch { return nil }
        let data = (try? outHandle.readToEnd()) ?? Data()
        task.waitUntilExit()
        _ = try? errHandle.readToEnd()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Tab descriptor

/// User-selectable sidebar background. Controls how the sidebar visually integrates with the
/// rest of the window. Stored in `@AppStorage("dnp.mac.sidebarStyle")`.
enum MacSidebarStyle: String, CaseIterable, Identifiable, Hashable {
    case solid          // Opaque MacTheme.surface (default)
    case liquidGlass    // .ultraThinMaterial — light blur over the desktop
    case vibrantGlass   // .regularMaterial + accent tint

    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid:        return "Solid"
        case .liquidGlass:  return "Liquid Glass"
        case .vibrantGlass: return "Vibrant Glass"
        }
    }
    var icon: String {
        switch self {
        case .solid:        return "square.fill"
        case .liquidGlass:  return "square.dashed"
        case .vibrantGlass: return "sparkles"
        }
    }
}

enum SidebarTab: String, CaseIterable, Identifiable, Hashable {
    // `.search` removed from sidebar — search is now the toolbar command palette (⌘P).
    // `.history` is a chronological timeline across every session in the project (events
    // are per-session by default; this is the project-wide "git log" style view).
    case home, files, sessions, events, history, git, github, pairing, settings, diagnostics
    var id: String { rawValue }

    /// Hard-coded factory order used as the seed for `SidebarOrderService`
    /// AND as the target the "Reset" button restores. Keep these in sync
    /// with the new tabs you add to the enum so the reset returns to a
    /// fully-populated default.
    static var defaultTopItems: [SidebarTab]    { [.home, .files, .sessions, .events, .history, .git] }
    static var defaultBottomItems: [SidebarTab] { [.github, .pairing, .diagnostics, .settings] }

    /// User-customisable ordering of the icon strip — driven by
    /// `SidebarOrderService` so a drag-reorder in any window updates every
    /// other open project window's strip on the next render. The service
    /// merges any persisted order with the current factory list, filtering
    /// out tabs that no longer exist and appending any new tabs at the end
    /// so an app update never leaves the user looking at a half-empty rail.
    static var topItems: [SidebarTab]    { SidebarOrderService.shared.topOrder }
    static var bottomItems: [SidebarTab] { SidebarOrderService.shared.bottomOrder }

    /// Whether this tab can participate in drag-reorder. Pinned tabs
    /// (Home in the top cluster, every tab in the bottom cluster) refuse
    /// to be dragged AND refuse to be drop targets — so neither they nor
    /// the slot they occupy can move. Reorder is therefore only valid
    /// among the middle of the top cluster: Files / Sessions / Events /
    /// History / Git.
    var isReorderable: Bool {
        switch self {
        case .home, .github, .pairing, .diagnostics, .settings:
            return false
        case .files, .sessions, .events, .history, .git:
            return true
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .files: return "Files"
        case .sessions: return "Sessions"
        case .events: return "Events"
        case .history: return "History"
        case .git: return "Source Control"
        case .github: return "GitHub"
        case .pairing: return "Pairing"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .files: return "folder.fill"
        case .sessions: return "rectangle.stack"
        case .events: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .git: return "arrow.triangle.branch"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .pairing: return "iphone.radiowaves.left.and.right"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}
