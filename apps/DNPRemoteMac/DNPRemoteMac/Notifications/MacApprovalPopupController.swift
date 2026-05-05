import AppKit
import SwiftUI

/// Center-of-screen Liquid Glass approval popup for the Mac. The previous implementation
/// was a top-right `NSPanel` with macOS title-bar chrome (traffic-light area visible);
/// the user wanted the same calm Liquid Glass card we use on iOS — center-of-screen,
/// borderless, no chrome, no traffic-light buttons. This controller now mirrors the iOS
/// `IOSApprovalCenterOverlay` 1:1 in shape and behavior, on the Mac as a borderless
/// `NSPanel` pinned to `.floating`.
///
/// Behavior:
/// - Borderless (no `.titled`, no `.closable`) so there's no Mac chrome up top.
/// - Translucent background via SwiftUI's `.regularMaterial` (system Liquid Glass).
/// - Centered on the active screen.
/// - Auto-dismissed when the request is decided here, on iOS, or via the system
///   notification action — keeps every surface in sync.
@MainActor
final class MacApprovalPopupController {
    static let shared = MacApprovalPopupController()

    /// Active panels keyed by approval id. Multiple concurrent approvals stack with a
    /// vertical offset so they're all visible without overlapping.
    private var panels: [UUID: NSPanel] = [:]

    private init() {}

    func present(approvalId: UUID,
                 sessionTitle: String,
                 summary: String,
                 risk: RiskLevel,
                 actionType: ApprovalActionType,
                 onApprove: @escaping () -> Void,
                 onDeny: @escaping () -> Void) {
        guard prefBool("dnp.mac.approvalsFloatingPanel", default: false) else { return }
        guard panels[approvalId] == nil else { return }
        // Skip the popup whenever the IDE is the foreground app at all — per the
        // user's rule: "if you're INSIDE the IDE, no notifications and no approval
        // popup, the in-app surfaces are enough." Even if the user is in a different
        // project's window, they're still in the app and can switch via Window menu /
        // dock. The popup is reserved for the case where the IDE is in the background
        // or another app is foreground — that's where the user genuinely needs the
        // attention-grab.
        if NSApp.isActive { return }

        // Borderless panel with a clear background — the Liquid Glass material is rendered
        // by SwiftUI inside the content view, NOT by the window itself. The window has to
        // be transparent (`isOpaque = false` + `backgroundColor = .clear`) so the rounded
        // corners + material show through to the desktop instead of sitting on top of an
        // opaque grey rectangle.
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 220
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        // `.floating` keeps it above the app's normal windows without the focus-stealing
        // intrusiveness of `.statusBar` / `.popUpMenu`.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: MacApprovalCenterCard(
            sessionTitle: sessionTitle,
            summary: summary,
            risk: risk,
            actionType: actionType,
            onApprove: { [weak self] in
                onApprove()
                self?.dismiss(approvalId: approvalId)
            },
            onDeny: { [weak self] in
                onDeny()
                self?.dismiss(approvalId: approvalId)
            },
            onClose: { [weak self] in
                self?.dismiss(approvalId: approvalId)
            }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        panels[approvalId] = panel
        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    func dismiss(approvalId: UUID) {
        guard let panel = panels.removeValue(forKey: approvalId) else { return }
        panel.orderOut(nil)
    }

    func dismissAll() {
        for (_, panel) in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    /// Center on the active screen. Multiple concurrent approvals fan out vertically by
    /// half a card-height each so they remain individually clickable instead of stacking
    /// directly on top of each other.
    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let stackIndex = max(0, panels.count - 1)
        let xCenter = visibleFrame.midX - panelSize.width / 2
        let yCenter = visibleFrame.midY - panelSize.height / 2
        let yOffset = CGFloat(stackIndex) * (panelSize.height * 0.55)
        panel.setFrameOrigin(NSPoint(x: xCenter, y: yCenter - yOffset))
    }

    private func prefBool(_ key: String, default def: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return def }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// SwiftUI body of the centered Liquid Glass approval card. Visually mirrors
/// `IOSApprovalCenterOverlay` 1:1 — same icon shape, same risk pill, same Approve / Deny
/// affordances — so the user sees the same prompt whether the request reached them on
/// iOS or the Mac. Borderless on macOS = no chrome, no traffic-light buttons.
private struct MacApprovalCenterCard: View {
    let sessionTitle: String
    let summary: String
    let risk: RiskLevel
    let actionType: ApprovalActionType
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onClose: () -> Void

    /// Pick button wording that mirrors Claude's TUI prompt language.
    /// Tool permissions → "Allow / Don't Allow"; generic → "Yes / No".
    fileprivate func buttonLabels(for risk: RiskLevel,
                                  actionType: ApprovalActionType) -> (approve: String, deny: String) {
        switch actionType {
        case .bashCommand, .fileWrite, .fileEdit, .fileDelete, .mcpTool, .webFetch:
            return ("Allow", "Don't Allow")
        case .other:
            return ("Yes", "No")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — risk-tinted glyph + title + session subtitle. Mirrors the iOS
            // overlay's hierarchy so the user reads the same shape across surfaces.
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(riskTint.opacity(0.22))
                        .frame(width: 40, height: 40)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(riskTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval needed")
                        .font(.headline)
                        .foregroundStyle(MacTheme.textPrimary)
                    Text(sessionTitle)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                riskPill
                // Tiny dismiss control. We deliberately keep this small — it replaces
                // the macOS close (×) button we removed by going borderless, but it's a
                // soft "hide" affordance, not a destructive cancel: tapping it just
                // closes the popup; the request stays pending until decided in-app or
                // via the system banner.
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MacTheme.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(MacTheme.surface.opacity(0.5),
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .help("Hide popup (decision still pending)")
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)

            // Summary — capped to 4 lines so an ambitious tool target (e.g. a multi-line
            // paste) can't push the action row off-screen. Truncation is tail.
            Text(summary)
                .font(.callout)
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)

            // Action row — labels mirror Claude Code's actual TUI prompt:
            //   tool permissions (Bash, file edits, web fetch, MCP) → "Allow / Don't Allow"
            //   generic confirmation (.other)                       → "Yes / No"
            // The PTY keystroke (`1\r` / `2\r`) is the same either way; only the visible
            // wording changes so the user sees the same language they'd see in the IDE.
            let labels = buttonLabels(for: risk, actionType: actionType)
            HStack(spacing: 10) {
                Button {
                    onDeny()
                } label: {
                    Text(labels.deny)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MacTheme.danger)
                .background(MacTheme.danger.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    onApprove()
                } label: {
                    Text(labels.approve)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(MacTheme.accent,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        // Liquid Glass body. `.regularMaterial` is the macOS analog of iOS's
        // `.ultraThinMaterial` — translucent, picks up the desktop wallpaper / windows
        // behind the card. Soft hairline outline + drop shadow give it presence without
        // looking like a heavy modal.
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 18)
    }

    @ViewBuilder
    private var riskPill: some View {
        Text(risk.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(riskTint, in: Capsule())
    }

    private var riskTint: Color {
        switch risk {
        case .low:      return MacTheme.success
        case .medium:   return MacTheme.accent
        case .high:     return MacTheme.warning
        case .critical: return MacTheme.danger
        }
    }
}
