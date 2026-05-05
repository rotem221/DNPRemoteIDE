import SwiftUI
import AppKit

/// Liquid Glass popover shown when the user clicks the menu-bar icon. Acts as a
/// "lite control center" the user can reach without bringing the IDE window to front:
///
/// - **Bold brand wordmark** at the top
/// - **Live status row** — bridge online + paired devices + open windows
/// - **Claude usage** — 5h / 7d quota windows pulled from
///   `MacAppViewModel.aiUsage`, same source as the status-bar AI Usage pill
/// - **Active windows** — one row per open project, with a spinning ring while
///   Claude is processing in that project and a small badge showing the
///   session count
/// - **Quick actions** — Settings / Quit
struct MacMenuBarView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header was the brand wordmark + connection-state dot. The user
            // asked to remove both — the popover now opens directly into the
            // Bridge / Paired / Windows status block. Connection state is
            // still legible from the Bridge row's tinted icon (green/red),
            // and the brand identity already lives in the menu-bar icon
            // itself, so the duplicate header was redundant chrome.
            statusBlock
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16)
            Divider().background(MacTheme.border)
            usageSection
            Divider().background(MacTheme.border)
            windowsSection
            Divider().background(MacTheme.border)
            actionsSection
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    // MARK: - Status block

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow(icon: "antenna.radiowaves.left.and.right",
                      label: "Bridge",
                      value: bridgeValueText,
                      tint: vm.bridge.port == nil ? MacTheme.danger : MacTheme.success)
            statusRow(icon: "iphone",
                      label: "Paired",
                      value: pairedSummary,
                      tint: vm.connectedDeviceIds.isEmpty ? MacTheme.textTertiary : MacTheme.success)
            statusRow(icon: "macwindow",
                      label: "Windows",
                      value: vm.openProjectWindows.isEmpty ? "None open" : "\(vm.openProjectWindows.count) open",
                      tint: vm.openProjectWindows.isEmpty ? MacTheme.textTertiary : MacTheme.accent)
        }
    }

    private func statusRow(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label)
                .font(.callout)
                .foregroundStyle(MacTheme.textSecondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(MacTheme.textPrimary)
            Spacer()
        }
    }

    private var bridgeValueText: String {
        if let port = vm.bridge.port { return "Online · :\(port)" }
        return "Offline"
    }

    private var pairedSummary: String {
        let connected = vm.connectedDeviceIds.count
        let total = vm.connectedDevices.count
        if total == 0 { return "No devices" }
        return "\(connected) of \(total) online"
    }

    // MARK: - Claude usage
    //
    // Compact AI-quota strip — same `AIUsageSnapshot` the status-bar pill
    // and Diagnostics card render. Mirrors the popover's section rhythm:
    // one row per quota window (`5h`, `7d`, `7d Sonnet`, `7d Omelette`)
    // with label · percent · linear bar tinted by utilisation. Fits the
    // 380-pt popover width without needing to open a separate sheet.

    @ViewBuilder
    private var usageSection: some View {
        sectionHeader("Claude usage")
        Group {
            if let usage = vm.aiUsage {
                if let err = usage.errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(MacTheme.warning)
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(MacTheme.warning)
                            .lineLimit(2)
                        Spacer()
                    }
                } else if usage.windows.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "hourglass")
                            .font(.callout)
                            .foregroundStyle(MacTheme.textTertiary)
                        Text("No quota data yet")
                            .font(.callout)
                            .foregroundStyle(MacTheme.textTertiary)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(usage.windows, id: \.label) { window in
                            usageRow(window)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.mini)
                    Text("Fetching usage…")
                        .font(.callout)
                        .foregroundStyle(MacTheme.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// Single quota row inside the usage section. Layout matches the
    /// status-bar popover's `MacAIUsagePopoverRow` (label gutter, big bold
    /// percent, "X.X% used" detail, tinted progress bar) so the visual
    /// language stays consistent across both surfaces.
    private func usageRow(_ window: AIUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacTheme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                if let pct = window.percent {
                    Text("\(Int(pct.rounded()))%")
                        .font(.callout.weight(.bold).monospacedDigit())
                        .foregroundStyle(MacTheme.textPrimary)
                } else {
                    Text("—")
                        .font(.callout.weight(.bold))
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
                    .tint(usageBarTint(for: pct))
            }
        }
    }

    private func usageBarTint(for pct: Double) -> Color {
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

    // MARK: - Active windows
    //
    // One row per open `WorkspaceWindow`. Each row carries:
    //   • A `macwindow` icon — when ANY session in that project is in the
    //     `thinkingSessions` set (Claude is actively processing this turn),
    //     the icon is overlaid by a continuously-rotating accent arc, the
    //     same idiom the sidebar `ContextRing` uses. Reads as "Claude is
    //     working here right now."
    //   • Project name + ~/path subtitle.
    //   • A small circular count badge with the number of LIVE sessions
    //     in this project (status != .ended). Hidden when zero; tinted
    //     accent so the eye lands on it when the user is multi-tasking.
    // Tapping the row brings the project window to the front.

    @ViewBuilder
    private var windowsSection: some View {
        sectionHeader("Active windows")
        if vm.openProjectWindows.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "macwindow")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textTertiary)
                Text("No project windows open")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(vm.openProjectWindows.prefix(5).enumerated()), id: \.offset) { _, url in
                    HoverableMenuRow {
                        focusProjectWindow(url)
                    } content: {
                        windowRow(url: url)
                    }
                }
                if vm.openProjectWindows.count > 5 {
                    Text("+ \(vm.openProjectWindows.count - 5) more window\(vm.openProjectWindows.count - 5 == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(MacTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
        }
    }

    private func windowRow(url: URL) -> some View {
        let liveSessions = vm.sessions.filter {
            $0.projectPath == url.path && $0.status != .ended
        }
        let isThinking = liveSessions.contains { vm.thinkingSessions.contains($0.id) }
        let sessionCount = liveSessions.count
        return HStack(spacing: 12) {
            ZStack {
                Image(systemName: "macwindow")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isThinking ? MacTheme.accent : MacTheme.textSecondary)
                    .frame(width: 28, height: 28)
                if isThinking {
                    SpinningArc(tint: MacTheme.accent)
                        .frame(width: 28, height: 28)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(prettyPath(url))
                    .font(.caption)
                    .foregroundStyle(MacTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if sessionCount > 0 {
                sessionCountBadge(sessionCount)
            }
            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundStyle(MacTheme.textTertiary)
        }
    }

    /// Pill-style count badge next to a window row. Accent tint for active
    /// sessions, with a slightly lighter inner stroke so it reads as a
    /// distinct UI element rather than blending into the row's hover fill.
    private func sessionCountBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(MacTheme.textPrimary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 5)
            .background(MacTheme.accent.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(MacTheme.accent.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel("\(count) session\(count == 1 ? "" : "s")")
    }

    /// "~/Desktop/Project" style truncation for the window subtitle.
    private func prettyPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.deletingLastPathComponent().path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Actions
    //
    // Trimmed to just Quit per user request. The Settings entry was
    // removed because it was never the natural entry path from this
    // popover — Settings is reachable from the standard ⌘, shortcut,
    // the in-app gear icon, and the Dock menu. "Pair iPhone…" was
    // removed earlier for the same reason. Approvals section also
    // doesn't live here — pending approvals already surface as a
    // system notification + the in-window approval card, so
    // duplicating them in this menu just added clutter.

    private var actionsSection: some View {
        VStack(spacing: 2) {
            actionRow(icon: "power", title: "Quit DNP Remote", tint: MacTheme.danger) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }

    private func actionRow(icon: String,
                           title: String,
                           tint: Color = .primary,
                           action: @escaping () -> Void) -> some View {
        let resolvedIconTint = tint == .primary ? MacTheme.textSecondary : tint
        let resolvedTextTint = tint == .primary ? MacTheme.textPrimary   : tint
        return HoverableMenuRow(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(resolvedIconTint)
                    .frame(width: 22)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(resolvedTextTint)
                Spacer()
            }
        }
    }

    private func focusProjectWindow(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "project", value: url.standardizedFileURL)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(0.7)
                .foregroundStyle(MacTheme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }
}

/// Continuously-rotating arc overlay rendered behind the window-row icon
/// while Claude is actively processing in that project. Same idiom the
/// sidebar `ContextRing.RunningSpinnerOverlay` uses — own `@State` so the
/// rotation lifecycle is structural (created when `isThinking` flips true,
/// torn down when it flips false). 1-second cycle to read as "alive,
/// working" without becoming visually noisy.
private struct SpinningArc: View {
    let tint: Color
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.30)
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// Apple-style hoverable row used by the menu-bar popover for sessions and
/// quick-action items. Mirrors how macOS Notification Center widgets,
/// Spotlight result rows, and Finder sidebar entries respond to the cursor:
/// a soft rounded fill that fades in over ~120ms.
private struct HoverableMenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.07) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
