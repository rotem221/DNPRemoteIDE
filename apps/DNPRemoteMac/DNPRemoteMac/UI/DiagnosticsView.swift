import SwiftUI
import Darwin
import Foundation

/// Diagnostics dashboard. Visual language matches `MacSettingsView` — same
/// `SettingsCard` chrome, same `MacTheme.groupedBackground` page tone — so the two
/// pages feel like sibling tabs.
///
/// Why this isn't using SwiftUI Charts: an earlier version did, and on macOS 14 it
/// produced AttributeGraph cycles plus a frozen tab. The Charts mixed-mark
/// (`LineMark` + `AreaMark`) ForEach pattern over a 60-sample rolling window kept
/// re-laying out on every `@Published` change, and with five separate published
/// fields landing per second the dependency graph never settled. The custom
/// `MiniAreaChart` below draws a single `Path` per sample buffer in a `Canvas` —
/// no observable framework, no per-mark re-layout, ~zero invalidation churn.
///
/// Why the sampler publishes a single struct instead of seven separate fields:
/// SwiftUI batches @Published updates, but each one schedules a render pass for
/// every observer — and `DiagnosticsView` reads all seven, so seven mutations per
/// tick = seven render passes. Bundling them into one `Snapshot` collapses that to
/// one render pass per tick.
struct DiagnosticsView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @StateObject private var sampler = ResourceSampler()
    @State private var storage: StorageStats = .zero
    /// Tailscale status is probed by shelling out to the `tailscale` CLI — that's a
    /// blocking `Process.waitUntilExit()` call that takes tens-to-hundreds of ms and
    /// MUST NOT happen on the main thread or inside a view body. The previous version
    /// called `TailscaleService.currentStatus()` directly inside `trafficRow`, so every
    /// 1 Hz sampler tick re-rendered that row and re-spawned three child processes on
    /// the main thread — the page froze on entry. We now snapshot it once in `.task`
    /// off the main actor and only re-fetch on explicit Refresh.
    @State private var tailscale: TailscaleService.Status = .init(ipv4: nil, hostname: nil)
    /// Stable Y-axis ceiling for memory — total physical RAM. Computed once on view
    /// init so the chart never re-domains while a sample lands.
    private let memoryCeiling: Double = Double(ProcessInfo.processInfo.physicalMemory)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                runtimeRow
                claudeUsageRow
                graphsRow
                trafficRow
                storageCard
                if !vm.diagnostics.issues.isEmpty { issuesCard }
                Spacer(minLength: 32)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacTheme.groupedBackground)
        .task {
            // `.task` runs AFTER the first frame has rendered, on a different scope
            // from view updates — that's the cleanest way to kick off published-state
            // mutations from `@StateObject` without tripping "Modifying state during
            // view update". Cancellation hooks into the view's lifecycle automatically:
            // when the user navigates away, the task is cancelled and the timer torn
            // down via `stop()`'s defer block.
            sampler.start()
            refreshStorage()
            refreshTailscale()
            defer { sampler.stop() }
            // Keep the task alive for the lifetime of the view. The Timer drives
            // the actual sampling cadence; this just owns the lifecycle.
            // Parentheses around the AsyncStream init disambiguate the
            // trailing closure — without them Swift warns that the
            // first `{ _ in }` could be read as the for-loop body.
            for await _ in (AsyncStream<Void> { _ in }) { _ = () }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(MacTheme.accent)
                .frame(width: 56, height: 56, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostics").font(.title.bold()).foregroundStyle(MacTheme.textPrimary)
                Text("Runtime health, live resource usage, and connectivity.")
                    .font(.callout).foregroundStyle(MacTheme.textSecondary)
            }
            Spacer()
            Button("Refresh") {
                sampler.kickSample()
                refreshStorage()
                refreshTailscale()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Row 1: runtime info
    //
    // Three compact status cards. Each card surfaces only the two highest-signal
    // facts for its area — Settings already shows the verbose path/version
    // breakdown, so Diagnostics keeps it minimal so the row reads at a glance
    // without scrolling past redundant info. `.frame(maxHeight: .infinity, alignment: .top)`
    // on each card stretches the shorter cards to match the tallest one in the
    // row, so the bottom edges align perfectly even when one card has a one-line
    // overflow (e.g. a long status string).

    private var runtimeRow: some View {
        HStack(alignment: .top, spacing: 14) {
            equalHeight {
                SettingsCard(title: "Claude", icon: "sparkles") {
                    infoRow("Version", vm.diagnostics.claudeVersion ?? "—", mono: true)
                    infoRow("PTY",
                            vm.diagnostics.ptyAvailable ? "available" : "unavailable",
                            tint: vm.diagnostics.ptyAvailable ? MacTheme.success : MacTheme.danger)
                }
            }
            equalHeight {
                SettingsCard(title: "Bridge", icon: "network") {
                    infoRow("Port", vm.diagnostics.bridgePort.map(String.init) ?? "—", mono: true)
                    infoRow("Status", bridgeStatusText, tint: bridgeStatusTint)
                }
            }
            equalHeight {
                SettingsCard(title: "Sessions", icon: "rectangle.stack") {
                    let active = vm.sessions.filter { $0.status != .ended }.count
                    infoRow("Active", "\(active) running")
                    infoRow("Pending", "\(vm.pendingApprovals.count)",
                            tint: vm.pendingApprovals.isEmpty ? nil : MacTheme.warning)
                }
            }
        }
    }

    /// Makes its child fill the trailing height of an `HStack`, so cards in the
    /// same row end at the same Y. Without this, `SettingsCard` self-sizes to
    /// content height and rows with a 2-row card next to a 4-row card look
    /// stair-stepped. Content stays pinned to the top via the inner card's
    /// `VStack`; only the card's background rectangle stretches, which is the
    /// visual we want — even rectangles, content sitting at top.
    @ViewBuilder
    private func equalHeight<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Row 2: Claude usage
    //
    // Surfaces the SAME `AIUsageSnapshot` data the status-bar `aiUsagePill` and
    // its popover already render — the four quota windows Anthropic returns
    // from `/api/oauth/usage` (5h, 7d, 7d Sonnet, 7d Omelette / Opus) plus the
    // optional `extra_usage` overflow. Source of truth is
    // `MacAppViewModel.aiUsage`, refreshed every 5 min by `ClaudeUsageService`
    // and cached in memory; we just reuse `MacAIUsagePopoverRow` so the row
    // layout (label · big % · "X.X% used" · resets HH:MM · tinted progress
    // bar) stays bit-identical to what the user already sees in the popover.
    // The "Refresh" button calls `refreshAIUsage()` which kicks the same
    // service off-cycle so the user doesn't have to wait for the timer.

    private var claudeUsageRow: some View {
        SettingsCard(title: "Claude usage", icon: "sparkles") {
            claudeUsageHeader
            Divider().background(MacTheme.border).padding(.vertical, 2)
            claudeUsageBody
        }
    }

    /// Title strip for the Claude-usage card: provider name on the left
    /// (e.g. "Claude Code"), relative-fetched stamp + Refresh on the right.
    /// Mirrors `MacAIUsagePopover`'s top row so the two surfaces feel like
    /// the same widget rendered in two places.
    @ViewBuilder
    private var claudeUsageHeader: some View {
        HStack(spacing: 8) {
            Text(vm.aiUsage?.providerName ?? "Claude Code")
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacTheme.textPrimary)
            Spacer()
            if let stamp = claudeUsageRelativeStamp {
                Text(stamp)
                    .font(.caption)
                    .foregroundStyle(MacTheme.textTertiary)
            }
            Button {
                Task { await vm.refreshAIUsage() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    /// Body of the Claude-usage card. Three branches:
    ///   • snapshot has windows → render one `MacAIUsagePopoverRow` per
    ///     window, exactly as the status-bar popover does.
    ///   • snapshot exists but has an `errorMessage` (token expired, no
    ///     keychain match, etc.) → surface the error verbatim so the user
    ///     can act on it without having to open the popover.
    ///   • snapshot is `nil` (first launch, before the 5-min timer fired)
    ///     → "loading" placeholder; refreshing populates it.
    @ViewBuilder
    private var claudeUsageBody: some View {
        if let usage = vm.aiUsage {
            if let err = usage.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MacTheme.warning)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(MacTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if usage.windows.isEmpty {
                Text("No quota windows reported yet — Anthropic returns them after your first authenticated request.")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(usage.windows, id: \.label) { window in
                        MacAIUsagePopoverRow(window: window)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching usage from Claude Code…")
                    .font(.callout)
                    .foregroundStyle(MacTheme.textSecondary)
                Spacer()
            }
        }
    }

    /// "just now" / "3 min ago" label for the last-fetched timestamp, same
    /// formatter the popover uses so both surfaces report time identically.
    private var claudeUsageRelativeStamp: String? {
        guard let date = vm.aiUsage?.fetchedAt else { return nil }
        let secs = -date.timeIntervalSinceNow
        if secs < 60 { return "just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins) min ago" }
        return "\(mins / 60)h ago"
    }

    // MARK: - Row 2: live charts

    private var graphsRow: some View {
        let s = sampler.snapshot
        return HStack(alignment: .top, spacing: 14) {
            equalHeight {
                SettingsCard(title: "Memory", icon: "memorychip") {
                    MiniAreaChart(samples: s.memorySamples,
                                  yMax: memoryCeiling,
                                  tint: MacTheme.accent,
                                  currentLabel: byteString(s.currentMemoryBytes))
                    statTriple(items: [
                        ("Process", byteString(s.currentMemoryBytes)),
                        ("Peak",    byteString(s.memoryPeakBytes)),
                        ("System",  byteString(s.systemMemoryUsedBytes))
                    ])
                }
            }
            equalHeight {
                SettingsCard(title: "CPU", icon: "cpu") {
                    MiniAreaChart(samples: s.cpuSamples,
                                  yMax: 100,
                                  tint: cpuTint(for: s.currentCPUPercent),
                                  currentLabel: String(format: "%.1f%%", s.currentCPUPercent))
                    statTriple(items: [
                        ("Current", String(format: "%.1f%%", s.currentCPUPercent)),
                        ("Peak",    String(format: "%.1f%%", s.cpuPeakPercent)),
                        ("Cores",   "\(ProcessInfo.processInfo.activeProcessorCount)")
                    ])
                }
            }
        }
    }

    // MARK: - Row 3: events + tailscale
    //
    // Tailscale is collapsed from a three-line "Daemon / Hostname / IPv4" block
    // to two lines — the daemon-state row was redundant once the IPv4/hostname
    // values themselves convey "online" through their green tint and "offline"
    // through dashes. Settings still has the full breakdown for users that
    // want it.

    private var trafficRow: some View {
        HStack(alignment: .top, spacing: 14) {
            equalHeight {
                SettingsCard(title: "Event traffic", icon: "tray.full") {
                    let totals = eventTotals()
                    statQuad(items: [
                        ("Events", "\(totals.events)", MacTheme.textPrimary),
                        ("Errors", "\(totals.errors)",
                         totals.errors > 0 ? MacTheme.danger : MacTheme.textSecondary),
                        ("Warnings", "\(totals.warnings)",
                         totals.warnings > 0 ? MacTheme.warning : MacTheme.textSecondary),
                        ("Approvals", "\(totals.approvals)", MacTheme.textSecondary)
                    ])
                }
            }
            equalHeight {
                SettingsCard(title: "Tailscale", icon: "antenna.radiowaves.left.and.right") {
                    let connected = (tailscale.ipv4?.isEmpty == false) || (tailscale.hostname?.isEmpty == false)
                    infoRow("Hostname", tailscale.hostname ?? "—",
                            tint: connected ? MacTheme.success : MacTheme.textTertiary,
                            mono: true)
                    infoRow("IPv4", tailscale.ipv4 ?? "Offline",
                            tint: connected ? MacTheme.success : MacTheme.textTertiary,
                            mono: true)
                }
            }
        }
    }

    private var storageCard: some View {
        SettingsCard(title: "Local storage", icon: "externaldrive") {
            HStack(alignment: .top, spacing: 14) {
                storageBar("Sessions",     bytes: storage.sessionsBytes,    accent: MacTheme.accent)
                storageBar("Transcripts",  bytes: storage.transcriptsBytes, accent: MacTheme.success)
                storageBar("Memory notes", bytes: storage.memoryBytes,      accent: MacTheme.warning)
                storageBar("Crashes",      bytes: storage.crashesBytes,     accent: MacTheme.danger)
            }
        }
    }

    private var issuesCard: some View {
        SettingsCard(title: "Issues", icon: "exclamationmark.triangle.fill") {
            ForEach(Array(vm.diagnostics.issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MacTheme.warning)
                        .padding(.top, 2)
                    Text(issue)
                        .font(.callout)
                        .foregroundStyle(MacTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Building blocks

    private func infoRow(_ label: String, _ value: String,
                          tint: Color? = nil, mono: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(MacTheme.textSecondary).font(.subheadline)
            Spacer()
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .subheadline)
                .foregroundStyle(tint ?? MacTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func statTriple(items: [(String, String)]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ForEach(0..<items.count, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(items[i].0).font(.caption2).foregroundStyle(MacTheme.textTertiary)
                    Text(items[i].1).font(.callout.monospacedDigit())
                        .foregroundStyle(MacTheme.textPrimary)
                }
                if i != items.count - 1 { Spacer(minLength: 0) }
            }
        }
        .padding(.top, 4)
    }

    private func statQuad(items: [(String, String, Color)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            ForEach(0..<items.count, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[i].0).font(.caption).foregroundStyle(MacTheme.textTertiary)
                    Text(items[i].1)
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(items[i].2)
                }
                if i != items.count - 1 { Spacer(minLength: 0) }
            }
        }
    }

    private func storageBar(_ label: String, bytes: Int64, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(MacTheme.textTertiary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.callout.monospacedDigit())
                .foregroundStyle(MacTheme.textPrimary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(MacTheme.surfaceAlt)
                    RoundedRectangle(cornerRadius: 3).fill(accent)
                        .frame(width: geo.size.width * proportion(of: bytes))
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived values

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func proportion(of bytes: Int64) -> CGFloat {
        let m = max(storage.sessionsBytes, storage.transcriptsBytes,
                    storage.memoryBytes, storage.crashesBytes)
        guard m > 0 else { return 0 }
        return CGFloat(Double(bytes) / Double(m))
    }

    private var bridgeStatusText: String {
        switch vm.bridgeStatus {
        case .connected: return "Listening"
        case .connecting, .discovering, .authenticating: return "Connecting"
        case .degraded:  return "Degraded"
        case .error:     return "Error"
        case .offline:   return "Offline"
        }
    }
    private var bridgeStatusTint: Color {
        switch vm.bridgeStatus {
        case .connected: return MacTheme.success
        case .degraded:  return MacTheme.warning
        case .error:     return MacTheme.danger
        default:         return MacTheme.textSecondary
        }
    }
    private func cpuTint(for percent: Double) -> Color {
        switch percent {
        case 75...:    return MacTheme.danger
        case 40..<75:  return MacTheme.warning
        default:       return MacTheme.success
        }
    }

    private struct EventTotals {
        var events = 0, errors = 0, warnings = 0, approvals = 0
    }
    private func eventTotals() -> EventTotals {
        var t = EventTotals()
        for events in vm.feed.values {
            t.events += events.count
            for e in events {
                if e.severity == .error || e.severity == .critical || e.type == .crash {
                    t.errors += 1
                } else if e.severity == .warning {
                    t.warnings += 1
                }
                if e.type == .approvalRequired || e.type == .approvalResult {
                    t.approvals += 1
                }
            }
        }
        return t
    }

    // MARK: - Storage probe

    private struct StorageStats {
        var sessionsBytes: Int64 = 0
        var transcriptsBytes: Int64 = 0
        var memoryBytes: Int64 = 0
        var crashesBytes: Int64 = 0
        static let zero = StorageStats()
    }

    private func refreshStorage() {
        Task.detached(priority: .utility) {
            let stats = Self.computeStorage()
            await MainActor.run { self.storage = stats }
        }
    }

    /// `TailscaleService.currentStatus()` shells out (3 child processes, ~tens-of-ms
    /// each). Run it OFF the main actor and publish the result back when it finishes —
    /// never call it inline from a view body.
    private func refreshTailscale() {
        Task.detached(priority: .utility) {
            let status = TailscaleService.currentStatus()
            await MainActor.run { self.tailscale = status }
        }
    }

    private static func computeStorage() -> StorageStats {
        var s = StorageStats()
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let base = appSupport?.appendingPathComponent("DNPRemote", isDirectory: true) {
            s.sessionsBytes    = directorySize(base.appendingPathComponent("sessions"))
            s.transcriptsBytes = directorySize(base.appendingPathComponent("transcripts"))
            s.memoryBytes      = directorySize(base.appendingPathComponent("memory/notes"))
            s.crashesBytes     = directorySize(base.appendingPathComponent("memory/crashes"))
        }
        return s
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                              options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Mini area chart (Canvas-based — no Charts dependency)

/// Tiny line + area chart drawn into a `Canvas`. Replaces SwiftUI Charts here because:
///   1. Canvas builds ONE `Path` per buffer, drawn once per render — no per-sample
///      view identity, no per-mark re-layout. Charts' `ForEach { LineMark; AreaMark }`
///      pattern over a 60-element rolling window produced AttributeGraph cycles on
///      macOS 14 because each mark's identity depended on a published index.
///   2. We don't need axis ticks / legends / interactive selection — the inline
///      "current" label in the corner already conveys the live value, so Charts'
///      machinery is overkill.
private struct MiniAreaChart: View {
    let samples: [Double]
    let yMax: Double
    let tint: Color
    let currentLabel: String

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1, yMax > 0 else { return }
            let stepX = size.width / CGFloat(samples.count - 1)
            let line = Path { p in
                for (i, v) in samples.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height - CGFloat(min(v, yMax) / yMax) * size.height
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else      { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            let area = Path { p in
                p.addPath(line)
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.addLine(to: CGPoint(x: 0,         y: size.height))
                p.closeSubpath()
            }
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.32), tint.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint:   CGPoint(x: 0, y: size.height)
            ))
            ctx.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .frame(height: 84)
        .overlay(alignment: .topTrailing) {
            Text(currentLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(MacTheme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(MacTheme.surfaceAlt, in: Capsule())
                .padding(8)
        }
    }
}

// MARK: - Resource sampler

/// Single-snapshot sampler. Publishes ONE struct per tick instead of seven separate
/// `@Published` fields — that batches the dependent-view invalidations into a single
/// SwiftUI render pass per second and eliminates the "Modifying state during view
/// update" cycles the original multi-field design produced.
@MainActor
final class ResourceSampler: ObservableObject {
    struct Snapshot: Equatable {
        var memorySamples: [Double] = []
        var cpuSamples: [Double] = []
        var currentMemoryBytes: UInt64 = 0
        var memoryPeakBytes: UInt64 = 0
        var systemMemoryUsedBytes: UInt64 = 0
        var currentCPUPercent: Double = 0
        var cpuPeakPercent: Double = 0
    }

    @Published private(set) var snapshot = Snapshot()

    private let window = 60
    private var timer: Timer?
    private var lastCPUTotalSeconds: Double = 0
    private var lastCPUSampleTime: Date = .distantPast

    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kickSample() }
        }
        timer = t
        // First sample on the next runloop iteration — never inline, so this is safe
        // to call from anywhere including `.task { ... }`.
        Task { @MainActor [weak self] in self?.kickSample() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func kickSample() {
        var s = snapshot
        let mem = Self.residentMemoryBytes()
        s.currentMemoryBytes = mem
        s.memoryPeakBytes = max(s.memoryPeakBytes, mem)
        s.memorySamples = appended(s.memorySamples, value: Double(mem))

        let cpu = sampleCPU()
        s.currentCPUPercent = cpu
        s.cpuPeakPercent = max(s.cpuPeakPercent, cpu)
        s.cpuSamples = appended(s.cpuSamples, value: cpu)

        s.systemMemoryUsedBytes = Self.systemMemoryUsedBytes()
        snapshot = s
    }

    private func appended(_ buf: [Double], value: Double) -> [Double] {
        var b = buf
        b.append(value)
        if b.count > window { b.removeFirst(b.count - window) }
        return b
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size /
                                           MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func systemMemoryUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size /
                                          MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) + UInt64(stats.inactive_count)
                 + UInt64(stats.speculative_count) + UInt64(stats.purgeable_count)
        let total = ProcessInfo.processInfo.physicalMemory
        return total > free * pageSize ? total - free * pageSize : 0
    }

    private func sampleCPU() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size /
                                           MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let userSec = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let sysSec  = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        let total   = userSec + sysSec
        let now     = Date()
        defer {
            lastCPUTotalSeconds = total
            lastCPUSampleTime   = now
        }
        let elapsed = now.timeIntervalSince(lastCPUSampleTime)
        guard elapsed > 0, lastCPUSampleTime != .distantPast else { return 0 }
        let delta = total - lastCPUTotalSeconds
        return max(0, min(100, (delta / elapsed) * 100))
    }
}
