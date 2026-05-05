import SwiftUI
import AppKit

/// Main pairing surface: shows trusted devices + a "Pair iPhone" button that opens
/// the QR-and-code sheet. The sheet is the only place the QR is rendered.
struct PairingCenterView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @State private var showPairingSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actionCard
                trustedDevicesCard
                Spacer(minLength: 32)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Same Apple System Settings.app pattern the Settings page uses:
        // a slightly darker grouped tone behind the cards, with each card
        // in `MacTheme.card`. The tonal contrast lifts the cards without
        // needing heavy shadows, and the page now reads as one consistent
        // chrome system with Settings instead of an isolated surface.
        .background(MacTheme.groupedBackground)
        .sheet(isPresented: $showPairingSheet) { PairingSheet() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(MacTheme.accent)
                .frame(width: 56, height: 56, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing").font(.title.bold()).foregroundStyle(MacTheme.textPrimary)
                Text("Connect your iPhone to view sessions, approve actions, and send prompts.")
                    .font(.callout).foregroundStyle(MacTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var actionCard: some View {
        SettingsCard(title: "Pair a device", icon: "qrcode") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a new iPhone or iPad")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("Generate a QR + 6-digit code so a paired device can connect over LAN — and over Tailscale automatically when off-LAN.")
                        .font(.caption)
                        .foregroundStyle(MacTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let port = vm.bridge.port {
                        Text("Bridge listening on port \(port)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                }
                Spacer()
                Button { showPairingSheet = true } label: {
                    Label("Pair iPhone", systemImage: "qrcode")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(MacTheme.accent)
                .controlSize(.regular)
            }
        }
    }

    private var trustedDevicesCard: some View {
        SettingsCard(title: "Trusted devices", icon: "iphone.gen3") {
            HStack {
                Text("\(vm.connectedDevices.count) paired · \(vm.connectedDeviceIds.count) connected")
                    .font(.caption)
                    .foregroundStyle(MacTheme.textTertiary)
                Spacer()
            }
            if vm.connectedDevices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.slash").font(.title)
                        .foregroundStyle(MacTheme.textTertiary)
                    Text("No devices paired yet").foregroundStyle(MacTheme.textSecondary)
                    Text("Click “Pair iPhone” above to start.")
                        .font(.caption).foregroundStyle(MacTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.connectedDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 {
                            Divider().background(MacTheme.border.opacity(0.5))
                        }
                        DeviceRow(
                            device: device,
                            isConnected: vm.connectedDeviceIds.contains(device.id),
                            transport: vm.connectedDeviceTransports[device.id]
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Device row

struct DeviceRow: View {
    let device: DeviceRecord
    let isConnected: Bool
    let transport: MacAppViewModel.PairingTransport?
    @EnvironmentObject var vm: MacAppViewModel
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Platform avatar — 36pt rounded square (was 44pt) so the
            // overall device row is more compact. Still big enough to
            // host the platform glyph clearly without dominating the
            // row vertically.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(stateColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: platformIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textPrimary)
                    statusChip
                }
                // Platform · fingerprint line — matches the System Settings
                // "device name + small mono identifier" pattern.
                HStack(spacing: 6) {
                    Text(platformLabel)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textSecondary)
                    Text("·").font(.caption).foregroundStyle(MacTheme.textTertiary)
                    Text(device.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(MacTheme.textTertiary)
                }
                // Paired-at / last-seen / transport — third row, smaller
                // typography. When the device is connected we show the
                // active transport (LAN / Tailnet); when offline we show
                // the last-seen relative timestamp.
                HStack(spacing: 8) {
                    Label("Paired \(relative(device.pairedAt))",
                          systemImage: "clock")
                        .font(.caption2)
                        .labelStyle(InlineLabelStyle())
                        .foregroundStyle(MacTheme.textTertiary)
                    if isConnected, let transport, transport != .unknown {
                        transportChip(transport)
                    } else if !isConnected, let last = device.lastSeenAt {
                        Label("Last seen \(relative(last))",
                              systemImage: "wifi.slash")
                            .font(.caption2)
                            .labelStyle(InlineLabelStyle())
                            .foregroundStyle(MacTheme.textTertiary)
                    } else if !isConnected {
                        Text("Offline")
                            .font(.caption2)
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) { confirmRemove = true } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(device.revoked)
            .confirmationDialog("Remove \(device.name)?",
                                isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove and disconnect", role: .destructive) {
                    Task { await vm.removeDevice(device.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(device.name) will be disconnected immediately and the iPhone will need to pair again to reconnect.")
            }
        }
        // Slightly tighter than before (was 8pt) to bring the row block
        // height down a notch — matches the user's "shrink the device
        // row block" request.
        .padding(.vertical, 5)
    }

    // MARK: chips

    @ViewBuilder
    private var statusChip: some View {
        if isConnected {
            chip(text: "Connected", tint: MacTheme.success)
        } else if device.revoked {
            chip(text: "Revoked", tint: MacTheme.danger)
        } else {
            chip(text: "Offline", tint: MacTheme.textTertiary)
        }
    }

    private func transportChip(_ t: MacAppViewModel.PairingTransport) -> some View {
        Label(t.label, systemImage: t.iconName)
            .font(.caption2.weight(.semibold))
            .labelStyle(InlineLabelStyle())
            .foregroundStyle(t == .tailscale ? MacTheme.accent : MacTheme.success)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                (t == .tailscale ? MacTheme.accent : MacTheme.success).opacity(0.15),
                in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        (t == .tailscale ? MacTheme.accent : MacTheme.success).opacity(0.4),
                        lineWidth: 0.5)
            )
    }

    private func chip(text: String, tint: Color) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 0.5)
            )
    }

    // MARK: derived

    private var stateColor: Color {
        if device.revoked { return MacTheme.danger }
        return isConnected ? MacTheme.success : MacTheme.textTertiary
    }

    private var platformIcon: String {
        switch device.platform {
        case .iPhone:  return "iphone.gen3"
        case .iPad:    return "ipad"
        case .mac:     return "macbook"
        case .unknown: return "questionmark.circle"
        }
    }

    private var platformLabel: String {
        switch device.platform {
        case .iPhone:  return "iPhone"
        case .iPad:    return "iPad"
        case .mac:     return "Mac"
        case .unknown: return "Device"
        }
    }

    private func relative(_ d: Date) -> String {
        Self.relativeFormatter.localizedString(for: d, relativeTo: Date())
    }

    /// Static — `RelativeDateTimeFormatter` is heavyweight and the paired-devices list
    /// renders one row per device on every connection-status change. The previous
    /// per-call instantiation thrashed the heap during reconnect storms.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Compact label style — icon and text inline at the same baseline, no
/// extra spacing. Used for the meta row's "paired ago" / "last seen" /
/// transport chips so the icons sit flush with the text.
private struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Pairing sheet (QR + 6-digit + endpoint)

struct PairingSheet: View {
    @EnvironmentObject var vm: MacAppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var session: PairingSession?
    @State private var qrImage: NSImage?
    @State private var copiedField: String?
    @State private var initialDeviceCount: Int = 0
    @State private var pairedDevice: DeviceRecord?

    var body: some View {
        ZStack {
            VStack(spacing: 18) {
                HStack {
                    Text("Pair a new device").font(.title2.bold()).foregroundStyle(MacTheme.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                qrSquare
                if let session = session {
                    codeBlock(session: session)
                    expiryLabel(session: session)
                    endpointBlock(session: session)
                } else {
                    ProgressView().frame(height: 30)
                }
                Text("On your iPhone: open DNP Remote → Pair → either Scan QR code or Enter 6-digit code.")
                    .font(.caption).multilineTextAlignment(.center)
                    .foregroundStyle(MacTheme.textTertiary)
                    .frame(maxWidth: 320)

                HStack(spacing: 8) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                    Button("New code") { Task { await issueNew() } }
                        .buttonStyle(.borderedProminent).tint(MacTheme.accent)
                }
            }
            .opacity(activityHidesQR ? 0 : 1)

            activityOverlay
        }
        .padding(28)
        .frame(width: 380)
        .background(MacTheme.surface)
        .animation(.easeInOut(duration: 0.18), value: vm.pairingActivity)
        .task {
            initialDeviceCount = vm.connectedDevices.count
            // Reset any stale activity from a prior closed session before re-issuing.
            vm.pairingActivity = .idle
            await issueNew()
        }
        .onDisappear {
            // Don't leave .succeeded/.failed lingering after the user dismisses the sheet.
            vm.pairingActivity = .idle
        }
        // Watch for a new trusted device to appear → auto-dismiss with success toast.
        .onReceive(vm.$connectedDevices) { devices in
            guard pairedDevice == nil,
                  devices.count > initialDeviceCount,
                  let newest = devices.last else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { pairedDevice = newest }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dismiss() }
        }
    }

    /// Hide the QR + code while a handshake is mid-flight so the live status fills the sheet.
    private var activityHidesQR: Bool {
        switch vm.pairingActivity {
        case .verifying, .succeeded, .failed: return true
        default: return pairedDevice != nil
        }
    }

    @ViewBuilder
    private var activityOverlay: some View {
        switch vm.pairingActivity {
        case .idle:
            EmptyView()
        case .connecting(let remote):
            connectingPanel(remote: remote)
        case .verifying(let deviceName, let via):
            verifyingPanel(deviceName: deviceName, via: via)
        case .succeeded(let deviceName, let fingerprint):
            successPanel(deviceName: deviceName, fingerprint: fingerprint)
        case .failed(let reason):
            failurePanel(reason: reason)
        }
    }

    private func connectingPanel(remote: String) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("iPhone connecting…").font(.callout.weight(.semibold))
                    .foregroundStyle(MacTheme.textPrimary)
            }
            Text(remote)
                .font(.caption.monospaced())
                .foregroundStyle(MacTheme.textTertiary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MacTheme.border, lineWidth: 1))
        .frame(maxWidth: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 60)
        .transition(.opacity)
    }

    private func verifyingPanel(deviceName: String, via channel: MacPairingActivity.Channel) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Verifying \(deviceName)…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(MacTheme.textPrimary)
            Text(channel == .humanCode ? "Checking 6-digit code + signature" : "Checking pairing token + signature")
                .font(.caption)
                .foregroundStyle(MacTheme.textSecondary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MacTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func successPanel(deviceName: String, fingerprint: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(MacTheme.success.opacity(0.15)).frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(MacTheme.success)
            }
            Text("Paired!").font(.title2.bold()).foregroundStyle(MacTheme.textPrimary)
            Text(deviceName)
                .font(.callout)
                .foregroundStyle(MacTheme.textSecondary)
            Text(fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(MacTheme.textTertiary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MacTheme.success.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private func failurePanel(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MacTheme.danger)
                Text("Pairing failed").font(.title3.bold()).foregroundStyle(MacTheme.textPrimary)
                Spacer()
            }
            Text(reason)
                .font(.callout)
                .foregroundStyle(MacTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Dismiss") { vm.pairingActivity = .idle }
                    .buttonStyle(.bordered)
                Button("New code") { Task { vm.pairingActivity = .idle; await issueNew() } }
                    .buttonStyle(.borderedProminent).tint(MacTheme.accent)
            }
        }
        .padding(22)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MacTheme.danger.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: pieces

    private var qrSquare: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.white)
            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .padding(8)
            } else {
                ProgressView().tint(.black)
            }
        }
        .frame(width: 240, height: 240)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MacTheme.border, lineWidth: 1))
    }

    private func codeBlock(session: PairingSession) -> some View {
        VStack(spacing: 6) {
            Text("OR ENTER CODE").font(.caption2.bold()).foregroundStyle(MacTheme.textTertiary)
            Text(formatCode(session.humanCode))
                .font(.system(.title, design: .monospaced).weight(.bold))
                .tracking(6)
                .foregroundStyle(MacTheme.textPrimary)
                .onTapGesture { copy(session.humanCode, label: "code") }
                .help("Click to copy")
            if copiedField == "code" {
                Text("Copied!").font(.caption2).foregroundStyle(MacTheme.success)
            }
        }
    }

    private func expiryLabel(session: PairingSession) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            let remaining = max(0, Int(session.expiresAt.timeIntervalSinceNow))
            Text(remaining > 0 ? "Expires in \(remaining / 60)m \(remaining % 60)s" : "Expired — tap “New code”")
                .font(.caption).foregroundStyle(remaining > 30 ? MacTheme.textTertiary : MacTheme.warning)
        }
    }

    private func endpointBlock(session: PairingSession) -> some View {
        VStack(spacing: 6) {
            endpointRow(label: "LAN", endpoint: session.endpoint, icon: "network",
                        copyKey: "endpoint")
            // When the QR carries a Tailscale endpoint, show it explicitly so the user
            // can verify "yes, my iPhone will fall over to this if hotel WiFi blocks
            // the LAN address." Without surfacing it here the user has no way to know
            // whether tailnet pairing is even an option for the QR they're showing.
            if let te = session.tailscaleEndpoint, !te.isEmpty {
                endpointRow(label: "Tailnet", endpoint: te,
                            icon: "antenna.radiowaves.left.and.right",
                            copyKey: "tailnet",
                            tint: MacTheme.accent)
            }
        }
    }

    private func endpointRow(label: String, endpoint: String, icon: String,
                              copyKey: String, tint: Color = .clear) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption)
                .foregroundStyle(tint == .clear ? MacTheme.textTertiary : tint)
            Text(label).font(.caption2.weight(.semibold))
                .foregroundStyle(MacTheme.textTertiary)
                .frame(width: 48, alignment: .leading)
            Text(endpoint)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MacTheme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                copy(endpoint, label: copyKey)
            } label: {
                Image(systemName: copiedField == copyKey ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Copy \(label.lowercased()) endpoint")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(MacTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: actions

    private func issueNew() async {
        let port = vm.bridge.port ?? 18733
        let endpoint = "ws://\(LocalIP.firstNonLoopback() ?? "127.0.0.1"):\(port)"
        // Probe Tailscale at QR-issue time so the QR carries a tailnet endpoint when one is
        // available. This is what makes pairing work end-to-end at a hotel: the iPhone
        // scans the QR, can't reach the LAN endpoint, and silently falls over to the
        // tailnet endpoint that the QR also carries. No extra steps for the user.
        let ts = TailscaleService.currentStatus()
        let tailscaleEndpoint: String? = {
            guard let ip = ts.ipv4, !ip.isEmpty else { return nil }
            return "ws://\(ip):\(port)"
        }()
        let new = await vm.pairing.issuePairingSession(endpoint: endpoint,
                                                       tailscaleEndpoint: tailscaleEndpoint)
        session = new
        qrImage = QRCodeGenerator.image(for: new.qrPayload, size: 460)
    }

    private func copy(_ s: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        copiedField = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedField == label { copiedField = nil }
        }
    }

    private func formatCode(_ raw: String) -> String {
        guard raw.count == 6 else { return raw }
        let mid = raw.index(raw.startIndex, offsetBy: 3)
        return "\(raw[raw.startIndex..<mid]) \(raw[mid...])"
    }
}

// MARK: - LocalIP helper (kept here so it has scope when this file is the only pairing UI source)

enum LocalIP {
    static func firstNonLoopback() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let family = p.pointee.ifa_addr.pointee.sa_family
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               family == UInt8(AF_INET) {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(p.pointee.ifa_addr,
                               socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                               &hostBuf, socklen_t(hostBuf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let candidate = String(cString: hostBuf)
                    let name = String(cString: p.pointee.ifa_name)
                    if name.hasPrefix("en"), !candidate.hasPrefix("169.254") { return candidate }
                    address = address ?? candidate
                }
            }
            ptr = p.pointee.ifa_next
        }
        return address
    }
}
