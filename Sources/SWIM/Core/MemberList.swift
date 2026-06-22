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
        /// Timestamps when members were marked dead (for GC)
        var deadTimestamps: [MemberID: ContinuousClock.Instant]
        /// Index for round-robin selection
        var probeIndex: Int

        init() {
            self.members = [:]
            self.aliveMembers = []
            self.suspectMembers = []
            self.deadMembers = []
            self.deadTimestamps = [:]
            self.probeIndex = 0
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

    /// Returns the next probe target using round-robin selection.
    ///
    /// This ensures all members are probed eventually, providing
    /// more consistent failure detection across the cluster.
    ///
    /// - Parameter excluding: Set of member IDs to exclude from selection
    /// - Returns: A member to probe, or nil if none available
    public func nextRoundRobinTarget(excluding: Set<MemberID> = []) -> Member? {
        state.withLock { state in
            let candidates = Self.sortedMemberIDs(
                state.aliveMembers
                    .union(state.suspectMembers)
                    .subtracting(excluding)
            )
            guard !candidates.isEmpty else { return nil }

            // Reset index if it exceeds array bounds
            state.probeIndex = state.probeIndex % candidates.count
            let id = candidates[state.probeIndex]
            state.probeIndex += 1

            return state.members[id]
        }
    }

    /// Removes dead members older than the specified retention period.
    ///
    /// Dead members are kept for a period to allow gossip propagation.
    /// After the retention period, they are removed from memory.
    ///
    /// - Parameter retention: Duration after which dead members are removed
    /// - Returns: IDs of removed members
    @discardableResult
    public func removeDeadMembers(olderThan retention: Duration) -> [MemberID] {
        state.withLock { state in
            let now = ContinuousClock.now
            var removed: [MemberID] = []

            for (id, timestamp) in state.deadTimestamps {
                if now - timestamp > retention {
                    state.members.removeValue(forKey: id)
                    state.deadMembers.remove(id)
                    state.deadTimestamps.removeValue(forKey: id)
                    removed.append(id)
                }
            }

            return removed
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
                return Self.applyExistingUpdate(&state, member: member, existing: existing)
            } else {
                return Self.insertNewMember(&state, member: member)
            }
        }
    }

    /// Applies an update for an already-known member, enforcing precedence rules.
    ///
    /// Must be called while holding the state lock.
    private static func applyExistingUpdate(
        _ state: inout State,
        member: Member,
        existing: Member
    ) -> MembershipChange? {
        // Apply update rules
        guard shouldApplyUpdate(existing: existing, update: member) else {
            return nil
        }

        let previousStatus = existing.status
        state.members[member.id] = member
        updateStatusSets(&state, for: member, previousStatus: previousStatus)

        // Track dead timestamp for GC (learned via gossip)
        if member.status == .dead && previousStatus != .dead {
            state.deadTimestamps[member.id] = .now
        }
        // Clear dead timestamp if member recovered
        if member.status != .dead && previousStatus == .dead {
            state.deadTimestamps.removeValue(forKey: member.id)
        }

        if previousStatus != member.status {
            return .statusChanged(member, from: previousStatus)
        }
        return nil
    }

    /// Inserts a brand-new member.
    ///
    /// Must be called while holding the state lock.
    private static func insertNewMember(
        _ state: inout State,
        member: Member
    ) -> MembershipChange? {
        state.members[member.id] = member
        updateStatusSets(&state, for: member)
        // Track dead timestamp for new dead members (learned via gossip)
        if member.status == .dead {
            state.deadTimestamps[member.id] = .now
        }
        return .joined(member)
    }

    /// Applies a gossiped member update through the trust boundary.
    ///
    /// Unlike ``update(_:)`` (which trusts its input completely and is used for
    /// locally-originated state), this variant enforces the sanity bounds that
    /// make the trust boundary explicit for *unauthenticated* gossip:
    ///
    /// 1. **Incarnation jump bound** — rejects an update whose incarnation is
    ///    further than `maxIncarnationDelta` ahead of the locally known
    ///    incarnation. A forged, implausibly high incarnation would otherwise win
    ///    every conflict and could mark any member dead or make a peer
    ///    undetectable.
    /// 2. **Member-table cap** — rejects admitting a brand-new member once the
    ///    table holds `maxMemberCount` members, bounding memory growth from a
    ///    flood of forged `alive` members (GC only reclaims dead members).
    ///
    /// Rejections are surfaced as ``MemberListRejection`` rather than silently
    /// dropped, so the caller can decide how to react.
    ///
    /// - Parameters:
    ///   - member: The gossiped member state to apply.
    ///   - maxIncarnationDelta: Maximum allowed forward incarnation delta. Pass
    ///     `nil` to disable the bound.
    ///   - maxMemberCount: Maximum member-table size. Pass `nil` to disable the cap.
    /// - Returns: The membership change if the update was applied, or `nil` if it
    ///   was superseded by existing state.
    /// - Throws: ``MemberListRejection`` if a sanity bound is violated.
    @discardableResult
    public func applyGossip(
        _ member: Member,
        maxIncarnationDelta: UInt64?,
        maxMemberCount: Int?
    ) throws -> MembershipChange? {
        try state.withLock { state in
            if let existing = state.members[member.id] {
                // Sanity bound only applies to forward jumps. A non-advancing
                // update can never inflate the logical clock, so it is harmless
                // here and will be filtered by the normal precedence rules below.
                if let maxDelta = maxIncarnationDelta,
                   member.incarnation > existing.incarnation {
                    let delta = member.incarnation.value - existing.incarnation.value
                    if delta > maxDelta {
                        throw MemberListRejection.incarnationJumpTooLarge(
                            memberID: member.id,
                            known: existing.incarnation,
                            proposed: member.incarnation,
                            maxDelta: maxDelta
                        )
                    }
                }
                return Self.applyExistingUpdate(&state, member: member, existing: existing)
            } else {
                // New member: enforce the absolute incarnation bound (a fresh
                // member is "known" at .initial) and the table-size cap.
                if let maxDelta = maxIncarnationDelta,
                   member.incarnation.value > maxDelta {
                    throw MemberListRejection.incarnationJumpTooLarge(
                        memberID: member.id,
                        known: .initial,
                        proposed: member.incarnation,
                        maxDelta: maxDelta
                    )
                }
                if let limit = maxMemberCount, state.members.count >= limit {
                    throw MemberListRejection.memberTableFull(
                        memberID: member.id,
                        limit: limit
                    )
                }
                return Self.insertNewMember(&state, member: member)
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
            state.deadTimestamps.removeValue(forKey: id)
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

    /// Marks a suspected member as dead because its suspicion timeout expired.
    ///
    /// This is the *kill* path driven by the suspicion timer. To preserve the
    /// core SWIM safety property — "a node that refutes a suspicion must not be
    /// declared dead" — the kill only applies when the member is **still**
    /// `.suspect` at the **exact** incarnation captured when suspicion started.
    ///
    /// Any refutation in the meantime (the member transitions to `.alive` and/or
    /// bumps its incarnation) changes either the status or the incarnation, which
    /// invalidates the pending kill via strict equality. A stale "dead at N"
    /// therefore cannot kill a member that is currently alive at N, and an
    /// already-refuted member is never killed by an old timer.
    ///
    /// - Parameters:
    ///   - id: The member to mark dead.
    ///   - incarnation: The incarnation captured when suspicion started.
    /// - Returns: The membership change if the kill applied, otherwise `nil`.
    @discardableResult
    public func markDead(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        state.withLock { state in
            guard var member = state.members[id] else { return nil }
            // Strict precondition: still suspect AND exact captured incarnation.
            // Any refutation (status -> .alive or incarnation bump) invalidates
            // this pending kill.
            guard member.status == .suspect, member.incarnation == incarnation else {
                return nil
            }

            let previousStatus = member.status
            member.status = .dead
            state.members[id] = member
            Self.updateStatusSets(&state, for: member, previousStatus: previousStatus)

            // Record timestamp for GC
            state.deadTimestamps[id] = .now

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

            // Clear dead timestamp if recovering from dead status
            if previousStatus == .dead {
                state.deadTimestamps.removeValue(forKey: id)
            }

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

    private static func sortedMemberIDs<S: Sequence>(_ ids: S) -> [MemberID] where S.Element == MemberID {
        Array(ids).sorted { lhs, rhs in
            if lhs.id != rhs.id {
                return lhs.id < rhs.id
            }
            return lhs.address < rhs.address
        }
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
