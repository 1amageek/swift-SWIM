/// SWIM Dissemination State
///
/// Value-type accounting for gossip dissemination: the broadcast queue plus the
/// current dissemination limit. Embedded-clean — no `Synchronization.Mutex`, no
/// clock, no Foundation. The caller (the `Disseminator` adapter) owns
/// synchronization and drives these `mutating` methods under its own lock.

/// Mutable accounting state for gossip dissemination.
///
/// Maintains a priority queue of membership updates that should be piggybacked
/// on protocol messages. Updates are sent multiple times (controlled by
/// ``disseminationLimit``) to ensure reliable propagation.
public struct DisseminationState: Sendable {
    /// The priority queue of pending updates.
    public private(set) var queue: BroadcastQueue

    /// Maximum number of updates to include per outgoing message.
    public let maxPayloadSize: Int

    /// Number of times to send each update.
    ///
    /// This must grow with `log(N)` as the cluster grows, so it lives in the
    /// mutable state rather than being fixed at init. Otherwise large clusters
    /// would under-disseminate (each update dropped after too few sends to reach
    /// everyone).
    public private(set) var disseminationLimit: Int

    /// Creates a new dissemination state.
    ///
    /// - Parameters:
    ///   - maxPayloadSize: Maximum number of updates per message.
    ///   - disseminationLimit: Initial number of times to send each update.
    public init(maxPayloadSize: Int, disseminationLimit: Int) {
        self.maxPayloadSize = maxPayloadSize
        self.disseminationLimit = disseminationLimit
        self.queue = BroadcastQueue()
    }

    /// Updates the dissemination limit to reflect the current cluster size.
    ///
    /// - Parameter newLimit: The recomputed limit (clamped to at least 1).
    public mutating func updateDisseminationLimit(_ newLimit: Int) {
        disseminationLimit = Swift.max(1, newLimit)
    }

    /// Enqueues a membership update for dissemination.
    public mutating func enqueue(_ update: MembershipUpdate) {
        queue.push(update)
    }

    /// Enqueues a membership update for a member.
    public mutating func enqueue(member: Member) {
        queue.push(MembershipUpdate(member: member))
    }

    /// Enqueues multiple updates.
    public mutating func enqueue(_ updates: [MembershipUpdate]) {
        for update in updates {
            queue.push(update)
        }
    }

    /// Selects updates to piggyback on the next outgoing message, increments
    /// their dissemination count, and prunes any that exceeded the limit.
    ///
    /// - Returns: Gossip payload with up to ``maxPayloadSize`` updates.
    public mutating func getPayloadForMessage() -> GossipPayload {
        let updates = queue.peek(count: maxPayloadSize)

        if updates.isEmpty {
            return .empty
        }

        // Increment dissemination count for the selected members.
        let memberIDs = Set(updates.map { $0.memberID })
        queue.incrementDisseminationCount(for: memberIDs)

        // Remove expired updates.
        queue.removeExpired(limit: disseminationLimit)

        return GossipPayload(updates: updates)
    }

    /// Returns the top updates without incrementing the dissemination count.
    public func peekUpdates(count: Int? = nil) -> [MembershipUpdate] {
        queue.peek(count: count ?? maxPayloadSize)
    }

    /// Number of updates pending in the queue.
    public var pendingCount: Int {
        queue.count
    }

    /// Whether the queue is empty.
    public var isEmpty: Bool {
        queue.isEmpty
    }

    /// Removes an update for a specific member.
    public mutating func remove(for memberID: MemberID) {
        queue.remove(for: memberID)
    }

    /// Clears all pending updates.
    public mutating func clear() {
        queue = BroadcastQueue()
    }
}
