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
///
/// Uses a Dictionary-based storage for O(1) push operations.
/// Sorting is performed on-demand during peek/pop.
internal struct BroadcastQueue: Sendable {
    /// MemberID -> latest update mapping
    private var memberUpdates: [MemberID: MembershipUpdate]

    /// Creates an empty broadcast queue.
    init() {
        self.memberUpdates = [:]
    }

    /// Whether the queue is empty.
    var isEmpty: Bool {
        memberUpdates.isEmpty
    }

    /// Number of updates in the queue.
    var count: Int {
        memberUpdates.count
    }

    /// Pushes an update to the queue.
    ///
    /// If an update for this member already exists, it's replaced
    /// only if the new update has higher priority.
    ///
    /// Complexity: O(1)
    mutating func push(_ update: MembershipUpdate) {
        if let existing = memberUpdates[update.memberID] {
            // Check if new update should replace existing
            if shouldReplace(existing: existing, with: update) {
                memberUpdates[update.memberID] = update
            }
        } else {
            memberUpdates[update.memberID] = update
        }
    }

    /// Pops the highest priority update from the queue.
    ///
    /// Complexity: O(n log n) due to sorting
    mutating func pop() -> MembershipUpdate? {
        let updates = peek(count: 1)
        guard let first = updates.first else { return nil }
        memberUpdates.removeValue(forKey: first.memberID)
        return first
    }

    /// Peeks at the highest priority updates without removing them.
    ///
    /// Complexity: O(n log n) for sorting, O(k) for taking k elements
    func peek(count: Int) -> [MembershipUpdate] {
        let sorted = memberUpdates.values.sorted { lhs, rhs in
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
        return Array(sorted.prefix(count))
    }

    /// Removes an update for the given member.
    ///
    /// Complexity: O(1)
    mutating func remove(for memberID: MemberID) {
        memberUpdates.removeValue(forKey: memberID)
    }

    /// Increments the dissemination count for updates that were sent.
    ///
    /// Complexity: O(m) where m is the number of member IDs
    mutating func incrementDisseminationCount(for memberIDs: Set<MemberID>) {
        for id in memberIDs {
            memberUpdates[id]?.disseminationCount += 1
        }
    }

    /// Removes updates that have exceeded the dissemination limit.
    ///
    /// Complexity: O(n)
    mutating func removeExpired(limit: Int) {
        memberUpdates = memberUpdates.filter { $0.value.disseminationCount < limit }
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
}
