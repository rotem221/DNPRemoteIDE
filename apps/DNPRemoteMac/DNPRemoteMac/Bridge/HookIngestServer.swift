import Foundation
import Network

/// Tiny HTTP/1.1 listener on `127.0.0.1:18734` that accepts `POST /hook` from
/// `tools/dnp-hook-relay`. Each request body is the JSON the relay built — we forward it to the
/// owning view model for normalization → broadcast to iOS.
final class HookIngestServer: @unchecked Sendable {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dnp.hook.ingest")
    private(set) var port: Int?

    /// Called for every successful POST. Body is the raw JSON the relay sent.
    var onHook: ((Data) -> Void)?

    func start(preferredPort: UInt16 = 18734) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: preferredPort))
            self.listener = l
            l.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.port = Int(preferredPort) }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                self.handle(conn)
            }
            l.start(queue: queue)
            print("[HookIngest] listening on \(preferredPort)")
        } catch {
            print("[HookIngest] failed to start: \(error)")
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    // MARK: - Per-connection handling (one request → one response, then close).

    private func handle(_ conn: NWConnection) {
        var accumulated = Data()
        receive(conn, into: &accumulated)
    }

    private func receive(_ conn: NWConnection, into buffer: inout Data) {
        var buf = buffer
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { buf.append(data) }
            if let error = error {
                print("[HookIngest] receive error: \(error)")
                conn.cancel(); return
            }

            if let body = Self.parseRequestBody(buf) {
                // Got a complete request body — invoke and reply.
                self.onHook?(body)
                self.respondOK(conn)
                return
            }
            if isComplete {
                self.respondOK(conn)
                return
            }
            self.receive(conn, into: &buf)
        }
    }

    /// Returns the body if `buf` contains a complete HTTP/1.1 request with `Content-Length` bytes
    /// after the header terminator. Returns nil if more bytes are needed.
    private static func parseRequestBody(_ data: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let headerBytes = data.subdata(in: 0..<range.lowerBound)
        guard let header = String(data: headerBytes, encoding: .utf8) else { return nil }

        // Read Content-Length.
        var length: Int? = nil
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let v = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                length = Int(v)
            }
        }
        let bodyStart = range.upperBound
        guard let len = length else {
            // No body declared — treat header alone as the request.
            return Data()
        }
        let available = data.count - bodyStart
        guard available >= len else { return nil }
        return data.subdata(in: bodyStart..<(bodyStart + len))
    }

    private func respondOK(_ conn: NWConnection) {
        let body = "{\"status\":\"ok\"}"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
