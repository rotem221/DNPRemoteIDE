import Foundation

/// Tracks recently-seen nonces per sender to reject replays. Bounded LRU.
public final class ReplayProtection: @unchecked Sendable {
    private let lock = NSLock()
    private var nonces: [UUID: NonceCache] = [:]
    private let maxClockSkew: TimeInterval
    private let cacheCapacity: Int
    private let now: () -> Date

    public init(
        maxClockSkewSeconds: TimeInterval = ProtocolConstants.maxClockSkewSeconds,
        cacheCapacity: Int = ProtocolConstants.maxNonceCacheSize,
        now: @escaping () -> Date = { Date() }
    ) {
        self.maxClockSkew = maxClockSkewSeconds
        self.cacheCapacity = cacheCapacity
        self.now = now
    }

    /// Records the nonce as observed. Returns `true` if accepted, `false` if it's a replay or stale.
    public func accept(senderId: UUID, nonce: String, timestamp: Date) -> Result<Void, BridgeSecurityError> {
        let n = now()
        if abs(n.timeIntervalSince(timestamp)) > maxClockSkew {
            return .failure(.staleTimestamp)
        }
        lock.lock(); defer { lock.unlock() }
        var cache = nonces[senderId] ?? NonceCache(capacity: cacheCapacity)
        if cache.contains(nonce) {
            return .failure(.replayedNonce)
        }
        cache.insert(nonce)
        nonces[senderId] = cache
        return .success(())
    }

    /// Drop a sender (e.g., when revoked).
    public func forget(senderId: UUID) {
        lock.lock(); defer { lock.unlock() }
        nonces.removeValue(forKey: senderId)
    }
}

private struct NonceCache {
    private var order: [String] = []
    private var set: Set<String> = []
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func contains(_ nonce: String) -> Bool { set.contains(nonce) }

    mutating func insert(_ nonce: String) {
        guard !set.contains(nonce) else { return }
        order.append(nonce)
        set.insert(nonce)
        if order.count > capacity {
            let drop = order.removeFirst()
            set.remove(drop)
        }
    }
}
