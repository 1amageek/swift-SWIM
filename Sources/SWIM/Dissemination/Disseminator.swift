/// SWIM Disseminator
///
/// Manages gossip dissemination of membership updates.

import Synchronization

/// Manages gossip dissemination.
///
/// The disseminator maintains a queue of membership updates that should
/// be piggybacked on protocol messages. Updates are sent multiple times
/// (controlled by `disseminationLimit`) to ensure reliable propagation.
public final class Disseminator: Sendable {
    private let state: Mutex<DisseminationState>
    private let maxPayloadSize: Int

    private struct DisseminationState: Sendable {
        var queue: BroadcastQueue
        /// Number of times to send each update.
        ///
        /// This must grow with `log(N)` as the cluster grows, so it lives in the
        /// mutable state rather than being fixed at init. Otherwise large
        /// clusters would under-disseminate (each update dropped after too few
        /// sends to reach everyone).
        var disseminationLimit: Int
    }

    /// Creates a new disseminator.
    ///
    /// - Parameters:
    ///   - maxPayloadSize: Maximum number of updates per message
    ///   - disseminationLimit: Initial number of times to send each update
    public init(maxPayloadSize: Int = 10, disseminationLimit: Int = 6) {
        self.maxPayloadSize = maxPayloadSize
        self.state = Mutex(
            DisseminationState(queue: BroadcastQueue(), disseminationLimit: disseminationLimit)
        )
    }

    /// Updates the dissemination limit to reflect the current cluster size.
    ///
    /// Call this when the member count changes so each update is piggybacked
    /// enough times to reach the whole (grown) cluster.
    ///
    /// - Parameter newLimit: The recomputed limit (must be at least 1).
    public func updateDisseminationLimit(_ newLimit: Int) {
        state.withLock { state in
            state.disseminationLimit = Swift.max(1, newLimit)
        }
    }

    /// The current dissemination limit.
    public var disseminationLimit: Int {
        state.withLock { $0.disseminationLimit }
    }

    // MARK: - Enqueue Updates

    /// Enqueues a membership update for dissemination.
    ///
    /// - Parameter update: The update to disseminate
    public func enqueue(_ update: MembershipUpdate) {
        state.withLock { state in
            state.queue.push(update)
        }
    }

    /// Enqueues a membership update for a member.
    ///
    /// - Parameter member: The member whose state to disseminate
    public func enqueue(member: Member) {
        let update = MembershipUpdate(member: member)
        enqueue(update)
    }

    /// Enqueues multiple updates.
    public func enqueue(_ updates: [MembershipUpdate]) {
        state.withLock { state in
            for update in updates {
                state.queue.push(update)
            }
        }
    }

    // MARK: - Get Payload

    /// Gets updates to piggyback on the next outgoing message.
    ///
    /// This returns up to `maxPayloadSize` updates and increments their
    /// dissemination count.
    ///
    /// - Returns: Gossip payload with updates to send
    public func getPayloadForMessage() -> GossipPayload {
        state.withLock { state in
            // Get top priority updates
            let updates = state.queue.peek(count: maxPayloadSize)

            if updates.isEmpty {
                return .empty
            }

            // Increment dissemination count
            let memberIDs = Set(updates.map { $0.memberID })
            state.queue.incrementDisseminationCount(for: memberIDs)

            // Remove expired updates
            state.queue.removeExpired(limit: state.disseminationLimit)

            return GossipPayload(updates: updates)
        }
    }

    /// Gets updates without incrementing dissemination count.
    ///
    /// Useful for inspecting the queue without side effects.
    public func peekUpdates(count: Int? = nil) -> [MembershipUpdate] {
        state.withLock { state in
            state.queue.peek(count: count ?? maxPayloadSize)
        }
    }

    // MARK: - Process Incoming Payload

    /// Processes a received gossip payload.
    ///
    /// Updates the member list based on the received updates and
    /// returns any membership changes that occurred.
    ///
    /// - Parameters:
    ///   - payload: The received gossip payload
    ///   - memberList: The member list to update
    /// - Returns: List of membership changes that occurred
    @discardableResult
    public func processPayload(
        _ payload: GossipPayload,
        memberList: MemberList
    ) -> [MembershipChange] {
        var changes: [MembershipChange] = []

        for update in payload.updates {
            let member = update.toMember()

            if let change = memberList.update(member) {
                changes.append(change)

                // Re-disseminate this update to help propagation
                enqueue(update)
            }
        }

        return changes
    }

    // MARK: - Queue Management

    /// Returns the number of updates in the queue.
    public var pendingCount: Int {
        state.withLock { $0.queue.count }
    }

    /// Whether the queue is empty.
    public var isEmpty: Bool {
        state.withLock { $0.queue.isEmpty }
    }

    /// Removes an update for a specific member.
    public func remove(for memberID: MemberID) {
        state.withLock { state in
            state.queue.remove(for: memberID)
        }
    }

    /// Clears all pending updates.
    public func clear() {
        state.withLock { state in
            state.queue = BroadcastQueue()
        }
    }
}
