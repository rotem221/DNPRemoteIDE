import SwiftUI

struct SessionFeedPaneView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    var body: some View {
        SidebarPanel(
            title: "Event Feed",
            icon: "list.bullet.rectangle",
            trailing: {
                Text("\(vm.eventsForSelected().count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MacTheme.textTertiary)
            },
            content: {
                if vm.eventsForSelected().isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.dashed")
                            .font(.largeTitle).foregroundStyle(MacTheme.textTertiary)
                        Text("No events yet").foregroundStyle(MacTheme.textSecondary)
                        Text("Start a session and run a command, or send a prompt from iPhone.")
                            .font(.caption).foregroundStyle(MacTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(vm.eventsForSelected()) { e in
                                FeedRowMac(event: e)
                            }
                        }
                        .padding(12)
                    }
                    // Always-visible vertical scroll indicator. The
                    // default `.automatic` hides the scroller until
                    // the user scrolls, which made the bar appear to
                    // "jump in" when the sidebar collapsed or the
                    // window narrowed. Pinning it visible keeps the
                    // pane width predictable across all resize paths
                    // — same intent as SwiftTerm's `.legacy` scroller
                    // style on the terminal pane.
                    .scrollIndicators(.visible, axes: .vertical)
                    // Force a fresh ScrollView when the user switches sessions so the lazy
                    // diff doesn't carry rows from the previous session into the new context.
                    .id(workspace.selectedSessionId)
                }
            }
        )
    }
}

struct FeedRowMac: View {
    let event: SessionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(event.title).font(.callout).foregroundStyle(MacTheme.textPrimary)
                Spacer()
                if case .codeEdit(let p)? = event.payload {
                    DiffStatChips(added: p.linesAdded, removed: p.linesRemoved)
                }
                Text(time).font(.caption2.monospacedDigit()).foregroundStyle(MacTheme.textTertiary)
            }
            // Code-edit events get the rich Cursor-style unified diff. Everything else
            // falls back to the plain summary string.
            if case .codeEdit(let p)? = event.payload, let diff = p.diffPreview, !diff.isEmpty {
                DiffPreviewView(diff: diff)
            } else if let s = event.summary {
                Text(s).font(.caption).foregroundStyle(MacTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch event.type {
        case .userMessage: return "person.fill"
        case .assistantMessage: return "sparkles"
        case .thinkingSummary: return "cloud.fill"
        case .commandStarted, .commandOutput, .commandCompleted: return "terminal.fill"
        case .codeEditSummary: return "pencil.and.ruler"
        case .fileChanged: return "doc.fill"
        case .toolActivity: return "hammer.fill"
        case .approvalRequired: return "shield.lefthalf.filled"
        case .approvalResult: return "shield"
        case .warning: return "exclamationmark.triangle.fill"
        case .error, .crash: return "xmark.octagon.fill"
        case .contextUpdate: return "gauge"
        case .sessionStarted: return "play.circle"
        case .sessionEnded: return "stop.circle"
        default: return "circle.dashed"
        }
    }

    private var color: Color {
        switch event.severity {
        case .warning: return MacTheme.warning
        case .error, .critical: return MacTheme.danger
        case .notice: return MacTheme.accent
        case .debug: return MacTheme.textTertiary
        case .info: return MacTheme.textSecondary
        }
    }

    private var time: String {
        Self.timestampFormatter.string(from: event.timestamp)
    }

    /// Static so SwiftUI doesn't allocate a fresh `DateFormatter` per row per render.
    /// During a busy session the feed renders dozens of rows per second and the previous
    /// per-call instantiation showed up as real heap churn in Instruments.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Cursor-style unified-diff renderer. Each line is one row, with a translucent green
/// fill for additions, red for deletions, neutral for context. The leading `+` / `-`
/// glyph is preserved (just like a real `git diff`) so the user can paste the rendered
/// text into any other tool and have it round-trip cleanly.
///
/// Performance notes: we cap the number of rendered lines so a 5,000-line write doesn't
/// freeze the feed pane — past the cap we collapse the rest into a "+ N more lines"
/// footer. The rendered rows are plain `Text` views (not `TextEditor`/`NSTextView`) so
/// the Mac event pane stays cheap to layout.
struct DiffPreviewView: View {
    let diff: String
    /// Soft cap to keep huge writes from melting the feed. 200 rows is well past the
    /// "context window" most edits show; users who really need to see the full diff can
    /// open the file from the explorer.
    private let maxLines = 200

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let visible = Array(lines.prefix(maxLines))
        let overflow = max(0, lines.count - maxLines)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                DiffLine(text: line)
            }
            if overflow > 0 {
                Text("… \(overflow) more line\(overflow == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MacTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.background.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(MacTheme.border.opacity(0.45), lineWidth: 0.5)
        )
    }
}

/// One row of `DiffPreviewView`. Adopts a different fill + sigil colour depending on
/// whether the leading char is `+` (addition), `-` (deletion), or anything else
/// (unchanged context — rare in our `LineDiff` output but kept for parity with stock
/// unified diffs).
private struct DiffLine: View {
    let text: String

    var body: some View {
        let kind = classify(text)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Sigil column — fixed width so all rows align even when context lines have
            // no prefix character of their own.
            Text(kind.sigil)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(kind.sigilColor)
                .frame(width: 10, alignment: .leading)
            // Strip the leading +/- so we don't render it twice (sigil column shows it).
            Text(stripped(text, kind: kind))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(kind.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .background(kind.fill)
    }

    private enum Kind {
        case added, removed, context
        var sigil: String {
            switch self { case .added: return "+"; case .removed: return "−"; case .context: return " " }
        }
        var sigilColor: Color {
            switch self {
            case .added:   return Color(red: 0.40, green: 0.85, blue: 0.50)
            case .removed: return Color(red: 0.95, green: 0.45, blue: 0.45)
            case .context: return MacTheme.textTertiary
            }
        }
        var textColor: Color {
            switch self {
            case .added:   return Color(red: 0.74, green: 0.94, blue: 0.78)
            case .removed: return Color(red: 0.97, green: 0.74, blue: 0.74)
            case .context: return MacTheme.textSecondary
            }
        }
        var fill: Color {
            switch self {
            case .added:   return Color(red: 0.20, green: 0.60, blue: 0.30).opacity(0.18)
            case .removed: return Color(red: 0.70, green: 0.20, blue: 0.20).opacity(0.18)
            case .context: return .clear
            }
        }
    }

    private func classify(_ s: String) -> Kind {
        if s.hasPrefix("+") { return .added }
        if s.hasPrefix("-") { return .removed }
        return .context
    }

    private func stripped(_ s: String, kind: Kind) -> String {
        switch kind {
        case .added, .removed: return s.isEmpty ? "" : String(s.dropFirst())
        case .context:         return s
        }
    }
}

/// Two compact pills — `+N` (green) and `-N` (red) — pinned to the far right of a
/// code-edit row's header. Mirrors GitHub's PR file-diff badges.
private struct DiffStatChips: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                statChip(symbol: "+", count: added,
                         tint: Color(red: 0.40, green: 0.85, blue: 0.50))
            }
            if removed > 0 {
                statChip(symbol: "−", count: removed,
                         tint: Color(red: 0.95, green: 0.45, blue: 0.45))
            }
        }
    }

    private func statChip(symbol: String, count: Int, tint: Color) -> some View {
        Text("\(symbol)\(count)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

// MARK: - History pane

/// Project-wide chronological timeline. Renders every `SessionEvent` from
/// every session in the workspace's project as a single ordered list,
/// newest-first, styled like the muxy / git-log timeline the user shared:
///
///   • a colored bullet on a thin vertical rail down the left edge
///   • a bold title (the event's `title`)
///   • optional severity / type chips next to the title
///   • a quiet "session · relative time" subtitle underneath
///
/// Tapping a row jumps to the source session and switches the workspace
/// to its terminal pane so the user lands on the live state behind the
/// historical entry.
struct ProjectHistoryPaneView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController
    @State private var filter: HistoryFilter = .all

    /// Filters that mirror the user-facing event categories. Hand-curated
    /// (rather than `CaseIterable` over `SessionEventType`) so the filter
    /// chip strip reads as a short, scannable row instead of a 12-pill wall.
    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all, messages, tools, edits, approvals, alerts
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .messages: return "Messages"
            case .tools: return "Tools"
            case .edits: return "Edits"
            case .approvals: return "Approvals"
            case .alerts: return "Alerts"
            }
        }

        func includes(_ event: SessionEvent) -> Bool {
            switch self {
            case .all: return true
            case .messages:
                return event.type == .userMessage
                    || event.type == .assistantMessage
                    || event.type == .thinkingSummary
            case .tools:
                return event.type == .toolActivity
                    || event.type == .commandStarted
                    || event.type == .commandOutput
                    || event.type == .commandCompleted
            case .edits:
                return event.type == .codeEditSummary || event.type == .fileChanged
            case .approvals:
                return event.type == .approvalRequired || event.type == .approvalResult
            case .alerts:
                return event.severity == .warning
                    || event.severity == .error
                    || event.severity == .critical
                    || event.type == .crash
            }
        }
    }

    var body: some View {
        SidebarPanel(
            title: "History",
            icon: "clock.arrow.circlepath",
            trailing: {
                Text("\(allEvents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MacTheme.textTertiary)
            },
            content: {
                VStack(alignment: .leading, spacing: 0) {
                    filterStrip
                    Divider().background(MacTheme.border.opacity(0.5))
                    if visibleEvents.isEmpty {
                        emptyState
                    } else {
                        timeline
                    }
                }
            }
        )
    }

    // MARK: Filter strip

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HistoryFilter.allCases) { f in
                    FilterChip(
                        label: f.label,
                        active: filter == f,
                        count: count(for: f)
                    ) { filter = f }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(MacTheme.textTertiary)
            Text("No history yet").foregroundStyle(MacTheme.textSecondary)
            Text("Run a command, send a prompt, or let Claude touch a file — every step lands here.")
                .font(.caption)
                .foregroundStyle(MacTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { idx, event in
                    HistoryRow(
                        event: event,
                        sessionTitle: sessionTitle(for: event.sessionId),
                        isFirst: idx == 0,
                        isLast: idx == visibleEvents.count - 1,
                        onTap: { focus(event) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: Data plumbing

    /// Every event from every session in this workspace's project,
    /// flattened and sorted newest-first.
    private var allEvents: [SessionEvent] {
        let sessionIds = Set(workspace.sessions.map(\.id))
        var out: [SessionEvent] = []
        for (sid, events) in workspace.feed where sessionIds.contains(sid) {
            out.append(contentsOf: events)
        }
        return out.sorted { $0.timestamp > $1.timestamp }
    }

    private var visibleEvents: [SessionEvent] {
        allEvents.filter { filter.includes($0) }
    }

    private func count(for f: HistoryFilter) -> Int {
        allEvents.lazy.filter { f.includes($0) }.count
    }

    private func sessionTitle(for sessionId: UUID) -> String {
        workspace.sessions.first(where: { $0.id == sessionId })?.title ?? "Session"
    }

    /// Jump back to the live session that produced this entry. Uses
    /// `switchToSession` so a click on an event whose session isn't
    /// in the current split layout collapses the splits and shows the
    /// session full-bleed — same rule the sidebar and palette follow.
    private func focus(_ event: SessionEvent) {
        workspace.switchToSession(event.sessionId)
        workspace.workspacePane = .terminal
    }
}

/// A single row inside the project-history timeline. Renders the bullet,
/// the optional vertical rail above and below it (so the bullets read as
/// nodes on a continuous line, not isolated dots), and the title +
/// metadata block on the right.
private struct HistoryRow: View {
    let event: SessionEvent
    let sessionTitle: String
    let isFirst: Bool
    let isLast: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                rail
                content
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? MacTheme.surfaceAlt.opacity(0.6) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Vertical rail with a colored node at the row's vertical center.
    /// The line clips at the very top of the first row and the very
    /// bottom of the last row so the timeline reads as a finite track
    /// rather than running off-screen.
    private var rail: some View {
        ZStack(alignment: .top) {
            // Vertical line — drawn full-height, then masked at the top
            // for the first row and at the bottom for the last row.
            Rectangle()
                .fill(MacTheme.border.opacity(0.55))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .padding(.top, isFirst ? 12 : 0)
                .padding(.bottom, isLast ? 12 : 0)
            // Node dot — the timeline marker for this event.
            Circle()
                .fill(nodeColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .strokeBorder(MacTheme.background, lineWidth: 1.5)
                )
                .padding(.top, 8)
        }
        .frame(width: 14)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                severityChip
                typeChip
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(MacTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 6) {
                Text(sessionTitle)
                    .font(.caption2)
                    .foregroundStyle(MacTheme.textTertiary)
                    .lineLimit(1)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(MacTheme.textTertiary)
                Text(Self.relativeFormatter.localizedString(for: event.timestamp,
                                                             relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(MacTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var severityChip: some View {
        switch event.severity {
        case .warning:  HistoryChip(text: "warning",  tint: MacTheme.warning)
        case .error:    HistoryChip(text: "error",    tint: MacTheme.danger)
        case .critical: HistoryChip(text: "critical", tint: MacTheme.danger)
        default:        EmptyView()
        }
    }

    private var typeChip: some View {
        HistoryChip(text: typeLabel, tint: nodeColor)
    }

    private var typeLabel: String {
        switch event.type {
        case .userMessage: return "user"
        case .assistantMessage: return "assistant"
        case .thinkingSummary: return "thinking"
        case .commandStarted, .commandOutput, .commandCompleted: return "command"
        case .codeEditSummary: return "edit"
        case .fileChanged: return "file"
        case .toolActivity: return "tool"
        case .approvalRequired: return "approval"
        case .approvalResult: return "decision"
        case .warning: return "warning"
        case .error: return "error"
        case .crash: return "crash"
        case .contextUpdate: return "context"
        case .sessionStarted: return "started"
        case .sessionEnded: return "ended"
        default: return "event"
        }
    }

    private var nodeColor: Color {
        switch event.severity {
        case .warning: return MacTheme.warning
        case .error, .critical: return MacTheme.danger
        case .notice: return MacTheme.accent
        case .debug: return MacTheme.textTertiary
        case .info: return MacTheme.textSecondary
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Filter chip used by both the history filter strip and the per-row
/// type/severity tags. Same shape across both so the filter "active"
/// state visually matches what the rows are tagged with.
private struct HistoryChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
            )
    }
}

private struct FilterChip: View {
    let label: String
    let active: Bool
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(active ? MacTheme.textPrimary.opacity(0.7) : MacTheme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(active ? MacTheme.textPrimary : MacTheme.textSecondary)
            .background(
                Capsule(style: .continuous)
                    .fill(active
                          ? MacTheme.accent.opacity(0.22)
                          : (hovering ? MacTheme.surfaceAlt.opacity(0.8) : MacTheme.surfaceAlt.opacity(0.5)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active ? MacTheme.accent.opacity(0.55) : MacTheme.border.opacity(0.4),
                                  lineWidth: active ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
