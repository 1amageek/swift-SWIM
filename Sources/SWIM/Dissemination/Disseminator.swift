/// SWIM Disseminator
///
/// Manages gossip dissemination of membership updates.
///
/// ## Caller-locked adapter
///
/// This is the host-side adapter over the Embedded-clean value-type
/// `SWIMCore.DisseminationState`. It owns the `Synchronization.Mutex`; every
/// public method delegates to the value type's `mutating` methods under the lock,
/// so `Disseminator` keeps its existing `Sendable`, thread-safe behavior. The
/// value type has no Mutex, no clock, and no Foundation.

import Synchronization

/// Manages gossip dissemination.
///
/// The disseminator maintains a queue of membership updates that should be
/// piggybacked on protocol messages. Updates are sent multiple times (controlled
/// by `disseminationLimit`) to ensure reliable propagation.
public final class Disseminator: Sendable {
    private let state: Mutex<DisseminationState>

    /// Creates a new disseminator.
    ///
    /// - Parameters:
    ///   - maxPayloadSize: Maximum number of updates per message
    ///   - disseminationLimit: Initial number of times to send each update
    public init(maxPayloadSize: Int = 10, disseminationLimit: Int = 6) {
        self.state = Mutex(
            DisseminationState(
                maxPayloadSize: maxPayloadSize,
                disseminationLimit: disseminationLimit
            )
        )
    }

    /// Updates the dissemination limit to reflect the current cluster size.
    ///
    /// - Parameter newLimit: The recomputed limit (must be at least 1).
    public func updateDisseminationLimit(_ newLimit: Int) {
        state.withLock { $0.updateDisseminationLimit(newLimit) }
    }

    /// The current dissemination limit.
    public var disseminationLimit: Int {
        state.withLock { $0.disseminationLimit }
    }

    // MARK: - Enqueue Updates

    /// Enqueues a membership update for dissemination.
    public func enqueue(_ update: MembershipUpdate) {
        state.withLock { $0.enqueue(update) }
    }

    /// Enqueues a membership update for a member.
    public func enqueue(member: Member) {
        state.withLock { $0.enqueue(member: member) }
    }

    /// Enqueues multiple updates.
    public func enqueue(_ updates: [MembershipUpdate]) {
        state.withLock { $0.enqueue(updates) }
    }

    // MARK: - Get Payload

    /// Gets updates to piggyback on the next outgoing message.
    ///
    /// This returns up to `maxPayloadSize` updates and increments their
    /// dissemination count.
    public func getPayloadForMessage() -> GossipPayload {
        state.withLock { $0.getPayloadForMessage() }
    }

    /// Gets updates without incrementing dissemination count.
    public func peekUpdates(count: Int? = nil) -> [MembershipUpdate] {
        state.withLock { $0.peekUpdates(count: count) }
    }

    // MARK: - Process Incoming Payload

    /// Processes a received gossip payload.
    ///
    /// Updates the member list based on the received updates and returns any
    /// membership changes that occurred. This orchestrates across both the member
    /// list and this disseminator, so it stays in the adapter (the value-type
    /// cores are single-responsibility).
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

                // Re-disseminate this update to help propagation.
                enqueue(update)
            }
        }

        return changes
    }

    // MARK: - Queue Management

    /// Returns the number of updates in the queue.
    public var pendingCount: Int {
        state.withLock { $0.pendingCount }
    }

    /// Whether the queue is empty.
    public var isEmpty: Bool {
        state.withLock { $0.isEmpty }
    }

    /// Removes an update for a specific member.
    public func remove(for memberID: MemberID) {
        state.withLock { $0.remove(for: memberID) }
    }

    /// Clears all pending updates.
    public func clear() {
        state.withLock { $0.clear() }
    }
}
