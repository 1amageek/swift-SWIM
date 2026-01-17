/// SWIM Member List
///
/// Thread-safe collection of cluster members with efficient
/// random selection for failure detection.

import Synchronization

/// Thread-safe member list for SWIM protocol.
///
/// Provides efficient operations for:
/// - Adding/updating/removing members
/// - Random member selection for probing
/// - Status-based queries
public final class MemberList: Sendable {

    private let state: Mutex<State>

    private struct State: Sendable {
        var members: [MemberID: Member]
        var aliveMembers: Set<MemberID>
        var suspectMembers: Set<MemberID>
        var deadMembers: Set<MemberID>

        init() {
            self.members = [:]
            self.aliveMembers = []
            self.suspectMembers = []
            self.deadMembers = []
        }
    }

    /// Creates an empty member list.
    public init() {
        self.state = Mutex(State())
    }

    /// Creates a member list with initial members.
    public init(members: [Member]) {
        var state = State()
        for member in members {
            state.members[member.id] = member
            Self.updateStatusSets(&state, for: member)
        }
        self.state = Mutex(state)
    }

    // MARK: - Query Operations

    /// Returns the member with the given ID, if present.
    public func member(for id: MemberID) -> Member? {
        state.withLock { $0.members[id] }
    }

    /// Returns all members in the list.
    public var allMembers: [Member] {
        state.withLock { Array($0.members.values) }
    }

    /// Returns the number of members in the list.
    public var count: Int {
        state.withLock { $0.members.count }
    }

    /// Returns the number of alive members.
    public var aliveCount: Int {
        state.withLock { $0.aliveMembers.count }
    }

    /// Returns the number of suspect members.
    public var suspectCount: Int {
        state.withLock { $0.suspectMembers.count }
    }

    /// Returns all alive members.
    public var aliveMembers: [Member] {
        state.withLock { state in
            state.aliveMembers.compactMap { state.members[$0] }
        }
    }

    /// Returns all suspect members.
    public var suspectMembers: [Member] {
        state.withLock { state in
            state.suspectMembers.compactMap { state.members[$0] }
        }
    }

    /// Returns whether the list contains a member with the given ID.
    public func contains(_ id: MemberID) -> Bool {
        state.withLock { $0.members[id] != nil }
    }

    // MARK: - Random Selection

    /// Returns a random alive member, excluding specified IDs.
    ///
    /// - Parameter excluding: Set of member IDs to exclude from selection
    /// - Returns: A random alive member, or nil if none available
    public func randomAliveMember(excluding: Set<MemberID> = []) -> Member? {
        state.withLock { state in
            let candidates = state.aliveMembers.subtracting(excluding)
            guard !candidates.isEmpty else { return nil }
            let randomID = candidates.randomElement()!
            return state.members[randomID]
        }
    }

    /// Returns multiple random alive members, excluding specified IDs.
    ///
    /// - Parameters:
    ///   - count: Maximum number of members to return
    ///   - excluding: Set of member IDs to exclude from selection
    /// - Returns: Array of random alive members (may be fewer than requested)
    public func randomAliveMembers(count: Int, excluding: Set<MemberID> = []) -> [Member] {
        state.withLock { state in
            let candidates = Array(state.aliveMembers.subtracting(excluding))
            guard !candidates.isEmpty else { return [] }

            let selectCount = min(count, candidates.count)
            var selected: [Member] = []
            selected.reserveCapacity(selectCount)

            var available = candidates
            for _ in 0..<selectCount {
                let index = Int.random(in: 0..<available.count)
                let id = available.remove(at: index)
                if let member = state.members[id] {
                    selected.append(member)
                }
            }

            return selected
        }
    }

    /// Returns a random member from alive or suspect, excluding specified IDs.
    ///
    /// This is useful for failure detection - we want to probe both
    /// alive and suspect members.
    public func randomProbableTarget(excluding: Set<MemberID> = []) -> Member? {
        state.withLock { state in
            let candidates = state.aliveMembers
                .union(state.suspectMembers)
                .subtracting(excluding)
            guard !candidates.isEmpty else { return nil }
            let randomID = candidates.randomElement()!
            return state.members[randomID]
        }
    }

    // MARK: - Mutation Operations

    /// Updates a member in the list.
    ///
    /// Returns the membership change if the update was applied, or nil if
    /// the update was superseded by existing state.
    ///
    /// Update rules:
    /// 1. Higher incarnation always wins
    /// 2. If same incarnation, higher severity status wins (dead > suspect > alive)
    /// 3. New member is always added
    @discardableResult
    public func update(_ member: Member) -> MembershipChange? {
        state.withLock { state in
            if let existing = state.members[member.id] {
                // Apply update rules
                if !Self.shouldApplyUpdate(existing: existing, update: member) {
                    return nil
                }

                let previousStatus = existing.status
                state.members[member.id] = member
                Self.updateStatusSets(&state, for: member, previousStatus: previousStatus)

                if previousStatus != member.status {
                    return .statusChanged(member, from: previousStatus)
                }
                return nil
            } else {
                // New member
                state.members[member.id] = member
                Self.updateStatusSets(&state, for: member)
                return .joined(member)
            }
        }
    }

    /// Removes a member from the list.
    ///
    /// - Parameter id: The ID of the member to remove
    /// - Returns: The removed member, or nil if not found
    @discardableResult
    public func remove(_ id: MemberID) -> Member? {
        state.withLock { state in
            guard let member = state.members.removeValue(forKey: id) else {
                return nil
            }
            state.aliveMembers.remove(id)
            state.suspectMembers.remove(id)
            state.deadMembers.remove(id)
            return member
        }
    }

    /// Marks a member as suspect.
    ///
    /// Only applies if the member is currently alive and the incarnation matches.
    @discardableResult
    public func markSuspect(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        state.withLock { state in
            guard var member = state.members[id] else { return nil }
            guard member.status == .alive, member.incarnation == incarnation else { return nil }

            let previousStatus = member.status
            member.status = .suspect
            state.members[id] = member
            Self.updateStatusSets(&state, for: member, previousStatus: previousStatus)

            return .statusChanged(member, from: previousStatus)
        }
    }

    /// Marks a member as dead.
    ///
    /// Only applies if the incarnation matches or is older.
    @discardableResult
    public func markDead(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        state.withLock { state in
            guard var member = state.members[id] else { return nil }
            guard member.incarnation <= incarnation else { return nil }

            let previousStatus = member.status
            if previousStatus == .dead { return nil }

            member.status = .dead
            member.incarnation = incarnation
            state.members[id] = member
            Self.updateStatusSets(&state, for: member, previousStatus: previousStatus)

            return .statusChanged(member, from: previousStatus)
        }
    }

    /// Marks a member as alive with a new incarnation.
    ///
    /// This is used when a member refutes a suspicion.
    @discardableResult
    public func markAlive(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        state.withLock { state in
            guard var member = state.members[id] else { return nil }

            // Must have higher incarnation to refute
            guard incarnation > member.incarnation else { return nil }

            let previousStatus = member.status
            member.status = .alive
            member.incarnation = incarnation
            state.members[id] = member
            Self.updateStatusSets(&state, for: member, previousStatus: previousStatus)

            if previousStatus != .alive {
                return .statusChanged(member, from: previousStatus)
            }
            return nil
        }
    }

    // MARK: - Private Helpers

    private static func shouldApplyUpdate(existing: Member, update: Member) -> Bool {
        // Higher incarnation always wins
        if update.incarnation > existing.incarnation {
            return true
        }
        if update.incarnation < existing.incarnation {
            return false
        }

        // Same incarnation: higher severity wins
        return update.status > existing.status
    }

    private static func updateStatusSets(
        _ state: inout State,
        for member: Member,
        previousStatus: MemberStatus? = nil
    ) {
        let id = member.id

        // Remove from previous status set if known
        if let previous = previousStatus {
            switch previous {
            case .alive: state.aliveMembers.remove(id)
            case .suspect: state.suspectMembers.remove(id)
            case .dead: state.deadMembers.remove(id)
            }
        } else {
            // Remove from all sets (for new members or unknown previous)
            state.aliveMembers.remove(id)
            state.suspectMembers.remove(id)
            state.deadMembers.remove(id)
        }

        // Add to new status set
        switch member.status {
        case .alive: state.aliveMembers.insert(id)
        case .suspect: state.suspectMembers.insert(id)
        case .dead: state.deadMembers.insert(id)
        }
    }
}

extension MemberList: CustomStringConvertible {
    public var description: String {
        let (total, alive, suspect) = state.withLock { state in
            (state.members.count, state.aliveMembers.count, state.suspectMembers.count)
        }
        return "MemberList(total: \(total), alive: \(alive), suspect: \(suspect))"
    }
}
