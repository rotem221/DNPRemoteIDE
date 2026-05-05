import Foundation
import Network

/// Local WebSocket-style bridge over Network.framework. For MVP this uses raw NWListener with framed JSON
/// (length-prefixed) — easier to ship and audit than a full websocket implementation. iOS client mirrors this framing.
/// Each frame is `<4-byte big-endian length><JSON bytes of BridgeEnvelope>`.
final class BridgeServerService: ObservableObject, @unchecked Sendable {

    @Published private(set) var port: Int? = nil
    @Published private(set) var connections: Set<UUID> = []

    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "dnp.bridge.server")

    func start(preferredPort: UInt16 = 18733) async {
        // Idempotent: if a listener is already up, don't try to bind again — that would
        // collide on the same port and silently fail. Bootstrap can fire more than once
        // if state restoration or window-reopen paths re-trigger it; this guard makes
        // the call safe.
        if listener != nil {
            print("[DNP][Bridge] Mac listener already running on port \(port ?? 0) — skipping re-start")
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Accept LAN connections (the iPhone needs to reach us). The signed envelopes provide auth.
            let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: preferredPort))
            self.listener = listener
            listener.stateUpdateHandler = { state in
                print("[DNP][Bridge] Mac listener state → \(state)")
                Task { @MainActor in
                    if case .ready = state {
                        self.port = Int(preferredPort)
                    }
                    if case .failed(let err) = state {
                        print("[DNP][Bridge] Mac listener FAILED: \(err) — stopping")
                        self.stop()
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                let id = UUID()
                self.clients[id] = conn
                Task { @MainActor in self.connections.insert(id) }
                print("[Bridge] new connection \(id) from \(conn.endpoint)")
                let remote = String(describing: conn.endpoint)
                self.onConnectionAccepted?(id, remote)
                conn.stateUpdateHandler = { state in
                    print("[Bridge] connection \(id) state → \(state)")
                    if case .failed = state { self.dropClient(id) }
                    if case .cancelled = state { self.dropClient(id) }
                }
                conn.start(queue: self.queue)
                self.receiveLoop(connectionId: id)
            }
            listener.start(queue: queue)
            print("[DNP][Bridge] Mac listener.start() called for port \(preferredPort)")
        } catch {
            print("[DNP][Bridge] Mac listener bind FAILED on port \(preferredPort): \(error)")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        for c in clients.values { c.cancel() }
        clients.removeAll()
        Task { @MainActor in self.connections.removeAll() }
    }

    /// Broadcast a signed envelope to all connected clients. Caller is responsible for signing.
    func broadcast<P: Codable & Hashable & Sendable>(_ envelope: BridgeEnvelope<P>) {
        guard let data = try? DNPCoders.encode(envelope) else { return }
        let frame = Self.frame(data)
        for c in clients.values { c.send(content: frame, completion: .contentProcessed { _ in }) }
    }

    func send<P: Codable & Hashable & Sendable>(_ envelope: BridgeEnvelope<P>, to clientId: UUID) {
        guard let c = clients[clientId], let data = try? DNPCoders.encode(envelope) else { return }
        c.send(content: Self.frame(data), completion: .contentProcessed { _ in })
    }

    /// Forcibly close one connection (e.g., after a denied pairing or revocation).
    func dropConnection(_ connectionId: UUID) {
        clients[connectionId]?.cancel()
    }

    /// Caller-supplied handler — set by `MacAppViewModel` to dispatch to ApprovalCoordinator, etc.
    var onIncomingFrame: ((Data, UUID) -> Void)?
    /// Called when a connection is dropped, for the dispatcher's tracking maps.
    var onConnectionDropped: ((UUID) -> Void)?
    /// Called the moment a TCP connection lands, before any frame has been read.
    /// Drives the live "iPhone connecting…" beat in PairingSheet.
    /// `remoteDescription` is `host:port` of the peer.
    var onConnectionAccepted: ((UUID, String) -> Void)?

    // MARK: - Private

    private func dropClient(_ id: UUID) {
        clients.removeValue(forKey: id)
        Task { @MainActor in self.connections.remove(id) }
        onConnectionDropped?(id)
    }

    private func receiveLoop(connectionId: UUID) {
        guard let conn = clients[connectionId] else { return }
        // Read 4-byte length prefix
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 4, error == nil else {
                self?.dropClient(connectionId); return
            }
            let len = Int(UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3]))
            guard len > 0, len < 4 * 1024 * 1024 else { self.dropClient(connectionId); return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { payload, _, _, error in
                guard let payload, payload.count == len, error == nil else { self.dropClient(connectionId); return }
                self.onIncomingFrame?(payload, connectionId)
                self.receiveLoop(connectionId: connectionId)
            }
        }
    }

    private static func frame(_ data: Data) -> Data {
        var out = Data(capacity: data.count + 4)
        let len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}
