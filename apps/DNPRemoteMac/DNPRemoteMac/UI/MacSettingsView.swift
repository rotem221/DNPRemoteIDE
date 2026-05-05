import SwiftUI

/// Mac settings, single-page sectioned layout. Replaces the prior tabbed sheet so that
/// settings can render as the center pane of the main window.
struct MacSettingsView: View {
    @EnvironmentObject var vm: MacAppViewModel
    /// Sparkle-backed update controller. `@ObservedObject` is enough —
    /// the singleton lives forever, we just want this view to redraw
    /// when `availableUpdateVersion` / `canCheckForUpdates` change.
    @ObservedObject private var updates = UpdateService.shared
    @AppStorage("dnp.defaultLaunchVerbose") private var verbose = false
    @AppStorage("dnp.permissionMode") private var permissionMode = "ask"
    @AppStorage("dnp.mac.skipCloseConfirm") private var skipCloseConfirm = false
    @AppStorage("dnp.lowContextThreshold") private var threshold = 0.25
    @AppStorage("dnp.feedFilterDebug") private var showDebug = false
    @AppStorage("dnp.mac.screenMirrorEnabled") private var screenMirrorEnabled = false
    @AppStorage("dnp.mac.notifyEnabled")        private var notifyEnabled = true
    @AppStorage("dnp.mac.notifyApprovals")      private var notifyApprovals = true
    @AppStorage("dnp.mac.notifyAttention")      private var notifyAttention = true
    @AppStorage("dnp.mac.approvalsBringToFront") private var approvalsBringToFront = false
    @AppStorage("dnp.mac.approvalsFloatingPanel") private var approvalsFloatingPanel = false
    @AppStorage("dnp.mac.notifyDeviceChanges")  private var notifyDeviceChanges = true
    @AppStorage("dnp.mac.notifyErrors")         private var notifyErrors = true
    /// "Session ended" banner — default OFF so the user opts in
    /// explicitly. Read by `MacNotificationService.fireSessionEnded(...)`.
    @AppStorage("dnp.mac.notifySessionEnded")   private var notifySessionEnded = false
    @AppStorage("dnp.mac.notifyPairing")        private var notifyPairing = true
    @AppStorage("dnp.mac.notifySound")          private var notifySound = true
    // `dnp.mac.windowMode` and the "Project windows" Settings card were
    // removed. The app now ships with a single window-layout model:
    // every project opens in its own dedicated window. The "Tabs in one
    // window" alternative was conflicting with the title-bar layout
    // (the macOS native tab bar can't be repositioned and couldn't be
    // reliably hidden), so we standardised on the multi-window flow the
    // rest of the app was originally designed around.
    /// Default Claude context-window size. Read by
    /// `MacAppViewModel.budget(forModel:)` when the model id transcripts come
    /// through (e.g. plain `claude-opus-4-7`) lack the `[1m]` 1M-beta marker.
    /// "auto" → standard 200K (matches Claude Code's `/context` default).
    /// 1M-beta plan users override to "1000000" so their per-session ring
    /// reads against the right denominator from the first turn instead of
    /// near-100% used while at 10-20% of the real window.
    @AppStorage("dnp.mac.defaultContextWindow") private var defaultContextWindow = "auto"
    @AppStorage("dnp.mac.settingsCategory")     private var rawSelectedCategory = Category.general.rawValue
    @State private var tailscaleStatus: TailscaleService.Status = TailscaleService.currentStatus()

    /// User-facing settings categories. The tab strip below the header
    /// switches between them; each category renders its own scoped set
    /// of cards. Persisted via `@AppStorage` so the user lands on the
    /// last-used category when they reopen the page.
    enum Category: String, CaseIterable, Identifiable {
        case general, keyboard, connectivity, notifications, advanced, updates, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:       return "General"
            case .keyboard:      return "Keyboard"
            case .connectivity:  return "Connectivity"
            case .notifications: return "Notifications"
            case .advanced:      return "Advanced"
            case .updates:       return "Updates"
            case .about:         return "About"
            }
        }
        var icon: String {
            switch self {
            case .general:       return "gearshape"
            case .keyboard:      return "keyboard"
            case .connectivity:  return "network"
            case .notifications: return "bell.badge"
            case .advanced:      return "slider.horizontal.3"
            case .updates:       return "arrow.down.circle"
            case .about:         return "info.circle"
            }
        }
    }

    private var selectedCategory: Category {
        Category(rawValue: rawSelectedCategory) ?? .general
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                categoryTabs
                categoryContent
                Spacer(minLength: 32)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Apple System Settings.app pattern: page background is a slightly darker grouped
        // tone, cards float on top in the lighter `card` color. The tonal contrast is what
        // makes the cards "pop" without needing heavy shadows.
        .background(MacTheme.groupedBackground)
        // When the user picks a different default context window, re-derive
        // every cached snapshot's percentage immediately so the rings flip
        // without waiting for the next Claude `usage` block.
        .onChange(of: defaultContextWindow) { _, _ in
            Task { @MainActor in
                await vm.recomputeContextSnapshotsForBudgetChange()
            }
        }
    }

    /// Category-tabs strip — a horizontally scrollable row of pill
    /// buttons that sits BETWEEN the header (title + description) and
    /// the cards. Active pill is tinted with the brand accent;
    /// inactive pills sit on the surfaceAlt tone. Mirrors the look of
    /// the History pane's filter strip so the two surfaces feel like
    /// the same design system.
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Category.allCases) { cat in
                    SettingsCategoryChip(
                        category: cat,
                        active: selectedCategory == cat
                    ) {
                        rawSelectedCategory = cat.rawValue
                    }
                }
            }
        }
    }

    /// Switches the visible cards based on `selectedCategory`. Card
    /// definitions stay where they are (one per topic) — this just
    /// composes them into category-scoped sets so the user only sees
    /// what's relevant to the chosen tab.
    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .general:
            claudeCard
            sidebarCard
        case .keyboard:
            // Dedicated tab — the shortcuts list is long enough to deserve its
            // own pane rather than sitting at the bottom of General.
            ShortcutsCardView()
        case .connectivity:
            bridgeCard
            tailscaleCard
            screenMirrorCard
        case .notifications:
            notificationsCard
        case .advanced:
            contextCard
            feedCard
        case .updates:
            updatesCard
        case .about:
            aboutCard
        }
    }

    /// Tailscale status card — shows whether the daemon is reachable, the assigned tailnet
    /// IPv4, the host's tailnet name, and a one-shot Refresh button. Reflects what
    /// `TailscaleService.currentStatus()` reports right now; the bridge re-probes on every
    /// `broadcastProjectInfo()` so iOS sees fresh data without needing this card to refresh.
    private var tailscaleCard: some View {
        let connected = (tailscaleStatus.ipv4?.isEmpty == false) || (tailscaleStatus.hostname?.isEmpty == false)
        return SettingsCard(title: "Tailscale", icon: "network") {
            HStack(spacing: 12) {
                Image(systemName: connected ? "checkmark.circle.fill" : "wifi.slash")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(connected ? MacTheme.success : MacTheme.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(
                        (connected ? MacTheme.success : MacTheme.textTertiary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? "Connected to tailnet" : "Tailscale offline / not installed")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text(connected
                         ? "iOS clients fall back to your tailnet IP when the LAN is unreachable."
                         : "Install Tailscale and sign in to enable off-LAN reconnect.")
                        .font(.caption).foregroundStyle(MacTheme.textTertiary)
                }
                Spacer()
                Button("Refresh") {
                    tailscaleStatus = TailscaleService.currentStatus()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if connected {
                Divider().background(MacTheme.border).padding(.vertical, 4)
                row("Tailnet IPv4", value: tailscaleStatus.ipv4 ?? "—", mono: true,
                    valueColor: MacTheme.success)
                row("Tailnet hostname", value: tailscaleStatus.hostname ?? "—", mono: true)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(MacTheme.accent)
                .frame(width: 56, height: 56, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(.title.bold()).foregroundStyle(MacTheme.textPrimary)
                Text("Configure how DNP Remote Mac launches Claude, talks to iPhone, and renders events.")
                    .font(.callout).foregroundStyle(MacTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var claudeCard: some View {
        SettingsCard(title: "Claude Code", icon: "sparkles") {
            row("Path", value: vm.claude.detectedPath ?? "Not found", mono: true)
            row("Version", value: vm.claude.detectedVersion ?? "?", mono: true)
            Divider().background(MacTheme.border).padding(.vertical, 4)
            toggleRow("Verbose output", isOn: $verbose)
            labeledRow("Permission mode") {
                Picker("", selection: $permissionMode) {
                    Text("Ask").tag("ask")
                    Text("Allow").tag("allow")
                    Text("Deny").tag("deny")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: SettingsLayout.controlWidth, alignment: .trailing)
                .labelsHidden()
            }
            Text("DNP Remote never uses --dangerously-skip-permissions. iOS approvals always go through Claude's permission system.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
            Divider().background(MacTheme.border).padding(.vertical, 4)
            // Single global flag for the close-confirmation prompt — when
            // ON, every close path (sidebar row ✕, workspace tab strip ✕,
            // split-pane ✕) drops straight into the destructive action
            // without showing the "Close <session>?" alert. Off by
            // default so the user can't lose a session to a stray click.
            toggleRow("Skip close confirmation", isOn: $skipCloseConfirm)
            Text("When on, closing a session via ✕ ends it immediately without asking. The handoff note is still saved to memory/notes/. Applies to every session.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
        }
    }

    private var bridgeCard: some View {
        SettingsCard(title: "Bridge", icon: "network") {
            row("Status", value: vm.bridgeStatus.rawValue.capitalized, valueColor: bridgeStatusColor)
            row("Port", value: vm.bridge.port.map(String.init) ?? "—", mono: true)
            row("Trusted devices", value: "\(vm.connectedDevices.count)")
            row("Currently connected", value: "\(vm.connectedDeviceIds.count)",
                valueColor: vm.connectedDeviceIds.isEmpty ? MacTheme.textPrimary : MacTheme.success)
        }
    }

    /// Project-window layout settings — separate windows vs merged tabs.
    /// The choice is applied live to every open project window via
    /// `ProjectWindowTabbingConfigurator`; flipping the picker doesn't
    /// require an app restart. In tabs mode, the tab strip's "+" button
    /// is rebound to open the Welcome / project picker instead of
    /// spawning a blank project tab — matching the affordance the user
    /// actually wants when they reach for "+".
    /// Sidebar card — currently surfaces a single "Reset sidebar order"
    /// action that wipes the user's drag-reorder of the icon strip and
    /// snaps both the top and bottom clusters back to factory order.
    /// Lives here (not under the Shortcuts card) because the icon strip's
    /// arrangement is a layout preference, not a keyboard binding.
    private var sidebarCard: some View {
        SettingsCard(title: "Sidebar", icon: "sidebar.left") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidebar icon order")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("Drag any icon in the sidebar to rearrange. Reset returns both clusters to the factory order.")
                        .font(.caption)
                        .foregroundStyle(MacTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset") {
                    SidebarOrderService.shared.reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var contextCard: some View {
        SettingsCard(title: "Context monitor", icon: "gauge") {
            // Default context-window picker. The model id Anthropic writes to
            // transcripts (e.g. `claude-opus-4-7`) doesn't carry a `[1m]`
            // marker even when the user is on the 1M-context plan, so a
            // standard-200K denominator was producing artificially-high
            // "used %" rings for 1M-plan sessions. The picker lets users
            // pin the right denominator. Explicit `[1m]` model strings
            // still win over this — the model decides if it carries the
            // marker; this only fills the gap when it doesn't.
            labeledRow("Default context window") {
                Picker("", selection: $defaultContextWindow) {
                    Text("Auto (200K)").tag("auto")
                    Text("200K").tag("200000")
                    Text("500K").tag("500000")
                    Text("1M").tag("1000000")
                    Text("2M").tag("2000000")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: SettingsLayout.controlWidth, alignment: .trailing)
                .labelsHidden()
            }
            Text("If your Claude plan provides a 1M-token context window (Opus 4.7 1M-beta), pick **1M** so per-session rings count against the real window. The transcript model id rarely contains the `[1m]` marker, so without an override sessions on a 1M plan can read “near 100% used” while only 10–20% of the real window is consumed.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().background(MacTheme.border).padding(.vertical, 4)
            labeledRow("Low-context threshold") {
                Text("\(Int(threshold * 100))%")
                    .font(.callout.monospacedDigit().bold())
                    .foregroundStyle(MacTheme.textPrimary)
            }
            Slider(value: $threshold, in: 0.05...0.50, step: 0.05) {
                Text("Threshold")
            } minimumValueLabel: {
                Text("5%").font(.caption2).foregroundStyle(MacTheme.textTertiary)
            } maximumValueLabel: {
                Text("50%").font(.caption2).foregroundStyle(MacTheme.textTertiary)
            }
            .tint(MacTheme.accent)
            Text("Warn iOS when context drops below this percentage. Lower threshold = warning fires later.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
        }
    }

    private var feedCard: some View {
        SettingsCard(title: "Event feed", icon: "list.bullet.rectangle") {
            toggleRow("Show debug-severity events", isOn: $showDebug)
            Text("Affects the Mac event-feed pane only. iOS clients always receive a curated subset.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
        }
    }

    private var notificationsCard: some View {
        SettingsCard(title: "Notifications", icon: "bell.badge") {
            MacNotificationAuthorizationRow()
            Divider().background(MacTheme.border).padding(.vertical, 4)
            toggleRow("Enable notifications", isOn: $notifyEnabled)

            // Approvals subsection — high-priority alerts the user opted into. Time-
            // sensitive interruption breaks through Focus modes; the optional floating
            // panel is the "pop above all windows" affordance for users who don't want
            // to miss the approval card while working in another app.
            toggleRow("Claude approval requests", isOn: $notifyApprovals,
                      disabled: !notifyEnabled)
            toggleRow("Show approval popup over all windows", isOn: $approvalsFloatingPanel,
                      indented: true, disabled: !notifyEnabled || !notifyApprovals)
            toggleRow("Bring app to front on approval", isOn: $approvalsBringToFront,
                      indented: true, disabled: !notifyEnabled || !notifyApprovals)

            // Generic "Claude needs attention" — fallback nudge for Claude's Notification
            // hook (idle prompt, MCP server input, permission prompts that bypassed our
            // structured approval path). No inline actions, deduped against approvals.
            toggleRow("Claude needs attention", isOn: $notifyAttention,
                      disabled: !notifyEnabled)

            Divider().background(MacTheme.border).padding(.vertical, 4)
            toggleRow("Device connect / disconnect", isOn: $notifyDeviceChanges,
                      disabled: !notifyEnabled)
            toggleRow("New pairing requests", isOn: $notifyPairing,
                      disabled: !notifyEnabled)
            toggleRow("Session errors and crashes", isOn: $notifyErrors,
                      disabled: !notifyEnabled)
            // "Session ended" — distinct from "errors and crashes": this
            // covers normal close + the crashed transition with a
            // single `dnp.mac.notifySessionEnded` switch. Default OFF
            // so existing users don't get a banner per close until they
            // opt in.
            toggleRow("Session ended", isOn: $notifySessionEnded,
                      disabled: !notifyEnabled)
            toggleRow("Play sound", isOn: $notifySound,
                      disabled: !notifyEnabled)
            Text("Approval banners are time-sensitive — they appear above active windows even in Focus mode and include Approve / Deny buttons inline.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
        }
    }

    /// Screen Mirror card — master toggle for the iOS-driven remote control feature.
    /// Disabled-by-default, opt-in. When enabled the Mac honors `screenMirrorStart`
    /// requests from paired iOS clients; when disabled, those requests are dropped at
    /// the service layer (the dispatcher still verifies the signed envelope, but
    /// `MacScreenMirrorService.start` short-circuits via the same `prefBool` check).
    private var screenMirrorCard: some View {
        SettingsCard(title: "Screen Mirror", icon: "rectangle.on.rectangle") {
            toggleRow("Allow paired iPhones to mirror this screen", isOn: $screenMirrorEnabled)
            Text("When ON, your iPhone can view this Mac's main display and control the mouse/keyboard remotely. macOS will prompt for **Screen Recording** and **Accessibility** permission the first time the feature is used. Both prompts come from System Settings — DNP Remote never bypasses them.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Stream is end-to-end signed via the same Ed25519 envelope that protects every other bridge message — only the paired iPhone can request it.")
                .font(.caption2).foregroundStyle(MacTheme.textTertiary)
        }
    }

    /// Updates card — surfaces Sparkle's state (current version, last
    /// check, available update) plus the user-facing controls
    /// (Check Now, automatic toggle, channel picker). Mirrors the
    /// muxy-app/muxy Updates pane layout but uses our `SettingsCard`
    /// container so it sits visually with the rest of Settings.
    private var updatesCard: some View {
        SettingsCard(title: "Updates", icon: "arrow.down.circle") {
            // Banner — only visible when Sparkle has surfaced an
            // installable update. Two buttons: "Install" pops the
            // standard Sparkle install UI; "Release notes" opens the
            // GitHub release page so a user who couldn't install can
            // still read the changelog. Tinted with the brand accent
            // so it can't be missed at a glance.
            if let pending = updates.availableUpdateVersion {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(MacTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(MacTheme.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(pending) is available")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(MacTheme.textPrimary)
                        Text("Install to get the latest fixes and features.")
                            .font(.caption).foregroundStyle(MacTheme.textTertiary)
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Button("Install") { updates.checkForUpdates() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Release Notes") { updates.openReleasesPage() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Divider().background(MacTheme.border).padding(.vertical, 4)
            }

            // Status row — current version + last-checked relative
            // time. Mono-styled value column matches the rest of the
            // settings UI (Tailscale card, About card).
            row("Current version", value: Self.appVersion, mono: true)
            row("Last checked",
                value: updates.lastCheckedDescription ?? "Never")

            Divider().background(MacTheme.border).padding(.vertical, 4)

            // Manual check + auto-check toggle. Disabling the button
            // when Sparkle isn't ready (still resolving its first
            // feed) avoids the silent no-op the user would otherwise
            // see right after launch.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for updates now")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("Asks the appcast for the newest release on your channel.")
                        .font(.caption).foregroundStyle(MacTheme.textTertiary)
                }
                Spacer()
                Button("Check Now") { updates.checkForUpdates() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!updates.canCheckForUpdates)
            }

            Toggle(isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.automaticallyChecksForUpdates = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check automatically").font(.callout)
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("DNP Remote Mac will check once a day in the background.")
                        .font(.caption).foregroundStyle(MacTheme.textTertiary)
                }
            }
            .toggleStyle(.switch)

            Divider().background(MacTheme.border).padding(.vertical, 4)

            // Channel picker — Stable / Beta. Beta is opt-in; the
            // copy under the picker spells out the trade-off so the
            // user knows what they're signing up for.
            VStack(alignment: .leading, spacing: 6) {
                Text("Update channel")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                Picker("", selection: Binding(
                    get: { updates.channel },
                    set: { updates.channel = $0 }
                )) {
                    ForEach(DNPUpdateChannel.allCases) { ch in
                        Text(ch.displayName).tag(ch)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(updates.channel == .beta
                     ? "Beta builds ship from `main` automatically. Expect rough edges."
                     : "Stable builds ship after beta soak — recommended for daily use.")
                    .font(.caption).foregroundStyle(MacTheme.textTertiary)
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: "About", icon: "info.circle") {
            // Brand header — same `WelcomeLogo` imageset used on the Welcome page
            // (auto-light/dark) so the About card feels like the welcome screen's
            // sibling rather than a plain text dump. Centered inside the card,
            // matching the welcome layout. Fixed frame keeps the wordmark at the
            // intended ~4.95:1 aspect regardless of how wide the user dragged
            // the Settings window.
            HStack {
                Spacer()
                Image("WelcomeLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 280, height: 62)
                Spacer()
            }
            .padding(.vertical, 4)

            // Founder + copyright. "Founded by Rotem Dadon" is the credit the
            // Welcome page does NOT show — keeping that screen task-focused —
            // so About is the canonical place users find it. Year is rendered
            // dynamically so the copyright never goes stale across releases.
            VStack(spacing: 4) {
                Text("Founded by Rotem Dadon")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                Text("© \(Self.copyrightYear) DNP. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(MacTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            Divider().background(MacTheme.border).padding(.vertical, 4)

            row("App", value: "DNP Remote Mac · \(Self.appVersion)")
            labeledRow("Product site") {
                Link("remotednp.com",
                     destination: URL(string: "https://remotednp.com")!)
                    .font(.callout)
            }
            labeledRow("Company") {
                Link("dnp.co.il",
                     destination: URL(string: "https://dnp.co.il")!)
                    .font(.callout)
            }
            labeledRow("Documentation") {
                Link("Open in browser",
                     destination: URL(string: "https://code.claude.com/docs/en/overview")!)
                    .font(.callout)
            }
        }
    }

    /// Current year for the copyright line — derived at render time so a build
    /// shipped in December that runs in January still reads correctly without
    /// anyone bumping a constant.
    private static var copyrightYear: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f.string(from: Date())
    }

    /// Version pulled from `Info.plist` so the About card reflects the
    /// shipped build instead of a hardcoded string. The `Build` /
    /// `Bundle id` rows that used to live here were debugging-only
    /// diagnostics — removed to keep the card focused on user-facing
    /// information.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    // MARK: - Helpers

    private var bridgeStatusColor: Color {
        switch vm.bridgeStatus {
        case .connected: return MacTheme.success
        case .degraded: return MacTheme.warning
        case .error: return MacTheme.danger
        default: return MacTheme.textPrimary
        }
    }

    private func row(_ label: String, value: String, mono: Bool = false,
                     valueColor: Color = MacTheme.textPrimary) -> some View {
        labeledRow(label) {
            Text(value)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(valueColor)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// Shared layout primitive for every "label : control" row inside a
    /// `SettingsCard`. Pins the label to a fixed-width left column so titles
    /// across cards and across rows in the same card line up vertically, and
    /// reserves the trailing slot for a control (button / picker / value /
    /// link). This is what gives the Settings page its "one symmetric column
    /// of titles, one symmetric column of controls" rhythm — without it,
    /// rows with short labels let their controls drift left of rows with
    /// long labels, and the page reads ragged.
    @ViewBuilder
    private func labeledRow<Trailing: View>(_ label: String,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(MacTheme.textSecondary)
                .frame(minWidth: SettingsLayout.labelColumnWidth, alignment: .leading)
            Spacer(minLength: 8)
            trailing()
        }
    }

    /// Toggle row that pins the switch to the trailing edge regardless of label
    /// length. SwiftUI's default `Toggle("Title", isOn:)` lets the switch hug
    /// the title text, so a card with rows like "Play sound" and "Show approval
    /// popup over all windows" ends up with switches scattered at random
    /// horizontal positions. This helper forces every switch to align with the
    /// card's right gutter — the System Settings.app pattern — and supports
    /// optional indentation for "child of the row above" toggles, plus a single
    /// disabled flag that dims both the label and the switch in lockstep.
    @ViewBuilder
    private func toggleRow(_ label: String,
                           isOn: Binding<Bool>,
                           indented: Bool = false,
                           disabled: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(disabled ? MacTheme.textTertiary : MacTheme.textPrimary)
                .padding(.leading, indented ? 16 : 0)
                .lineLimit(2)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(MacTheme.accent)
                .disabled(disabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Visual constants shared across Settings rows so the label and control
/// columns line up regardless of which card a row lives in.
enum SettingsLayout {
    /// Minimum width of the leading label column. Picked to comfortably fit
    /// the longest label currently in use ("Tailnet hostname") at the system
    /// default font, so no label gets visibly truncated and shorter labels
    /// align flush-left under longer ones.
    static let labelColumnWidth: CGFloat = 170
    /// Maximum width for trailing controls (segmented pickers, menu pickers,
    /// fixed-width steppers). Applied as `frame(maxWidth:)` rather than a
    /// rigid `frame(width:)` so the controls can shrink on narrow windows
    /// instead of pushing past the card's right edge — the off-screen
    /// segmented buttons that used to appear on the "Project windows"
    /// row when the long labels exceeded 220pt.
    static let controlWidth: CGFloat = 220
}

// MARK: - Reusable card container

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(MacTheme.accent)
                Text(title).font(.headline).foregroundStyle(MacTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().background(MacTheme.border.opacity(0.5))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(16)
        }
        // Card surface — `controlBackgroundColor` is what System Settings.app uses for its
        // rounded blocks. Soft hairline border, no shadow (matches Apple's flat-card style).
        .background(MacTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MacTheme.border.opacity(0.5), lineWidth: 0.5)
        )
    }
}

/// Authorization status row for the Mac Settings → Notifications card. Mirrors the iOS
/// counterpart: shows the system grant state and offers a single CTA — request when not
/// determined, "Open System Settings" when denied (macOS blocks re-prompting).
struct MacNotificationAuthorizationRow: View {
    @StateObject private var service = MacNotificationService.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("System permission")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(MacTheme.textTertiary)
            }
            Spacer()
            actionButton
        }
        .task { await service.refreshAuthorization() }
    }

    private var icon: String {
        switch service.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "checkmark.circle.fill"
        case .denied:                               return "xmark.circle.fill"
        case .notDetermined:                        return "bell.badge"
        @unknown default:                            return "bell"
        }
    }

    private var tint: Color {
        switch service.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return MacTheme.success
        case .denied:                               return MacTheme.danger
        case .notDetermined:                        return MacTheme.warning
        @unknown default:                            return MacTheme.textTertiary
        }
    }

    private var statusText: String {
        switch service.authorizationStatus {
        case .authorized:    return "Allowed"
        case .provisional:   return "Allowed (provisional)"
        case .ephemeral:     return "Allowed (ephemeral)"
        case .denied:        return "Denied — change in System Settings"
        case .notDetermined: return "Not requested yet"
        @unknown default:    return "Unknown"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch service.authorizationStatus {
        case .notDetermined:
            Button("Allow") {
                Task { await service.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent).tint(MacTheme.accent)
            .controlSize(.small)
        case .denied:
            Button("Open System Settings") {
                service.openSystemSettings()
            }
            .buttonStyle(.bordered).controlSize(.small)
        default:
            EmptyView()
        }
    }
}

/// One pill in the Settings category-tabs strip. Active state is
/// accent-tinted; inactive sits on `surfaceAlt`. Hover lifts the
/// inactive fill slightly so the row reads as interactive even before
/// the user clicks. Style mirrors the History pane's filter strip
/// (`HistoryChip` / `FilterChip`) so the two surfaces feel like one
/// design system.
private struct SettingsCategoryChip: View {
    let category: MacSettingsView.Category
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.caption.weight(.semibold))
                Text(category.title)
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Chips now match the Settings *card* tone — same neutral
            // surface family the cards below sit on — instead of carrying
            // any brand-purple tint. The active chip is just a slightly
            // brighter fill in the same family with a stronger hairline,
            // so the strip reads as "one row of cards", with the selected
            // one elevated rather than colored.
            .foregroundStyle(active ? MacTheme.textPrimary : MacTheme.textSecondary)
            .background(
                Capsule(style: .continuous)
                    .fill(active
                          ? MacTheme.card
                          : (hovering ? MacTheme.surfaceAlt.opacity(0.85)
                                       : MacTheme.surfaceAlt.opacity(0.55)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        active ? MacTheme.border.opacity(0.85)
                               : MacTheme.border.opacity(0.4),
                        lineWidth: active ? 0.8 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
