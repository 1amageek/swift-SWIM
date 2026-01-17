/// SWIM Broadcast Queue
///
/// Priority queue for membership updates to be disseminated.

import Synchronization

/// Priority queue for membership updates.
///
/// Prioritizes updates by:
/// 1. Status severity (dead > suspect > alive)
/// 2. Lower dissemination count (newer updates first)
/// 3. Higher incarnation
internal struct BroadcastQueue: Sendable {
    private var updates: [MembershipUpdate]
    private var memberUpdates: [MemberID: Int]  // memberID -> index in updates

    /// Creates an empty broadcast queue.
    init() {
        self.updates = []
        self.memberUpdates = [:]
    }

    /// Whether the queue is empty.
    var isEmpty: Bool {
        updates.isEmpty
    }

    /// Number of updates in the queue.
    var count: Int {
        updates.count
    }

    /// Pushes an update to the queue.
    ///
    /// If an update for this member already exists, it's replaced
    /// only if the new update has higher priority.
    mutating func push(_ update: MembershipUpdate) {
        if let existingIndex = memberUpdates[update.memberID] {
            let existing = updates[existingIndex]

            // Check if new update should replace existing
            if shouldReplace(existing: existing, with: update) {
                updates[existingIndex] = update
                sortQueue()
            }
        } else {
            updates.append(update)
            memberUpdates[update.memberID] = updates.count - 1
            sortQueue()
        }
    }

    /// Pops the highest priority update from the queue.
    mutating func pop() -> MembershipUpdate? {
        guard !updates.isEmpty else { return nil }

        let update = updates.removeFirst()
        memberUpdates.removeValue(forKey: update.memberID)

        // Update indices
        for (i, u) in updates.enumerated() {
            memberUpdates[u.memberID] = i
        }

        return update
    }

    /// Peeks at the highest priority updates without removing them.
    func peek(count: Int) -> [MembershipUpdate] {
        Array(updates.prefix(count))
    }

    /// Removes an update for the given member.
    mutating func remove(for memberID: MemberID) {
        guard let index = memberUpdates[memberID] else { return }

        updates.remove(at: index)
        memberUpdates.removeValue(forKey: memberID)

        // Update indices
        for (i, u) in updates.enumerated() {
            memberUpdates[u.memberID] = i
        }
    }

    /// Increments the dissemination count for updates that were sent.
    mutating func incrementDisseminationCount(for memberIDs: Set<MemberID>) {
        for id in memberIDs {
            if let index = memberUpdates[id] {
                updates[index].disseminationCount += 1
            }
        }
        sortQueue()
    }

    /// Removes updates that have exceeded the dissemination limit.
    mutating func removeExpired(limit: Int) {
        updates.removeAll { $0.disseminationCount >= limit }
        memberUpdates.removeAll()
        for (i, u) in updates.enumerated() {
            memberUpdates[u.memberID] = i
        }
    }

    // MARK: - Private

    private func shouldReplace(existing: MembershipUpdate, with new: MembershipUpdate) -> Bool {
        // Higher incarnation always wins
        if new.incarnation > existing.incarnation {
            return true
        }
        if new.incarnation < existing.incarnation {
            return false
        }

        // Same incarnation: higher severity wins
        return new.status.disseminationPriority > existing.status.disseminationPriority
    }

    private mutating func sortQueue() {
        updates.sort { lhs, rhs in
            // Higher priority first
            if lhs.status.disseminationPriority != rhs.status.disseminationPriority {
                return lhs.status.disseminationPriority > rhs.status.disseminationPriority
            }

            // Lower dissemination count first (newer)
            if lhs.disseminationCount != rhs.disseminationCount {
                return lhs.disseminationCount < rhs.disseminationCount
            }

            // Higher incarnation first
            return lhs.incarnation > rhs.incarnation
        }

        // Update indices after sort
        memberUpdates.removeAll()
        for (i, u) in updates.enumerated() {
            memberUpdates[u.memberID] = i
        }
    }
}
