import SwiftUI
import AppKit

/// Top-level layout — Xcode-style integrated split. Sidebar lives in an HStack with the
/// workspace, sharing the same window background and divided by a hairline. The panel is
/// translucent (`.ultraThinMaterial`) so the desktop wallpaper still shows through, but it
/// no longer floats over the content — both surfaces blend cleanly into one window.
struct MacAppShellView: View {
    @EnvironmentObject var vm: MacAppViewModel
    /// Per-window workspace — the source of truth for which project this window shows,
    /// which sidebar tab is open, which session is selected, etc. Multi-window mode means
    /// each open project is its own workspace; this controller drives all the project-
    /// scoped UI inside this window.
    @EnvironmentObject var workspace: WorkspaceController
    /// Persisted width (survives app restart). Only WRITTEN on drag end — `@AppStorage`
    /// hits UserDefaults synchronously on every set, and during a 60fps live drag that's
    /// 60 disk-backed writes per second per the entire view-tree invalidation that goes
    /// with it. Live cursor-following uses `liveWidth` instead; we commit to
    /// `persistedWidth` once when the drag ends.
    @AppStorage("dnp.mac.sidebarWidth") private var persistedWidth: Double = 280
    /// Non-nil ONLY while the user is dragging the resize handle. Drives `currentWidth`
    /// directly so the panel follows the cursor in real time without thrashing
    /// UserDefaults / triggering @AppStorage publishers.
    @State private var liveWidth: Double? = nil

    private let collapsedWidth: CGFloat = 44
    // Lowered to 180 so the sidebar can ride a 640pt-wide window
    // without crowding the workspace below its own min. Sessions
    // / files / approvals lists all still read cleanly at 180pt
    // wide; the ProjectTopBar and status row reflow independently.
    private let minExpanded: CGFloat = 180
    private let maxExpanded: CGFloat = 480

    private var currentWidth: CGFloat {
        guard workspace.sidebarExpanded else { return collapsedWidth }
        let raw = liveWidth ?? persistedWidth
        return max(minExpanded, min(CGFloat(raw), maxExpanded))
    }

    var body: some View {
        // Inside a workspace window, we always render the IDE shell — the Welcome scene
        // lives in its OWN window now. Multi-window flow: Welcome → openWindow(value:) →
        // a fresh workspace window with its own `WorkspaceController`.
        workspaceShell
    }

    @ViewBuilder
    private var workspaceShell: some View {
        VStack(spacing: 0) {
            // Reserve 36pt at the top for the floating `ProjectTopBar`
            // overlay (added below). Without this spacer the icon strip's
            // `.ultraThinMaterial` would extend all the way up and cover
            // the project name.
            Color.clear.frame(height: 36)

            // Top hairline matching EXACTLY the vertical Divider between the icon strip
            // and the content panel — same `Divider` view, same tint, so the corner
            // where they meet is one continuous L-shape instead of two slightly different
            // greys not quite touching.
            Divider().background(MacTheme.border.opacity(0.6))

            HStack(spacing: 0) {
                // The fixed icon strip — ALWAYS 44pt, ALWAYS visible, lives OUTSIDE the
                // NSSplitView. Closing/opening the content panel (or dragging the divider)
                // never touches it, never re-renders it, never resizes it. This is what
                // gives Xcode/Finder their "the rail stays put while the panel slides" feel.
                MacSidebarIconStrip()
                Divider().background(MacTheme.border.opacity(0.6))

                // Only the CONTENT PANEL + workspace live inside the NSSplitView. The split
                // collapses the content pane to zero when `vm.sidebarExpanded == false`,
                // and AppKit handles the live drag with `inLiveResize` semantics so
                // SwiftTerm defers its expensive grid recalc until the user lets go.
                SidebarWorkspaceSplit(
                    sidebarWidth: Binding(
                        get: { CGFloat(persistedWidth) },
                        set: { persistedWidth = Double($0) }
                    ),
                    isExpanded: workspace.sidebarExpanded,
                    collapsedWidth: 0,         // content pane fully collapses; icon strip is separate
                    minExpanded: minExpanded,
                    maxExpanded: maxExpanded,
                    sidebar: { MacSidebarContent() },
                    workspace: { WorkspaceView() }
                )
            }
            .frame(maxHeight: .infinity)

            // Bottom hairline — same recipe as the top one (SwiftUI `Divider()` with the
            // theme-tinted background). Visually closes the chrome rectangle around the
            // status bar so the bottom edge feels integrated with the top edge instead
            // of just floating against the workspace.
            Divider().background(MacTheme.border.opacity(0.6))

            MacStatusBar()
        }
        // Lift the entire shell into the title-bar safe area so the
        // 36pt Color.clear spacer at the top of the VStack lands at
        // y=0 (where the traffic lights live) rather than below the
        // safe-area inset.
        .ignoresSafeArea(.container, edges: .top)
        // Floating ProjectTopBar overlay — sits on top of the sidebar
        // and workspace content so the project name on the leading edge
        // stays visible (the sidebar's `.ultraThinMaterial` background
        // can no longer cover it) and so clicks on the search pill
        // always hit the button rather than being eaten by the layer
        // beneath. Pinned to the very top of the shell with the same
        // `ignoresSafeArea` lift used by the spacer (and the same
        // tab-group exception).
        .overlay(alignment: .top) {
            // Single chrome row at the very top of the window: search +
            // project name + traffic-light buffer. The previous
            // `ProjectTabsStrip` layer was removed alongside the rest of
            // the tabs feature — every project always opens in its own
            // dedicated window now.
            ProjectTopBar()
                .frame(height: 36)
                .ignoresSafeArea(.container, edges: .top)
        }
        .background(MacTheme.background)
        // ⌘P / ⇧⌘P / ⌘K — promoted from `WorkspaceView` to the shell so the
        // shortcut also fires when the focused subview swallows key events.
        .background(
            Group {
                Button("") { workspace.paletteOpen.toggle() }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("") { workspace.paletteOpen.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("") { workspace.paletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            .opacity(0)
        )
        // The palette trigger lives in `ProjectTopBar` (a CHILD of this
        // shell), so its anchored frame preference flows up to here. We
        // overlay the dropdown at the shell level so it can extend down
        // past the title-bar row into the workspace area.
        .overlayPreferenceValue(PaletteTriggerFrameKey.self) { anchor in
            GeometryReader { geo in
                if workspace.paletteOpen, let anchor = anchor {
                    let triggerRect = geo[anchor]
                    let shellWidth = geo.size.width
                    // Dropdown width matches the trigger exactly when there's
                    // room (so it grows downward FROM the trigger), but is
                    // floored at 280 on very narrow windows and capped 12pt
                    // inside each shell edge so it never spills off-screen.
                    let paletteWidth = min(max(280, triggerRect.width), shellWidth - 24)
                    // Anchor the dropdown's left edge to the trigger's left
                    // edge when widths match; if we had to grow the dropdown
                    // wider than the trigger (small window), recenter it on
                    // the trigger and clamp to the shell.
                    let preferredX = triggerRect.width >= paletteWidth
                        ? triggerRect.minX
                        : (triggerRect.midX - paletteWidth / 2)
                    let clampedX = max(12, min(shellWidth - paletteWidth - 12, preferredX))
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { workspace.paletteOpen = false }
                        // `showsQueryField: false` — the title-bar TextField
                        // IS the input. The dropdown renders results-only,
                        // so the search box appears to stay in place while
                        // the suggestion list grows beneath it.
                        CommandPaletteView(
                            isPresented: Binding(
                                get: { workspace.paletteOpen },
                                set: { workspace.paletteOpen = $0 }
                            ),
                            showsQueryField: false
                        )
                        .frame(width: paletteWidth)
                        .offset(x: clampedX, y: triggerRect.maxY + 4)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeOut(duration: 0.18), value: workspace.paletteOpen)
                }
            }
        }
        .background(WindowAccessor { window in
            // Translucent title bar + full-size content keeps the modern look. We
            // deliberately DO NOT enable `isMovableByWindowBackground` — with the sidebar's
            // ultraThinMaterial counting as "background", AppKit was eating mouse-down
            // events on the resize handle / collapse-chevron button and treating them as
            // window-drag attempts (the whole app would scoot across the screen instead of
            // the sidebar resizing). The user still has the transparent title bar strip at
            // the very top to grab and drag the window.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
        })
        // Confirmation for "X" on a session is now a native `NSAlert` sheet driven directly
        // from `vm.requestClose` — bypasses the SwiftUI publisher pipeline so the dialog
        // appears in one frame instead of waiting for the full shell tree to re-render.
    }
}

/// One-shot `NSViewRepresentable` that grabs the host `NSWindow` and lets us mutate it
/// (transparent title bar, full-size content, drag-by-background). Applied EXACTLY ONCE
/// per view lifetime, when the NSView first attaches to a window. The previous form
/// re-dispatched `apply` on every SwiftUI update (i.e. every @Published change on the view
/// model) — with several sessions emitting events the main queue was getting flooded with
/// no-op window-config dispatches, which is a real source of "feels sluggish".
struct WindowAccessor: NSViewRepresentable {
    let apply: (NSWindow) -> Void

    final class Coordinator {
        var didApply = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachView()
        view.onAttach = { window in
            guard !context.coordinator.didApply else { return }
            context.coordinator.didApply = true
            apply(window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Intentionally empty — window setup is one-shot.
    }
}

/// AppKit hook: fires `onAttach` exactly when the NSView first gets a window. Dispatches
/// async so window-property mutations don't run inside SwiftUI's render pass — modifying
/// AppKit window state synchronously from `viewDidMoveToWindow` (which is itself driven by
/// a SwiftUI layout pass) is what was producing the AttributeGraph "cycle detected"
/// warning at startup.
private final class WindowAttachView: NSView {
    var onAttach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        DispatchQueue.main.async { [weak self] in self?.onAttach?(window) }
    }
}

/// Bottom status bar — Cursor-style. Shows project name, error/warning counts, bridge
/// connection, paired-device count, Tailscale state, and Claude version. Spans the full
/// window width with a thin `.bar` material so it reads as a system chrome strip.
struct MacStatusBar: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    // Status values default to "unknown / offline" placeholders. The previous
    // implementation called `TailscaleService.currentStatus()` and
    // `GitHubService.currentStatus()` as @State default initialisers — both
    // are blocking `Process + waitUntilExit` shell-outs that took 50-200ms
    // EACH and were re-evaluated every time SwiftUI rebuilt the view's
    // initial state (which happens on every project-window mount and on
    // some re-render cycles). With multiple open windows the cumulative
    // main-thread blocking was visible as UI stutter on cold-start and
    // when switching panes. The first real value now arrives asynchronously
    // via `.task` below, which dispatches the shell-outs to a utility queue.
    // The GitHub `gh`-auth state (`ghStatus`, `ghTimer`, `refreshGhStatus`)
    // was removed when the auth pill became the inline `repoPill` (which
    // reads from `workspace.projectGitHub`, not the gh CLI). Tailscale
    // state was removed alongside its pill. Settings → Tailscale,
    // Settings → About, and Diagnostics still surface those probes.
    /// Popover toggles for the error / warning badges in the bottom-left cluster. Mutually
    /// exclusive — opening one closes the other so the popovers can't stack.
    @State private var showErrorsPopover = false
    @State private var showWarningsPopover = false
    @State private var showAIUsagePopover = false

    var body: some View {
        // Compute counts ONCE per render. The previous form had three computed properties
        // (`allEvents`, `errorCount`, `warningCount`) that each re-walked `vm.feed.values`
        // independently — meaning every render did 3× the work. With many running sessions,
        // each event arrival re-rendered this bar and re-ran all three loops. Now there's
        // a single pass that updates a small `Counts` struct.
        let counts = Self.counts(from: vm.feed)
        return HStack(spacing: 14) {
            // Layout priority order keeps the most important controls
            // visible when the window is narrow: right cluster (live
            // connection status + paired iPhones) is highest priority,
            // left cluster (folder + repo + diagnostics) sits in the
            // middle, the center cluster (session title) drops first.
            leftCluster(errors: counts.errors, warnings: counts.warnings)
                .layoutPriority(1)
            Spacer(minLength: 0)
            centerCluster
            Spacer(minLength: 0)
            rightCluster
                .layoutPriority(2)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        // `.clipped()` prevents any residual overflow from leaking past
        // the status-bar bounds — defensive belt-and-suspenders for the
        // narrow-window path the user reported.
        .clipped()
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MacTheme.border.opacity(0.6)),
            alignment: .top
        )
        // Force LTR on the status bar for the same reason as the top
        // chrome row — Hebrew/RTL system locales otherwise reverse
        // `leftCluster` / `rightCluster` visually, so the connection
        // pill ends up on the left of the window and the
        // folder / repo / diagnostics on the right. With LTR pinned,
        // the status bar reads "folder · repo · errors · warnings · usage"
        // on the left and "connection · paired" on the right
        // regardless of locale.
        .environment(\.layoutDirection, .leftToRight)
    }

    private struct Counts {
        var errors: Int = 0
        var warnings: Int = 0
    }

    /// Walk every session's events once and tally errors + warnings. Keeps the per-render
    /// cost O(N) instead of 3×O(N).
    private static func counts(from feed: [UUID: [SessionEvent]]) -> Counts {
        var c = Counts()
        for events in feed.values {
            for e in events {
                if e.severity == .error || e.type == .crash { c.errors += 1 }
                else if e.severity == .warning { c.warnings += 1 }
            }
        }
        return c
    }

    // MARK: - Status-bar clusters

    private func leftCluster(errors: Int, warnings: Int) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MacTheme.accent)
                Text(workspace.projectRootName ?? "No folder")
                    .font(.caption)
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                    // Truncate the middle so a long project name shrinks
                    // gracefully on narrow windows instead of pushing the
                    // errors / warnings / AI-usage badges off the right
                    // edge of the cluster. Capped at 160pt so very long
                    // names can't dominate the status bar even on wide
                    // windows.
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            // Repo pill — only shown when this project is a GitHub-backed
            // working copy. Sits IMMEDIATELY after the folder name (the
            // user wanted a "folder · repo" reading), and tapping switches
            // the sidebar to the Source Control tab where commits, branch,
            // and remote operations live.
            repoPill
            divider
            // Error badge — clickable. Opens a popover listing the most recent errors so
            // the user can read what actually went wrong without navigating to the
            // Diagnostics pane. Disabled when there are no errors (nothing to show).
            Button {
                guard errors > 0 else { return }
                showWarningsPopover = false
                showErrorsPopover.toggle()
            } label: {
                statusBadgeContent(icon: "exclamationmark.octagon", count: errors,
                                   color: errors > 0 ? MacTheme.danger : MacTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(errors == 0)
            .help(errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s") — click for details" : "No errors")
            .popover(isPresented: $showErrorsPopover, arrowEdge: .top) {
                EventListPopover(title: "Errors",
                                 icon: "exclamationmark.octagon.fill",
                                 tint: MacTheme.danger,
                                 events: recentEvents(severity: .error, limit: 30))
            }
            // Warnings badge — same recipe.
            Button {
                guard warnings > 0 else { return }
                showErrorsPopover = false
                showWarningsPopover.toggle()
            } label: {
                statusBadgeContent(icon: "exclamationmark.triangle", count: warnings,
                                   color: warnings > 0 ? MacTheme.warning : MacTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(warnings == 0)
            .help(warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s") — click for details" : "No warnings")
            .popover(isPresented: $showWarningsPopover, arrowEdge: .top) {
                EventListPopover(title: "Warnings",
                                 icon: "exclamationmark.triangle.fill",
                                 tint: MacTheme.warning,
                                 events: recentEvents(severity: .warning, limit: 30))
            }
            // AI usage pill — moved from `rightCluster` so it sits next to
            // the errors / warnings badges, matching the user's "all
            // status counts in one row on the left" layout.
            divider
            aiUsagePill
        }
    }

    /// Walk the feed once and pull events of the requested severity, newest first, capped
    /// at `limit` so the popover never grows unbounded.
    private func recentEvents(severity: SessionEventSeverity, limit: Int) -> [SessionEvent] {
        var out: [SessionEvent] = []
        for events in vm.feed.values {
            for e in events {
                if severity == .error {
                    if e.severity == .error || e.severity == .critical || e.type == .crash {
                        out.append(e)
                    }
                } else if e.severity == severity {
                    out.append(e)
                }
            }
        }
        out.sort { $0.timestamp > $1.timestamp }
        return Array(out.prefix(limit))
    }

    @ViewBuilder
    private var centerCluster: some View {
        if let session = vm.selectedSession() {
            Text(session.title)
                .font(.caption)
                .foregroundStyle(MacTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Cap so the session title can't push the right cluster
                // (connection pill + paired-iPhones badge) past the
                // window edge on narrow windows. Lower-priority than
                // the right cluster so when space is really tight the
                // title shrinks first.
                .frame(maxWidth: 220)
                .layoutPriority(0)
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 14) {
            connectionPill
            divider
            // Connected-iPhones badge — clickable. Tapping opens the
            // workspace's Pairing pane so the user lands on the QR /
            // 6-digit code / paired-devices list. Re-tapping while the
            // pairing pane is already open returns to the terminal,
            // matching the toggle behaviour of the sidebar icon.
            Button {
                workspace.workspacePane = (workspace.workspacePane == .pairing)
                    ? .terminal
                    : .pairing
            } label: {
                statusBadgeContent(
                    icon: "iphone.gen3",
                    count: vm.connectedDeviceIds.count,
                    color: MacTheme.textSecondary,
                    labelWhenZero: "0 paired"
                )
            }
            .buttonStyle(.plain)
            .help("Open Pairing — \(vm.connectedDeviceIds.count) connected")
            // The GitHub `gh`-auth pill, the Tailscale hostname, and the
            // "Claude · <hash>" build label all used to live here. They
            // were moved or removed: the repo identifier is now the
            // `repoPill` next to the project name on the LEFT, and the
            // tailnet / build-info diagnostics are still reachable from
            // Settings → About / Diagnostics. Right cluster now ends at
            // the paired-iPhones badge for a compact, calm status row.
        }
    }

    /// AI Usage button. Same visual language as the errors / warnings badges
    /// in this status bar: a compact pill showing icon + the most relevant
    /// number, click to open a `.popover` with the full per-window
    /// breakdown. The 5-hour Claude Code utilisation % is the headline; the
    /// popover lists every window the Anthropic endpoint reports (5h / 7d /
    /// Sonnet / Omelette) with progress bars and reset times.
    @ViewBuilder
    private var aiUsagePill: some View {
        if let usage = vm.aiUsage {
            let headline = usage.windows.first(where: { $0.label == "5h" }) ?? usage.windows.first
            Button {
                showAIUsagePopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    // Claude Code logo — dual-asset imageset that picks the
                    // black or white variant automatically based on the
                    // system appearance, so the icon stays legible in both
                    // light and dark mode without a tint override.
                    Image("ClaudeAILogo")
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                    if let row = headline, let pct = row.percent {
                        // Just the icon + the percentage. The window label
                        // ("5h" / "7d") used to render here too — removed
                        // so the pill stays as compact as the errors and
                        // warnings badges next to it. The full per-window
                        // breakdown is still available in the popover.
                        Text("\(Int(pct.rounded()))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(MacTheme.textPrimary)
                    } else {
                        Text(usage.errorMessage == nil ? "Usage" : "Sign in")
                            .font(.caption)
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(usage.errorMessage ?? headline?.detail ?? "Claude Code AI Usage — click for details")
            .popover(isPresented: $showAIUsagePopover, arrowEdge: .bottom) {
                MacAIUsagePopover(usage: usage,
                                  refresh: { Task { await vm.refreshAIUsage() } })
            }
        }
    }

    /// Inline repo pill — sits next to the project folder name on the
    /// left side of the status bar. Renders only when this project is a
    /// GitHub-backed working copy (i.e. `workspace.projectGitHub` is
    /// non-nil); otherwise the slot collapses and the layout reads
    /// "folder · errors · warnings · usage".
    ///
    /// Tap → switch the sidebar to the Source Control (`.git`) tab and
    /// expand the panel, so the user lands directly on the commit / push /
    /// branch operations for this repo. The icon mirrors the GitHub
    /// "code" glyph used elsewhere in the chrome.
    @ViewBuilder
    private var repoPill: some View {
        if let info = workspace.projectGitHub {
            Button {
                workspace.sidebarTab = .git
                workspace.sidebarExpanded = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MacTheme.accent)
                    Text(info.nameWithOwner)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MacTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Cap the repo name in the status bar so a long
                        // `org/repo-with-very-long-name` doesn't force
                        // the badges to the right of it off-screen.
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Source Control — \(info.nameWithOwner)\(info.currentBranch.map { " · \($0)" } ?? "")")
        }
    }

    // `claudeVersionLabel` was removed from the status bar — the version
    // hash is still surfaced in Settings → About and in Diagnostics, both
    // of which are better homes for build-info diagnostics than the
    // always-visible chrome strip.

    private var divider: some View {
        Rectangle().fill(MacTheme.border.opacity(0.5)).frame(width: 1, height: 14)
    }

    private func statusBadge(icon: String, count: Int, color: Color,
                              labelWhenZero: String? = nil) -> some View {
        statusBadgeContent(icon: icon, count: count, color: color, labelWhenZero: labelWhenZero)
    }

    /// The badge's visible content, factored out so the error/warning Buttons in the
    /// left cluster can reuse it as a clickable label.
    private func statusBadgeContent(icon: String, count: Int, color: Color,
                                     labelWhenZero: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            if count > 0 || labelWhenZero == nil {
                Text("\(count)").font(.caption.monospacedDigit())
            } else {
                Text(labelWhenZero ?? "").font(.caption)
            }
        }
        .foregroundStyle(color)
        .contentShape(Rectangle())
    }

    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle().fill(connectionColor).frame(width: 7, height: 7)
            Text(connectionText).font(.caption)
                .foregroundStyle(connectionColor)
        }
        .help(connectionTooltip)
    }

    private var connectionColor: Color {
        switch vm.bridgeStatus {
        case .connected:                                 return MacTheme.success
        case .degraded:                                  return MacTheme.warning
        case .error:                                     return MacTheme.danger
        case .connecting, .discovering, .authenticating: return MacTheme.accent
        case .offline:                                   return MacTheme.textTertiary
        }
    }
    private var connectionText: String {
        switch vm.bridgeStatus {
        case .connected:        return "Bridge online"
        case .degraded:         return "Degraded"
        case .error:            return "Error"
        case .connecting:       return "Connecting…"
        case .discovering:      return "Discovering…"
        case .authenticating:   return "Authenticating…"
        case .offline:          return "Offline"
        }
    }
    private var connectionTooltip: String {
        let port = vm.bridge.port.map { String($0) } ?? "—"
        return "Bridge: \(connectionText) (port \(port))"
    }

    // `tailscalePill` (the long tailnet hostname) and its `refreshTsStatus`
    // probe were removed from the status bar — the long hostname dominated
    // the right cluster, and the same connectivity info is still visible
    // in Settings → Tailscale and the Diagnostics pane. The `tsStatus` /
    // `tsTimer` state is preserved on this struct in case other rows ever
    // want to read it again, but no view currently consumes them.
}

/// NSSplitView subclass that paints a subtle theme-matched hairline instead of the
/// default `.thin` divider, AND surfaces a `viewDidEndLiveResize` callback. The default
/// divider in dark mode reads as a hard black vertical strip running down the middle of
/// the window. The end-of-drag callback lets us defer the @AppStorage write until the
/// user releases — keeping the per-frame drag work to native AppKit only.
private final class HiddenDividerSplitView: NSSplitView {
    var onDragEnded: (() -> Void)?

    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        // Skip drawing when the leading pane is fully collapsed (content panel width 0).
        // In that state, the SwiftUI `Divider()` between the icon strip and the split
        // view sits at the same x-coordinate as our split divider would — drawing both
        // produced a "doubled, thicker" vertical line right when the sidebar closed.
        // Hiding ours leaves the SwiftUI Divider as the single hairline.
        if let leading = arrangedSubviews.first, leading.frame.width < 0.5 { return }
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        let line = NSRect(x: rect.midX - 0.25, y: rect.minY,
                          width: 0.5, height: rect.height)
        line.fill()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onDragEnded?()
    }
}

/// SwiftUI wrapper around `NSSplitView` for the sidebar/workspace boundary. NSSplitView
/// is what every native macOS IDE (Finder, Xcode, Terminal) uses for resizable panels;
/// during a divider drag it sets `inLiveResize = true` on its children, which SwiftTerm +
/// other AppKit views check before doing their expensive setFrame work. SwiftUI's HStack
/// doesn't trigger that flag at all, which is why the previous pure-SwiftUI live resize
/// felt laggy — every frame, SwiftTerm re-computed its character grid. Now AppKit gates
/// it: while you drag, SwiftTerm only updates its frame (cheap GPU work) and defers the
/// grid math + PTY `TIOCSWINSZ` ioctl until the divider stops moving.
struct SidebarWorkspaceSplit<Sidebar: View, Workspace: View>: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat
    let isExpanded: Bool
    let collapsedWidth: CGFloat
    let minExpanded: CGFloat
    let maxExpanded: CGFloat
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let workspace: () -> Workspace

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSplitView {
        // Custom subclass: suppresses NSSplitView's built-in divider drawing AND surfaces
        // the end-of-live-resize callback so we can write to @AppStorage exactly once
        // when the user releases (instead of on every drag tick — which was a
        // UserDefaults sync write per frame and a real source of jank).
        let split = HiddenDividerSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.translatesAutoresizingMaskIntoConstraints = true
        split.onDragEnded = { [weak coordinator = context.coordinator] in
            coordinator?.commitDragWidth()
        }

        // Concrete-typed `NSHostingView` (NOT `NSHostingView<AnyView>`). AnyView destroys
        // SwiftUI's view identity, so every `updateNSView` reassignment used to recreate
        // the entire workspace subtree — including the SwiftTerm `LocalProcessTerminalView`
        // — which is what made the resize feel laggy on every vm publish.
        let sidebarHost = NSHostingView(rootView: sidebar())
        let workspaceHost = NSHostingView(rootView: workspace())
        // CRITICAL: use frame-based layout, NOT constraint-based. With
        // `translatesAutoresizingMaskIntoConstraints = false`, NSSplitView creates
        // internal constraints to manage divider position, and any direct
        // `subview.frame = ...` write we do in `applyDividerLayout` is silently
        // reverted on the next autolayout pass — that's why the chevron clicked but
        // the content pane never visually resized. With it `true` (the default), the
        // frames we write are authoritative; NSSplitView still calls `adjustSubviews`
        // to flow remaining width into the trailing pane, but it doesn't fight us.
        sidebarHost.translatesAutoresizingMaskIntoConstraints = true
        workspaceHost.translatesAutoresizingMaskIntoConstraints = true
        // Track split-view height changes (window resize) — only the leading width is
        // pinned via holding priority below. `.width` is intentionally omitted so the
        // trailing host can be resized by NSSplitView when the divider moves.
        sidebarHost.autoresizingMask = [.height]
        workspaceHost.autoresizingMask = [.width, .height]

        split.addArrangedSubview(sidebarHost)
        split.addArrangedSubview(workspaceHost)
        // Pin the sidebar (leading) at its current width whenever NSSplitView reflows —
        // window resize, `adjustSubviews()`, autoresizing pass. Higher holding priority
        // = "this pane resists size changes; the other absorbs the delta." This is the
        // documented native replacement for the manual `splitView(_:resizeSubviewsWithOldSize:)`
        // bookkeeping we used to do, and it cooperates cleanly with the direct frame
        // manipulation we do in `updateNSView`.
        split.setHoldingPriority(.init(251), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        split.delegate = context.coordinator
        context.coordinator.splitView = split

        // Initial divider position — set frames DIRECTLY rather than via `setPosition`.
        // `setPosition` has subtle interactions with the split view's internal collapse
        // / holding-priority machinery that made the chevron-toggle silently no-op
        // (architecture_mac_sidebar.md memory). Direct frame writes + `adjustSubviews`
        // are deterministic: width goes exactly where we put it. Dispatched async only
        // so the split view's bounds are non-zero by the time we lay out.
        DispatchQueue.main.async { [weak split] in
            guard let split = split else { return }
            Self.applyDividerLayout(to: split,
                                    isExpanded: isExpanded,
                                    sidebarWidth: sidebarWidth,
                                    collapsedWidth: collapsedWidth,
                                    minExpanded: minExpanded,
                                    maxExpanded: maxExpanded,
                                    animated: false)
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        // Skip during in-flight live resize so we don't fight the user's drag.
        guard !split.inLiveResize else { return }
        Self.applyDividerLayout(to: split,
                                isExpanded: isExpanded,
                                sidebarWidth: sidebarWidth,
                                collapsedWidth: collapsedWidth,
                                minExpanded: minExpanded,
                                maxExpanded: maxExpanded,
                                animated: true)
    }

    /// Single source of truth for moving the divider — used by both `makeNSView` (initial
    /// layout) and `updateNSView` (toggle). Sets frames DIRECTLY instead of routing through
    /// `setPosition`, because `setPosition` interacts in subtle ways with NSSplitView's
    /// collapse / holding-priority machinery and would silently no-op the chevron toggle
    /// (see `architecture_mac_sidebar.md`). Holding priorities pinned in `makeNSView` keep
    /// `adjustSubviews()` honest — the leading pane's width stays exactly where we put it,
    /// the trailing pane absorbs the rest.
    ///
    /// Why no synthetic NSAnimationContext animation: `allowsImplicitAnimation = true` was
    /// driving the trailing pane (which contains SwiftTerm) through animated frame
    /// interpolation. Each animation tick re-fired `setFrameSize` → `TIOCSWINSZ` → SIGWINCH
    /// → Claude TUI redraw, and the redraws stacked in scrollback as a column of duplicated
    /// splash banners. Native macOS sidebars (Xcode, Finder, System Settings) snap on
    /// chevron toggle for exactly this reason — the splitter is for live drag, the chevron
    /// is for instant state change. Snap = one frame change = one SIGWINCH = clean redraw.
    private static func applyDividerLayout(to split: NSSplitView,
                                           isExpanded: Bool,
                                           sidebarWidth: CGFloat,
                                           collapsedWidth: CGFloat,
                                           minExpanded: CGFloat,
                                           maxExpanded: CGFloat,
                                           animated _: Bool) {
        guard split.arrangedSubviews.count >= 2 else { return }
        let leading = split.arrangedSubviews[0]
        let trailing = split.arrangedSubviews[1]

        let target = isExpanded
            ? max(minExpanded, min(maxExpanded, sidebarWidth))
            : collapsedWidth

        // Defensive un-hide in case anything earlier collapsed the leading subview.
        if leading.isHidden { leading.isHidden = false }

        if abs(leading.frame.width - target) < 0.5 { return }

        let totalWidth  = max(0, split.bounds.width)
        let dividerW    = split.dividerThickness
        let height      = split.bounds.height
        let trailingW   = max(0, totalWidth - target - dividerW)

        leading.frame  = NSRect(x: 0,                  y: 0, width: target,    height: height)
        trailing.frame = NSRect(x: target + dividerW,  y: 0, width: trailingW, height: height)
        split.adjustSubviews()
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let parent: SidebarWorkspaceSplit
        weak var splitView: NSSplitView?
        /// Most recent width seen during a live drag — committed once on mouse-up. Avoids
        /// a UserDefaults round-trip on every drag tick.
        var pendingDragWidth: CGFloat?

        init(parent: SidebarWorkspaceSplit) { self.parent = parent }

        func commitDragWidth() {
            guard let width = pendingDragWidth else { return }
            pendingDragWidth = nil
            parent.sidebarWidth = width
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            // Allow collapse all the way down to the icon-strip width, which is what the
            // chevron toggle uses; user can also drag manually past `minExpanded` to
            // collapse without using the chevron.
            return parent.collapsedWidth
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            return parent.maxExpanded
        }

        func splitView(_ splitView: NSSplitView,
                       constrainSplitPosition proposedPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            // Snap to either collapsed or the expanded zone (>= minExpanded).
            // Anywhere between 0 and minExpanded snaps to whichever is closer — gives
            // the chevron-toggle and manual-drag the same set of resting states.
            let snapPoint = (parent.collapsedWidth + parent.minExpanded) / 2
            if proposedPosition < snapPoint { return parent.collapsedWidth }
            return max(parent.minExpanded, min(parent.maxExpanded, proposedPosition))
        }

        // We deliberately do NOT implement `canCollapseSubview` (returns false by default).
        // When it returns true, NSSplitView treats `setPosition(0)` as a "collapse to
        // hidden" operation and sets `isHidden = true` on the subview — at which point
        // `setPosition(280)` won't bring it back without an explicit `isHidden = false`.
        // That made the chevron-toggle look broken (click does nothing). Instead we keep
        // the subview always visible-but-resizable: its width can go from 0 to 480, and
        // `setPosition` with our `constrainMinCoordinate = 0` just sets the width. No
        // isHidden complication, the toggle works on every click.

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split = notification.object as? NSSplitView,
                  let leading = split.arrangedSubviews.first
            else { return }
            let newWidth = leading.frame.width
            // Only persist while the user actually drags the divider — otherwise this
            // fires on every window resize and clobbers the saved width.
            guard split.inLiveResize else { return }
            // Only stash widths in the expanded range, so collapsed (~0) doesn't
            // overwrite the saved expanded width.
            guard newWidth >= parent.minExpanded else { return }
            // STASH the value in a local cache. The committed write to @AppStorage
            // happens once on mouse-up via `viewDidEndLiveResize` → `commitDragWidth`.
            // The previous form did `DispatchQueue.main.async { parent.sidebarWidth = ... }`
            // on every drag tick — UserDefaults sync write × 60fps = real jank.
            pendingDragWidth = newWidth
        }

        // Note: we used to implement `splitView(_:resizeSubviewsWithOldSize:)` to pin the
        // sidebar's width during window resizes. That's no longer needed — `setHoldingPriority`
        // calls in `makeNSView` give us the same "leading resists, trailing absorbs"
        // behavior natively, and (crucially) without fighting the direct-frame writes we do
        // for the chevron toggle.
    }
}

/// Popover content rendered when the user clicks the error or warning badge in the
/// status bar. Lists the most recent matching events with their session, title, summary,
/// and timestamp — enough to diagnose without leaving the bar. Empty state is hidden by
/// the badge being click-disabled when count is zero.
struct EventListPopover: View {
    let title: String
    let icon: String
    let tint: Color
    let events: [SessionEvent]
    @EnvironmentObject var vm: MacAppViewModel

    /// Static — same reasoning as the FeedRowMac formatter cache.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.headline).foregroundStyle(MacTheme.textPrimary)
                Spacer()
                Text("\(events.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MacTheme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().background(MacTheme.border.opacity(0.5))

            if events.isEmpty {
                Text("Nothing here right now.")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(events) { e in row(for: e) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 380)
    }

    @ViewBuilder
    private func row(for event: SessionEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Self.timestampFormatter.string(from: event.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MacTheme.textTertiary)
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(MacTheme.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            // Session label — handy when the user has multiple sessions and an error
            // arrived from one they aren't currently viewing.
            if let session = vm.sessions.first(where: { $0.id == event.sessionId }) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                        .font(.caption2)
                        .foregroundStyle(MacTheme.textTertiary)
                    Text(session.title)
                        .font(.caption2)
                        .foregroundStyle(MacTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surfaceAlt.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - AI Usage popover

/// Detail popover surfaced from the status bar's AI Usage button. Mirrors
/// the visual rhythm of `EventListPopover` (used by Errors / Warnings) so
/// the user gets a consistent "click status badge → see breakdown" model.
/// Lists every quota window the Anthropic endpoint reports plus a Refresh
/// button that immediately re-pulls (instead of waiting for the 5-minute
/// timer in `MacAppViewModel`).
struct MacAIUsagePopover: View {
    let usage: AIUsageSnapshot
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MacTheme.accent)
                Text(usage.providerName)
                    .font(.headline)
                    .foregroundStyle(MacTheme.textPrimary)
                Spacer()
                if let stamp = Self.relative(usage.fetchedAt) {
                    Text(stamp)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textTertiary)
                }
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
            Divider()
            if let err = usage.errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(MacTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if usage.windows.isEmpty {
                Text("No quota data yet — Claude hasn't reported any windows.")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textSecondary)
            } else {
                ForEach(usage.windows, id: \.label) { window in
                    MacAIUsagePopoverRow(window: window)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private static func relative(_ date: Date) -> String? {
        let secs = -date.timeIntervalSinceNow
        if secs < 60 { return "just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins) min ago" }
        return "\(mins / 60)h ago"
    }
}

/// Single-window row for the AI Usage popover AND the Diagnostics
/// "Claude usage" card — both surface the same `AIUsageWindow` and the
/// shared rhythm (label · big percent · "% used" · resets HH:MM · linear
/// progress tinted by utilisation) is the visual contract the user already
/// recognises from the status-bar pill. Lives at file scope (not nested in
/// `MacAIUsagePopover`) so DiagnosticsView can reach it without
/// duplicating layout / tint rules.
struct MacAIUsagePopoverRow: View {
    let window: AIUsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textSecondary)
                if let pct = window.percent {
                    Text("\(Int(pct.rounded()))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(MacTheme.textPrimary)
                }
                if let detail = window.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textTertiary)
                }
                Spacer()
                if let reset = window.resetAt {
                    Text("resets \(Self.shortTime(reset))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MacTheme.textTertiary)
                }
            }
            if let pct = window.percent {
                ProgressView(value: max(0, min(1, pct / 100)))
                    .progressViewStyle(.linear)
                    .tint(barTint(for: pct))
            }
        }
        .padding(.vertical, 4)
    }

    private func barTint(for pct: Double) -> Color {
        if pct >= 90 { return MacTheme.danger }
        if pct >= 70 { return MacTheme.warning }
        return MacTheme.accent
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Title-bar row that occupies the same horizontal strip as the macOS
/// traffic-light buttons. Layout from leading to trailing:
///
///   • 78pt empty gap reserved for the close / minimize / maximize buttons
///     (they are rendered by AppKit at fixed positions in the title bar
///     and we mustn't overlap them);
///   • centered command-palette search trigger — same look and behaviour as
///     the previous in-toolbar search pill, just promoted up to the chrome
///     row so the search lives in the window header instead of the
///     workspace toolbar;
///   • trailing slot showing the current project name with a folder glyph,
///     opposite the traffic lights so the eye lands on it naturally.
///
/// Tapping the trigger flips `workspace.paletteOpen`; the dropdown overlay
/// lives on `MacAppShellView` so the trigger's anchored frame preference
/// can flow up to it.
struct ProjectTopBar: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    /// Drives the cursor caret in the title-bar TextField. We keep it in
    /// sync with `workspace.paletteOpen` so opening the palette via ⌘P
    /// (or any other code path) auto-focuses the input, and pressing
    /// Escape both clears focus and dismisses the dropdown.
    @FocusState private var searchFocused: Bool

    /// Width reserved on the leading edge for the macOS traffic-light
    /// buttons. Slightly larger than the buttons themselves (3 × 14pt
    /// + spacing + leading inset ≈ 80pt) so the search pill never
    /// crowds them on narrow windows.
    private let trafficLightInset: CGFloat = 88

    var body: some View {
        // Force LTR on a WRAPPING container so every layout-direction-
        // aware modifier inside (.padding(.leading/.trailing), HStack
        // ordering) sees LTR — regardless of the system locale. Hebrew
        // (RTL) was the failure mode: `.padding(.trailing, 88)` on the
        // bar was evaluating to the VISUAL LEFT, leaving the search
        // pill flush against the right edge where the traffic lights
        // live. Wrapping the whole tree under `.environment(.layoutDirection, .leftToRight)`
        // makes every nested modifier honour visual-left = leading.
        innerBarContent
            .environment(\.layoutDirection, .leftToRight)
            .background(MacTheme.surface.ignoresSafeArea(edges: .top))
            .onChange(of: workspace.paletteOpen) { _, open in
                searchFocused = open
            }
    }

    /// HStack body extracted so it can be wrapped by the LTR-forced
    /// environment WITHOUT chaining the environment modifier between
    /// the HStack and its padding (which is what made
    /// `.padding(.trailing)` evaluate against the OUTER environment
    /// instead of the LTR one).
    @ViewBuilder
    private var innerBarContent: some View {
        HStack(spacing: 8) {
            DNPSidebarLogoMark(size: 18)
                .offset(y: 2)
            projectNameLabel
                .frame(minWidth: 0)
                .layoutPriority(0)
            Spacer(minLength: 8)
            searchInput
                .frame(minWidth: 140, idealWidth: 380, maxWidth: 440)
                .layoutPriority(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, trafficLightInset)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Real `TextField` styled to look identical to the previous search
    /// pill. The trigger STAYS in place when the palette opens — the
    /// dropdown grows downward beneath it instead of replacing it. Typing
    /// drives `workspace.paletteQuery`, which the dropdown filters on.
    private var searchInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(MacTheme.textTertiary)
            TextField(triggerPlaceholder, text: Binding(
                get: { workspace.paletteQuery },
                set: { workspace.paletteQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($searchFocused)
            // Opening on focus means clicking anywhere in the pill (or
            // tabbing into it) summons the dropdown — no need for a
            // separate "click to open" gesture.
            .onChange(of: searchFocused) { _, focused in
                if focused { workspace.paletteOpen = true }
            }
            .onSubmit { workspace.paletteOpen = true }
            if !workspace.paletteQuery.isEmpty {
                Button {
                    workspace.paletteQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MacTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            HStack(spacing: 2) {
                Image(systemName: "command").font(.caption2.weight(.semibold))
                Text("P").font(.caption.weight(.semibold))
            }
            .foregroundStyle(MacTheme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(MacTheme.border, lineWidth: 0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(MacTheme.surfaceAlt.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    MacTheme.border.opacity(workspace.paletteOpen ? 1.0 : 0.6),
                    lineWidth: workspace.paletteOpen ? 0.8 : 0.5
                )
        )
        .help("Search this project (⌘P)")
        .anchorPreference(key: PaletteTriggerFrameKey.self, value: .bounds) { $0 }
    }

    /// Bare project-name label rendered on the side opposite the traffic
    /// lights. No icon, no background, no border — just the project name as
    /// a piece of plain title-bar typography, which is what the user asked
    /// for. Truncates from the middle so very long names still hint at both
    /// the leading and trailing path components.
    @ViewBuilder
    private var projectNameLabel: some View {
        if let name = workspace.projectRootName {
            Text(name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(workspace.projectRoot?.url.path ?? name)
        }
    }

    private var triggerPlaceholder: String {
        if let project = workspace.projectRootName {
            return "Search \(project), commands, sessions…"
        }
        return "Search files, commands, sessions…"
    }
}

// `ProjectTabsStrip` and `ProjectTabDragPreview` were removed alongside
// the rest of the "Tabs in one window" feature. Every project now opens
// in its own dedicated window — the dock menu, the menu-bar popover, and
// the welcome window's "Recent Projects" rail are the canonical ways to
// switch between projects. `MacAppViewModel.moveProjectWindow(_:before:)`
// is kept around as the global ordering primitive for those listings.
