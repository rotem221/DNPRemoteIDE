import Foundation
import CryptoKit

/// Decodes inbound frames from iOS clients and dispatches them to the right service. Owned by the Mac
/// view model. Sends signed responses back via the `BridgeServerService`.
@MainActor
final class BridgeDispatcher {

    /// Connection-id → device-id of the device that has authenticated on that connection.
    private var deviceForConnection: [UUID: UUID] = [:]
    /// Inverse map for quick "drop all connections for this device" on revoke.
    private var connectionsForDevice: [UUID: Set<UUID>] = [:]
    /// Connection-id → remote address string the bridge accepted from
    /// (host:port form). Captured at TCP-accept time and consulted again
    /// after the device authenticates so we can publish the per-device
    /// transport (LAN / Tailscale) into the view model.
    private var remoteForConnection: [UUID: String] = [:]

    /// Called from `MacAppViewModel.bootstrap`'s `bridge.onConnectionAccepted`
    /// hook so the dispatcher can later derive each device's transport
    /// from the connection's remote address. Pre-auth: no device id is
    /// known yet, so we just stash the remote keyed by connection id and
    /// look it up in `markDeviceConnected` once the hello / pairing
    /// handshake completes.
    func recordRemote(_ remote: String, for connectionId: UUID) {
        remoteForConnection[connectionId] = remote
    }

    /// `vm` is unowned-style; the dispatcher is owned by the vm.
    weak var vm: MacAppViewModel?

    func handleIncoming(_ data: Data, connectionId: UUID) async {
        // Peek at the type without binding to a payload yet.
        guard let peek = try? DNPCoders.decode(EnvelopePeek.self, from: data) else {
            log("dropped frame: undecodable; \(data.count) bytes; head=\(String(data: data.prefix(120), encoding: .utf8) ?? "?")")
            return
        }
        log("← \(peek.type.rawValue) from \(peek.senderId.uuidString.prefix(8)) (conn \(connectionId.uuidString.prefix(8)))")

        switch peek.type {
        case .pairingRequest:
            await handlePairing(data: data, connectionId: connectionId)

        case .hello:
            await handleHello(data: data, connectionId: connectionId)

        case .userPrompt:
            await handleUserPrompt(data: data, connectionId: connectionId)

        case .approvalResponse:
            await handleApprovalResponse(data: data, connectionId: connectionId)

        case .newSessionRequest:
            await handleNewSessionRequest(data: data, connectionId: connectionId)

        case .closeSessionRequest:
            await handleCloseSessionRequest(data: data, connectionId: connectionId)

        case .attachmentTransfer:
            await handleAttachmentTransfer(data: data, connectionId: connectionId)

        case .cancelRunning:
            await handleCancelRunning(data: data, connectionId: connectionId)

        case .forceApprove:
            await handleForceApprove(data: data, connectionId: connectionId)

        case .openFolderRequest:
            await handleOpenFolderRequest(data: data, connectionId: connectionId)

        case .setProjectRootRequest:
            await handleSetProjectRootRequest(data: data, connectionId: connectionId)

        case .directoryListingRequest:
            await handleDirectoryListingRequest(data: data, connectionId: connectionId)

        case .fileContentRequest:
            await handleFileContentRequest(data: data, connectionId: connectionId)

        case .fileWriteRequest:
            await handleFileWriteRequest(data: data, connectionId: connectionId)

        case .fileSearchRequest:
            await handleFileSearchRequest(data: data, connectionId: connectionId)

        case .githubRepoListRequest:
            await handleGitHubRepoListRequest(data: data, connectionId: connectionId)

        case .githubAdoptRepoRequest:
            await handleGitHubAdoptRepoRequest(data: data, connectionId: connectionId)

        case .recentProjectListRequest:
            await handleRecentProjectListRequest(data: data, connectionId: connectionId)

        case .screenMirrorStart:
            await handleScreenMirrorStart(data: data, connectionId: connectionId)
        case .screenMirrorStop:
            await handleScreenMirrorStop(data: data, connectionId: connectionId)
        case .remoteInput:
            await handleRemoteInput(data: data, connectionId: connectionId)

        case .heartbeat:
            // Ack-only: send our own heartbeat back.
            await sendHeartbeat(to: connectionId)

        case .sessionListRequest:
            // iOS asks "give me the current session list now" — used on reconnect /
            // when the client suspects it missed a broadcast. Cheap one-shot reply on
            // the requesting connection only; broadcasts to others continue to fire
            // whenever sessions actually change on Mac.
            await sendSessionList(to: connectionId)

        case .subscribeSession, .unsubscribeSession:
            log("not yet implemented: \(peek.type)")

        default:
            log("unhandled message type: \(peek.type)")
        }
    }

    /// Called when a connection drops — clear our device→connection mapping
    /// AND drop the remote-address record for this connection. The latter
    /// is also cleared when the device reconnects on a new connection (it'll
    /// re-record from `markDeviceConnected`).
    func handleConnectionDropped(_ connectionId: UUID) async {
        remoteForConnection.removeValue(forKey: connectionId)
        guard let deviceId = deviceForConnection.removeValue(forKey: connectionId) else { return }
        connectionsForDevice[deviceId]?.remove(connectionId)
        if connectionsForDevice[deviceId]?.isEmpty == true {
            connectionsForDevice.removeValue(forKey: deviceId)
            await markDeviceDisconnected(deviceId: deviceId)
        }
    }

    /// Drop every active connection associated with the given device id (used on revoke).
    func dropAllConnections(forDevice deviceId: UUID) {
        let conns = connectionsForDevice[deviceId] ?? []
        for connId in conns { vm?.bridge.dropConnection(connId) }
    }

    /// Push a `revoke` to a single connection whose device id is unknown — used in
    /// `handleHello` to escape the iPhone-keeps-reconnecting-after-Mac-removed-it loop.
    /// We sign with the Mac's identity key as usual; iOS doesn't verify revokes against
    /// any specific Mac key (it just clears local state on receipt) so even a fresh Mac
    /// install with a brand-new identity could send this signal cleanly.
    private func sendRevokeUnsigned(reason: String, to connectionId: UUID) async {
        guard let vm = vm,
              let pk = await vm.pairing.macIdentity else { return }
        let macId = await vm.pairing.macDeviceId
        var env = BridgeEnvelope<RevokePayload>(
            type: .revoke, senderId: macId,
            nonce: NonceFactory.make(),
            payload: RevokePayload(revokedDeviceId: UUID(), reason: reason))
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm.bridge.send(env, to: connectionId)
    }

    /// Send a signed `revoke` envelope to every active connection of the given device. iOS
    /// uses this as the cue to clear its stored pairing + halt auto-reconnect, so removing
    /// a device on Mac is reflected immediately on the iPhone (the iPhone otherwise just
    /// sees a TCP drop and would loop trying to reconnect).
    func sendRevoke(toDevice deviceId: UUID, reason: String?) async {
        guard let vm = vm,
              let pk = await vm.pairing.macIdentity else { return }
        let macId = await vm.pairing.macDeviceId
        let conns = connectionsForDevice[deviceId] ?? []
        for connId in conns {
            var env = BridgeEnvelope<RevokePayload>(
                type: .revoke, senderId: macId,
                nonce: NonceFactory.make(),
                payload: RevokePayload(revokedDeviceId: deviceId, reason: reason))
            try? BridgeSigner.sign(envelope: &env, privateKey: pk)
            vm.bridge.send(env, to: connId)
        }
    }

    /// Send the latest session list to every connected iOS client. Call after any change to
    /// `vm.sessions` (new session, close, rename, status change).
    func broadcastSessionList() async {
        let allConns = Set(connectionsForDevice.values.flatMap { $0 })
        for c in allConns { await sendSessionList(to: c) }
    }

    /// Push the latest Claude Code AI Usage snapshot to every connected iOS
    /// client. Called by `MacAppViewModel.refreshAIUsage()` after each
    /// 5-minute Anthropic round-trip, and again when a new client connects
    /// (`sendAIUsageIfAvailable(to:)` below).
    func broadcastAIUsage(snapshot: AIUsageSnapshot) async {
        guard let vm = vm,
              let pk = await vm.pairing.macIdentity else { return }
        let macId = await vm.pairing.macDeviceId
        var env = BridgeEnvelope<AIUsageBroadcastPayload>(
            type: .aiUsageBroadcast, senderId: macId,
            nonce: NonceFactory.make(),
            payload: AIUsageBroadcastPayload(snapshot: snapshot)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        let allConns = Set(connectionsForDevice.values.flatMap { $0 })
        for c in allConns { vm.bridge.send(env, to: c) }
    }

    /// Send the cached AI Usage snapshot to a single freshly-connected
    /// client. The full broadcast happens every 5 min, but a new device
    /// shouldn't have to wait up to 5 min for the first reading.
    func sendAIUsageIfAvailable(to connectionId: UUID) async {
        guard let vm = vm, let snap = vm.aiUsage,
              let pk = await vm.pairing.macIdentity else { return }
        let macId = await vm.pairing.macDeviceId
        var env = BridgeEnvelope<AIUsageBroadcastPayload>(
            type: .aiUsageBroadcast, senderId: macId,
            nonce: NonceFactory.make(),
            payload: AIUsageBroadcastPayload(snapshot: snap)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm.bridge.send(env, to: connectionId)
    }

    /// Tell every paired iOS client which session the IDE just focused
    /// so the iOS session capsule auto-follows. Called from
    /// `MacAppViewModel.notifyActiveSessionChanged(_:)` whenever a
    /// `WorkspaceController.selectedSessionId` flips.
    func broadcastActiveSession(sessionId: UUID?) async {
        guard let vm = vm,
              let pk = await vm.pairing.macIdentity else { return }
        let macId = await vm.pairing.macDeviceId
        var env = BridgeEnvelope<ActiveSessionBroadcastPayload>(
            type: .activeSessionBroadcast, senderId: macId,
            nonce: NonceFactory.make(),
            payload: ActiveSessionBroadcastPayload(sessionId: sessionId)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        let allConns = Set(connectionsForDevice.values.flatMap { $0 })
        for c in allConns { vm.bridge.send(env, to: c) }
    }

    /// Replay the most recently-broadcast active-session id to a single
    /// freshly-connected iOS client. Without this the iPhone wouldn't
    /// know which session the IDE is on until the user clicked a new
    /// pane on the Mac.
    func sendActiveSessionIfAvailable(to connectionId: UUID) async {
        guard let vm = vm,
              let pk = await vm.pairing.macIdentity else { return }
        let sid = await MainActor.run { vm.lastBroadcastActiveSessionId }
        let macId = await vm.pairing.macDeviceId
        var env = BridgeEnvelope<ActiveSessionBroadcastPayload>(
            type: .activeSessionBroadcast, senderId: macId,
            nonce: NonceFactory.make(),
            payload: ActiveSessionBroadcastPayload(sessionId: sid)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm.bridge.send(env, to: connectionId)
    }

    // MARK: - Pairing

    private func handlePairing(data: Data, connectionId: UUID) async {
        guard let env = try? DNPCoders.decode(BridgeEnvelope<PairingRequest>.self, from: data) else {
            print("[DNP][Pairing] decode failed (\(data.count) bytes) on conn \(connectionId.uuidString.prefix(8))")
            return
        }
        let req = env.payload
        guard let pairing = vm?.pairing else { return }

        // Detect: 6-digit code vs long token (base64 ≥ 20 chars).
        let credential = req.pairingToken
        let isHumanCode = credential.count == 6 && credential.allSatisfy(\.isNumber)
        print("[DNP][Pairing] received \(isHumanCode ? "humanCode" : "token") from \(req.deviceName) (\(req.deviceId.uuidString.prefix(8)))")
        // Surface live state to PairingSheet — same beat the iPhone shows on its side.
        vm?.pairingActivity = .verifying(deviceName: req.deviceName,
                                          via: isHumanCode ? .humanCode : .token)
        let response: PairingResponse = isHumanCode
            ? await pairing.acceptPairing(humanCode: credential, fromDevice: req)
            : await pairing.acceptPairing(token: credential, fromDevice: req)

        print("[DNP][Pairing] decision for \(req.deviceName): \(response.accepted ? "ACCEPTED" : "DENIED — \(response.denialReason ?? "unknown")")")
        // Send response back over this connection.
        await sendPairingResponse(response, to: connectionId)

        if response.accepted {
            // Track this connection as authenticated.
            deviceForConnection[connectionId] = req.deviceId
            connectionsForDevice[req.deviceId, default: []].insert(connectionId)
            await markDeviceConnected(deviceId: req.deviceId, connectionId: connectionId)
            let fp = SHA256Helper.hex(of: req.publicKey).prefix(16)
            let fpDisplay = stride(from: 0, to: min(16, fp.count), by: 2)
                .map { i -> String in
                    let s = fp.index(fp.startIndex, offsetBy: i)
                    let e = fp.index(s, offsetBy: 2)
                    return String(fp[s..<e]).uppercased()
                }
                .joined(separator: ":")
            vm?.pairingActivity = .succeeded(deviceName: req.deviceName,
                                              fingerprint: fpDisplay)
            // After pairing, push the current session list + project info so the iOS sidebar
            // shows what folder we're connected to right away. Then backfill the feed for every
            // active session so the chat view matches the IDE state (no ghost-from-previous-run
            // content, no missing history).
            await sendSessionList(to: connectionId)
            await broadcastProjectInfo()
            await backfillFeed(to: connectionId)
            await sendAIUsageIfAvailable(to: connectionId)
            await sendActiveSessionIfAvailable(to: connectionId)
        } else {
            // Drop the connection so a misuser can't keep guessing.
            print("[DNP][Pairing] dropping connection after denial: \(response.denialReason ?? "?")")
            vm?.pairingActivity = .failed(reason: response.denialReason ?? "Pairing denied")
            vm?.bridge.dropConnection(connectionId)
        }
    }

    private func sendSessionList(to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity,
              let sessions = vm?.sessions else { return }
        // Filter out sessions that aren't actually live in the IDE: ended/crashed/disconnected
        // are persisted records (so the user can resume them on the Mac), but they're NOT
        // currently running and shouldn't show up as active in the iOS chat selector.
        let live = sessions.filter { s in
            s.status != .ended && s.status != .crashed && s.status != .disconnected
        }
        var env = BridgeEnvelope<SessionListResponsePayload>(
            type: .sessionListResponse,
            senderId: macId,
            nonce: NonceFactory.make(),
            payload: SessionListResponsePayload(sessions: live)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
        log("sent session list (\(live.count) live of \(sessions.count) total)")
    }

    /// Broadcast a new event to all paired iOS clients AND record it on the Mac for the context monitor.
    func emitLiveEvent(_ event: SessionEvent) async {
        await vm?.recordEventForContextMonitor(event)
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<LiveEventPayload>(
            type: .liveEvent,
            senderId: macId,
            sessionId: event.sessionId,
            nonce: NonceFactory.make(),
            payload: LiveEventPayload(event: event)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.broadcast(env)
    }

    private func sendPairingResponse(_ response: PairingResponse, to connectionId: UUID) async {
        guard let pk = await vm?.pairing.macIdentity, let macId = await vm?.pairing.macDeviceId else { return }
        var env = BridgeEnvelope<PairingResponse>(
            type: .pairingResponse,
            senderId: macId,
            nonce: NonceFactory.make(),
            payload: response
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    // MARK: - Hello (re-connect after pairing)

    private func handleHello(data: Data, connectionId: UUID) async {
        guard let env = try? DNPCoders.decode(BridgeEnvelope<HelloPayload>.self, from: data) else {
            print("[DNP][Hello] decode failed (\(data.count) bytes)"); return
        }
        let deviceId = env.payload.deviceId
        print("[DNP][Hello] from \(env.payload.deviceName) (\(deviceId.uuidString.prefix(8))) on conn \(connectionId.uuidString.prefix(8))")
        // Verify the sender is a trusted, non-revoked device.
        guard let trusted = await vm?.pairing.publicKey(forDevice: deviceId) else {
            print("[DNP][Hello] unknown device \(deviceId.uuidString.prefix(8)) — sending revoke")
            await sendRevokeUnsigned(reason: "This iPhone has been removed from the Mac.",
                                      to: connectionId)
            vm?.bridge.dropConnection(connectionId)
            return
        }
        // Verify signature.
        guard (try? BridgeSigner.verify(envelope: env, publicKey: trusted)) == true else {
            print("[DNP][Hello] signature invalid for \(deviceId.uuidString.prefix(8)) — dropping")
            vm?.bridge.dropConnection(connectionId); return
        }
        print("[DNP][Hello] verified — re-attaching device \(deviceId.uuidString.prefix(8))")

        deviceForConnection[connectionId] = deviceId
        connectionsForDevice[deviceId, default: []].insert(connectionId)
        await vm?.pairing.touchLastSeen(deviceId: deviceId)
        await markDeviceConnected(deviceId: deviceId, connectionId: connectionId)

        // Send helloAck + session list + project info + backfilled feed so iOS can
        // populate its UI immediately. The backfill matters specifically on RECONNECT
        // (the wifi blip case): before this, hello-after-reconnect resent the session
        // list but skipped backfill — so the sidebar showed the right sessions but
        // each chat looked empty until new events arrived. That's the "feels
        // disconnected" symptom the user reported.
        await sendHelloAck(to: connectionId)
        await sendSessionList(to: connectionId)
        await broadcastProjectInfo()
        await backfillFeed(to: connectionId)
        await sendAIUsageIfAvailable(to: connectionId)
        await sendActiveSessionIfAvailable(to: connectionId)
    }

    private func sendHelloAck(to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId, let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<HelloPayload>(
            type: .helloAck,
            senderId: macId,
            nonce: NonceFactory.make(),
            payload: HelloPayload(
                deviceId: macId,
                deviceName: Host.current().localizedName ?? "Mac",
                platform: .mac,
                appVersion: "0.1"
            )
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    // MARK: - User prompt / approval response (signed-only)

    private func handleUserPrompt(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId] else {
            print("[DNP][UserPrompt] REJECTED — no device tracked for connection \(connectionId.uuidString.prefix(8)). Did the iPhone skip the hello/pair handshake?")
            return
        }
        guard let trustedKey = await vm?.pairing.publicKey(forDevice: deviceId) else {
            print("[DNP][UserPrompt] REJECTED — device \(deviceId.uuidString.prefix(8)) not in trusted set (revoked?)")
            return
        }
        guard let env = try? DNPCoders.decode(BridgeEnvelope<UserPromptPayload>.self, from: data) else {
            print("[DNP][UserPrompt] REJECTED — envelope decode failed (\(data.count) bytes)")
            return
        }
        guard (try? BridgeSigner.verify(envelope: env, publicKey: trustedKey)) == true else {
            print("[DNP][UserPrompt] REJECTED — signature invalid for device \(deviceId.uuidString.prefix(8))")
            return
        }
        print("[DNP][UserPrompt] accepted sid=\(env.payload.sessionId.uuidString.prefix(8)) bytes=\(env.payload.text.utf8.count) text=\(env.payload.text.prefix(40))")
        await vm?.handleIncomingUserPrompt(text: env.payload.text,
                                           fromSessionId: env.payload.sessionId,
                                           deviceId: deviceId)
    }

    private func handleAttachmentTransfer(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<AttachmentTransferPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("attachmentTransfer rejected"); return }
        let payload = env.payload
        log("attachmentTransfer name=\(payload.filename) bytes=\(payload.data.count)")
        await vm?.persistAttachment(filename: payload.filename, data: payload.data)
    }

    /// iOS → Mac: bring up an NSOpenPanel and adopt the chosen folder as the active project.
    /// Pushes back a fresh `ProjectInfoPayload` to every client so the sidebar updates everywhere.
    private func handleOpenFolderRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<OpenFolderRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("openFolderRequest rejected"); return }
        await vm?.presentOpenFolderPanelAndAdopt()
        await broadcastProjectInfo()
    }

    private func handleSetProjectRootRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<SetProjectRootRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("setProjectRootRequest rejected"); return }
        await vm?.adoptProjectRoot(absolutePath: env.payload.path)
        await broadcastProjectInfo()
    }

    private func handleDirectoryListingRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<DirectoryListingRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("directoryListingRequest rejected"); return }
        let response = await vm?.listDirectory(payload: env.payload) ?? DirectoryListingResponsePayload(
            requestId: env.payload.requestId, relativePath: env.payload.relativePath,
            entries: [], error: "vm unavailable")
        await sendDirectoryListing(response, to: connectionId)
    }

    private func handleFileContentRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<FileContentRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("fileContentRequest rejected"); return }
        let response = await vm?.readFile(payload: env.payload) ?? FileContentResponsePayload(
            requestId: env.payload.requestId, relativePath: env.payload.relativePath,
            mimeType: "application/octet-stream", error: "vm unavailable")
        await sendFileContent(response, to: connectionId)
    }

    private func handleFileWriteRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<FileWriteRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("fileWriteRequest rejected"); return }
        let response = await vm?.writeFile(payload: env.payload) ?? FileWriteResponsePayload(
            requestId: env.payload.requestId, path: env.payload.path,
            success: false, error: "vm unavailable")
        await sendFileWriteResponse(response, to: connectionId)
    }

    private func handleFileSearchRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<FileSearchRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("fileSearchRequest rejected"); return }
        let response = await vm?.searchFiles(payload: env.payload) ?? FileSearchResponsePayload(
            requestId: env.payload.requestId, query: env.payload.query, hits: [],
            error: "vm unavailable")
        await sendFileSearchResponse(response, to: connectionId)
    }

    private func sendFileWriteResponse(_ payload: FileWriteResponsePayload, to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<FileWriteResponsePayload>(
            type: .fileWriteResponse, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    private func sendFileSearchResponse(_ payload: FileSearchResponsePayload, to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<FileSearchResponsePayload>(
            type: .fileSearchResponse, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    // MARK: - GitHub

    private func handleGitHubRepoListRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<GitHubRepoListRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("githubRepoListRequest rejected"); return }

        let req = env.payload
        // Off-main shell-out so the dispatcher loop doesn't block on `gh` (which can hit the
        // network for ~hundreds of ms). The result hops back on @MainActor for sending.
        let repos: [GitHubRepoSummary]
        let err: String?
        let limit = max(1, min(req.limit, 200))
        let result = await Task.detached {
            GitHubService.runCommand([
                "repo", "list", "--limit", "\(limit)",
                "--json", "nameWithOwner,description,isPrivate,url"
            ])
        }.value
        if let result, result.exit == 0,
           let data = result.stdout.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([GitHubRepoSummaryWire].self, from: data) {
            repos = parsed.map {
                GitHubRepoSummary(nameWithOwner: $0.nameWithOwner,
                                  description: $0.description ?? "",
                                  isPrivate: $0.isPrivate ?? false,
                                  url: $0.url ?? "")
            }
            err = nil
        } else {
            repos = []
            err = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "gh repo list failed"
        }
        let response = GitHubRepoListResponsePayload(requestId: req.requestId, repos: repos, error: err)
        await sendGitHubRepoListResponse(response, to: connectionId)
    }

    private func handleGitHubAdoptRepoRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<GitHubAdoptRepoRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("githubAdoptRepoRequest rejected"); return }
        // Mac's `adoptGitHubProject` either reuses an existing clone under
        // `~/Developer/<repo>` or runs `gh repo clone` first, then opens the project.
        // Successful adoption fires `broadcastProjectInfo` so iOS sees the new project.
        _ = await vm?.adoptGitHubProject(nameWithOwner: env.payload.nameWithOwner)
    }

    private func sendGitHubRepoListResponse(_ payload: GitHubRepoListResponsePayload, to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<GitHubRepoListResponsePayload>(
            type: .githubRepoListResponse, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    /// iOS asked for the project picker's recents list. We return the same `RecentProjectsService`
    /// the Mac welcome scene uses — same data, same ordering — so the iOS picker mirrors
    /// what the user would see if they walked over to the Mac. Each entry's `kind`
    /// (`local` / `clone` / `ssh`) drives the iOS row's icon.
    private func handleRecentProjectListRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<RecentProjectListRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("recentProjectListRequest rejected"); return }

        let entries = await MainActor.run { () -> [RecentProjectSummary] in
            RecentProjectsService.shared.entries.map { e in
                let kind: RecentProjectSummaryKind = {
                    switch e.kind {
                    case .local: return .local
                    case .clone: return .clone
                    case .ssh:   return .ssh
                    }
                }()
                return RecentProjectSummary(id: e.id, displayName: e.displayName,
                                             path: e.path, kind: kind,
                                             lastOpenedAt: e.lastOpenedAt)
            }
        }
        await sendRecentProjectListResponse(
            RecentProjectListResponsePayload(requestId: env.payload.requestId, entries: entries),
            to: connectionId
        )
    }

    private func sendRecentProjectListResponse(_ payload: RecentProjectListResponsePayload,
                                                to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<RecentProjectListResponsePayload>(
            type: .recentProjectListResponse, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    // MARK: - Screen mirror

    private var lastScreenSize: CGSize = .zero

    private func handleScreenMirrorStart(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<ScreenMirrorStartPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("screenMirrorStart rejected"); return }
        let payload = env.payload

        // Snapshot the Mac's signing identity ONCE so the per-frame send path
        // doesn't need to await the actor. Without this the previous form did
        // `await vm?.pairing.macIdentity` per frame, which serialised every frame
        // through the actor's mailbox AND through MainActor — that's what made
        // the iOS preview look frozen and the IDE feel laggy under mirror load.
        guard let macId = await vm?.pairing.macDeviceId,
              let signingKey = await vm?.pairing.macIdentity,
              let bridge = vm?.bridge else {
            log("screenMirrorStart cannot resolve mac identity")
            return
        }

        await MainActor.run { [weak self] in
            MacScreenMirrorService.shared.onFrame = { [weak self] frame in
                self?.lastScreenSize = CGSize(width: frame.displayPointWidth,
                                               height: frame.displayPointHeight)
            }
            // Background-safe sink: encode + sign + send entirely off MainActor.
            // Captures `bridge`, `macId`, `signingKey`, `connectionId` — all `Sendable`.
            // The dispatcher's own `lastScreenSize` is updated here too, on a
            // private serial queue mediated by NSLock, but in practice this is an
            // atomic write of a CGSize — no readers race with a partial value.
            MacScreenMirrorService.shared.settings.frameSink = { frame in
                var env = BridgeEnvelope<ScreenMirrorFramePayload>(
                    type: .screenMirrorFrame,
                    senderId: macId,
                    nonce: NonceFactory.make(),
                    payload: frame
                )
                try? BridgeSigner.sign(envelope: &env, privateKey: signingKey)
                bridge.send(env, to: connectionId)
            }
            // Independent 30Hz cursor sink — decouples pointer smoothness
            // from frame cadence so iOS sees a fluid cursor even at 5fps
            // bitmap streaming. Same Sendable-safe capture pattern as
            // `frameSink`; runs entirely off MainActor.
            MacScreenMirrorService.shared.settings.cursorSink = { cur in
                var env = BridgeEnvelope<ScreenMirrorCursorPayload>(
                    type: .screenMirrorCursor,
                    senderId: macId,
                    nonce: NonceFactory.make(),
                    payload: cur
                )
                try? BridgeSigner.sign(envelope: &env, privateKey: signingKey)
                bridge.send(env, to: connectionId)
            }
            MacScreenMirrorService.shared.start(targetFPS: payload.targetFPS,
                                                 maxLongEdge: payload.maxLongEdge)
        }
    }

    private func handleScreenMirrorStop(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<ScreenMirrorStopPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("screenMirrorStop rejected"); return }
        _ = env
        await MainActor.run {
            MacScreenMirrorService.shared.stop()
            MacScreenMirrorService.shared.onFrame = nil
            MacScreenMirrorService.shared.settings.frameSink = nil
            MacScreenMirrorService.shared.settings.cursorSink = nil
        }
    }

    private func broadcastScreenMirrorFrame(_ frame: ScreenMirrorFramePayload,
                                             to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<ScreenMirrorFramePayload>(
            type: .screenMirrorFrame, senderId: macId,
            nonce: NonceFactory.make(), payload: frame)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    private func handleRemoteInput(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<RemoteInputPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("remoteInput rejected"); return }
        let displaySize = self.lastScreenSize == .zero
            ? CGSize(width: 1920, height: 1080) : self.lastScreenSize
        await MainActor.run { [payload = env.payload] in
            MacRemoteInputService.shared.apply(payload, displayPointSize: displaySize)
        }
    }

    private func sendDirectoryListing(_ payload: DirectoryListingResponsePayload, to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<DirectoryListingResponsePayload>(
            type: .directoryListingResponse, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    private func sendFileContent(_ payload: FileContentResponsePayload, to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId,
              let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<FileContentResponsePayload>(
            type: .fileContentResponse, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    /// Send each session's recent events to a freshly-connected client so the iOS feed
    /// mirrors the IDE state. For sessions whose in-memory `feed[]` is empty (typical when
    /// Claude was started in the IDE long before the Mac app booted, OR before iOS joined),
    /// reconstruct events directly from Claude's transcript JSONL — this is the only way to
    /// surface the FULL conversation when iOS attaches mid-flight.
    private func backfillFeed(to connectionId: UUID) async {
        guard let vm = vm else { return }
        let macId = await vm.pairing.macDeviceId
        guard let pk = await vm.pairing.macIdentity else { return }
        for session in vm.sessions {
            var events = vm.feed[session.id] ?? []
            // If we don't have anything cached for this session, try reading the transcript.
            if events.isEmpty {
                events = await vm.reconstructEventsFromTranscript(for: session)
            }
            guard !events.isEmpty else { continue }
            let tail = Array(events.suffix(ProtocolConstants.eventBackfillBatchSize))
            var env = BridgeEnvelope<EventBatchPayload>(
                type: .eventBatch, senderId: macId, sessionId: session.id,
                nonce: NonceFactory.make(),
                payload: EventBatchPayload(sessionId: session.id, events: tail,
                                           isBackfill: true,
                                           highestSequence: tail.last?.sequence))
            try? BridgeSigner.sign(envelope: &env, privateKey: pk)
            vm.bridge.send(env, to: connectionId)
        }
    }

    /// Push the current project info to every connected client. Called after pairing/hello and
    /// whenever the Mac side's `projectRoot` changes.
    func broadcastProjectInfo() async {
        guard let vm = vm else { return }
        // Probe the Tailscale daemon on every broadcast — cheap (<100 ms), gives the iOS
        // client a fresh tailnet IP if the user just signed in / out. Failure is silent so a
        // box without Tailscale still publishes a usable LAN-only payload.
        let ts = TailscaleService.currentStatus()
        // GitHub backing of the active project + global auth status. iOS uses both: the
        // settings card shows auth state, the file-explorer header shows the current repo
        // and branch chip.
        let gh: SessionGitHubInfo? = {
            guard let info = vm.projectGitHub else { return nil }
            return SessionGitHubInfo(nameWithOwner: info.nameWithOwner,
                                     webURL: info.webURL?.absoluteString,
                                     currentBranch: info.currentBranch)
        }()
        let auth = GitHubService.currentStatus()
        let payload = ProjectInfoPayload(
            rootPath: vm.projectRoot?.url.path,
            displayName: vm.projectRoot?.url.lastPathComponent,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            tailscaleHostname: ts.hostname,
            tailscaleIPv4: ts.ipv4,
            gitHub: gh,
            gitHubAuth: GitHubAuthInfoPayload(
                installed: auth.isInstalled,
                signedIn: auth.signedIn,
                user: auth.user,
                host: auth.host,
                scopes: auth.scopes
            )
        )
        let macId = await vm.pairing.macDeviceId
        guard let pk = await vm.pairing.macIdentity else { return }
        var env = BridgeEnvelope<ProjectInfoPayload>(
            type: .projectInfo, senderId: macId,
            nonce: NonceFactory.make(), payload: payload)
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm.bridge.broadcast(env)
    }

    private func handleCancelRunning(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<CancelRunningPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("cancelRunning rejected"); return }
        await vm?.cancelRunningTurn(sessionId: env.payload.sessionId)
    }

    private func handleForceApprove(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<ForceApprovePayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("forceApprove rejected"); return }
        log("forceApprove sid=\(env.payload.sessionId)")
        await vm?.forceApprove(sessionId: env.payload.sessionId)
    }

    private func handleCloseSessionRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<CloseSessionRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("closeSessionRequest rejected"); return }
        log("closeSessionRequest sid=\(env.payload.sessionId)")
        await vm?.confirmClose(sessionId: env.payload.sessionId)
        await broadcastSessionList()
    }

    private func handleNewSessionRequest(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let key = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<NewSessionRequestPayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: key)) == true
        else { log("newSessionRequest rejected"); return }
        log("newSessionRequest accepted")
        await vm?.newSession()
        // Push the updated list to every connected client.
        for connId in connectionsForDevice.values.flatMap({ $0 }) {
            await sendSessionList(to: connId)
        }
    }

    private func handleApprovalResponse(data: Data, connectionId: UUID) async {
        guard let deviceId = deviceForConnection[connectionId],
              let trustedKey = await vm?.pairing.publicKey(forDevice: deviceId),
              let env = try? DNPCoders.decode(BridgeEnvelope<ApprovalResponsePayload>.self, from: data),
              (try? BridgeSigner.verify(envelope: env, publicKey: trustedKey)) == true
        else { log("approvalResponse rejected"); return }
        log("approvalResponse \(env.payload.response.approvalId)")
        // Single funnel: `handleApprovalDecision` now applies via the actor itself and
        // gates the PTY write on `.accepted`. The previous form pre-applied here AND
        // unconditionally called `handleApprovalDecision`, which double-typed `1\r` on
        // iOS retries (apply returned `.alreadyDecided` the second time but we still
        // typed). Letting the VM own the apply makes the operation idempotent end-to-end.
        await vm?.handleApprovalDecision(
            approvalId: env.payload.response.approvalId,
            decision: env.payload.response.decision
        )
    }

    private func sendHeartbeat(to connectionId: UUID) async {
        guard let macId = await vm?.pairing.macDeviceId, let pk = await vm?.pairing.macIdentity else { return }
        var env = BridgeEnvelope<HeartbeatPayload>(
            type: .heartbeat,
            senderId: macId,
            nonce: NonceFactory.make(),
            payload: HeartbeatPayload(connectionUptimeSeconds: 0)
        )
        try? BridgeSigner.sign(envelope: &env, privateKey: pk)
        vm?.bridge.send(env, to: connectionId)
    }

    // MARK: - Connection-state plumbing

    private func markDeviceConnected(deviceId: UUID, connectionId: UUID? = nil) async {
        guard let vm = vm else { return }
        vm.connectedDevices = await vm.pairing.trustedDevices
        let wasConnected = vm.connectedDeviceIds.contains(deviceId)
        vm.connectedDeviceIds.insert(deviceId)
        // Stamp the per-device transport (LAN / Tailscale) for the
        // pairing pane. We look up the remote address recorded against
        // this connection at TCP-accept time; if the caller didn't pass
        // a connection id we fall back to whichever active connection
        // belongs to this device (most recent one).
        let connId = connectionId
            ?? connectionsForDevice[deviceId]?.first
        if let cid = connId, let remote = remoteForConnection[cid] {
            vm.recordTransport(for: deviceId, remote: remote)
        }
        // Only fire on the rising edge — a hello-after-reconnect that just reasserts an
        // already-tracked device shouldn't surface as a fresh banner.
        if !wasConnected, let device = vm.connectedDevices.first(where: { $0.id == deviceId }) {
            MacNotificationService.shared.fireDeviceConnected(deviceName: device.name)
        }
    }

    private func markDeviceDisconnected(deviceId: UUID) async {
        guard let vm = vm else { return }
        let wasConnected = vm.connectedDeviceIds.contains(deviceId)
        vm.connectedDeviceIds.remove(deviceId)
        // Drop the cached transport so the row no longer claims a stale
        // "via Tailnet" / "via LAN" badge after the iPhone goes offline.
        vm.connectedDeviceTransports.removeValue(forKey: deviceId)
        if wasConnected {
            let name = vm.connectedDevices.first(where: { $0.id == deviceId })?.name
                ?? "iPhone"
            MacNotificationService.shared.fireDeviceDisconnected(deviceName: name)
        }
    }

    private func log(_ s: String) {
        #if DEBUG
        print("[BridgeDispatcher] \(s)")
        #endif
    }
}

/// Lightweight envelope-type peek: decodes only the discriminator without binding to a Payload type.
struct EnvelopePeek: Codable {
    let id: UUID
    let type: BridgeMessageType
    let senderId: UUID
    let timestamp: Date
}

/// Lenient decoder shape for `gh repo list --json ...` rows — `description` can be missing
/// or null for repos with no description, and `isPrivate`/`url` are also defensive.
private struct GitHubRepoSummaryWire: Codable {
    let nameWithOwner: String
    let description: String?
    let isPrivate: Bool?
    let url: String?
}
