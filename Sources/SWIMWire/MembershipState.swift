/// SWIM Membership State
///
/// The Embedded-clean, value-type SWIM membership state machine: the member
/// table, incarnation/precedence rules, refutation safety, suspicion -> dead
/// promotion, the member-table cap, the gossip trust boundary, and deterministic
/// probe-target enumeration.
///
/// ## Caller-locked + clock-seam design
///
/// This is a pure value type with `mutating` methods. It contains:
/// - NO `Synchronization.Mutex` / actor — the caller owns synchronization and
///   drives these methods under its own lock.
/// - NO `ContinuousClock` / `Date` — every method that needs "now" takes a
///   monotonic timestamp PARAMETER (`nowMillis: UInt64`) supplied by the caller.
/// - NO `SystemRandomNumberGenerator` — random probe selection is split into a
///   deterministic candidate enumeration here plus caller-side randomness, so the
///   core stays deterministic and Embedded-clean.
///
/// The `SWIM` adapter's `MemberList` holds a `MembershipState`, reads its host
/// clock, performs random selection, and calls these methods under a `Mutex`, so
/// observable behavior is identical to the previous Mutex/ContinuousClock-backed
/// implementation.
public struct MembershipState: Sendable {
    /// All known members keyed by ID.
    public private(set) var members: [MemberID: Member]

    /// IDs currently in each status, for O(1) status queries.
    private var aliveMembers: Set<MemberID>
    private var suspectMembers: Set<MemberID>
    private var deadMembers: Set<MemberID>

    /// Monotonic millisecond timestamps when members were marked dead (for GC).
    private var deadTimestamps: [MemberID: UInt64]

    /// Round-robin probe cursor.
    private var probeIndex: Int

    /// Creates an empty membership state.
    public init() {
        self.members = [:]
        self.aliveMembers = []
        self.suspectMembers = []
        self.deadMembers = []
        self.deadTimestamps = [:]
        self.probeIndex = 0
    }

    /// Creates a membership state seeded with initial members.
    public init(members: [Member]) {
        self.init()
        for member in members {
            self.members[member.id] = member
            Self.updateStatusSets(&self, for: member)
        }
    }

    // MARK: - Query Operations

    /// Returns the member with the given ID, if present.
    public func member(for id: MemberID) -> Member? {
        members[id]
    }

    /// Returns all members.
    public var allMembers: [Member] {
        Array(members.values)
    }

    /// Total number of members.
    public var count: Int {
        members.count
    }

    /// Number of alive members.
    public var aliveCount: Int {
        aliveMembers.count
    }

    /// Number of suspect members.
    public var suspectCount: Int {
        suspectMembers.count
    }

    /// All alive members.
    public var aliveMemberList: [Member] {
        aliveMembers.compactMap { members[$0] }
    }

    /// All suspect members.
    public var suspectMemberList: [Member] {
        suspectMembers.compactMap { members[$0] }
    }

    /// Whether the table contains a member with the given ID.
    public func contains(_ id: MemberID) -> Bool {
        members[id] != nil
    }

    // MARK: - Probe-Target Enumeration (deterministic; caller adds randomness)

    /// Returns the IDs of alive members, excluding `excluding`, in stable order.
    ///
    /// The caller performs random selection over this candidate set so the core
    /// stays deterministic and Embedded-clean (no system RNG).
    public func aliveCandidates(excluding: Set<MemberID>) -> [MemberID] {
        Self.sortedMemberIDs(aliveMembers.subtracting(excluding))
    }

    /// Returns the IDs of alive-or-suspect members, excluding `excluding`, in
    /// stable order. Used for failure-detection probing (both alive and suspect).
    public func probableCandidates(excluding: Set<MemberID>) -> [MemberID] {
        Self.sortedMemberIDs(
            aliveMembers.union(suspectMembers).subtracting(excluding)
        )
    }

    /// Returns the next probe target using round-robin selection.
    ///
    /// Candidates are the alive-or-suspect members (minus `excluding`) in stable
    /// order; the internal cursor advances each call, so all members are probed
    /// eventually. This `mutating` method owns the cursor — the caller drives it
    /// under its lock.
    ///
    /// - Returns: A member to probe, or nil if none available.
    public mutating func nextRoundRobinTarget(excluding: Set<MemberID>) -> Member? {
        let candidates = Self.sortedMemberIDs(
            aliveMembers.union(suspectMembers).subtracting(excluding)
        )
        guard !candidates.isEmpty else { return nil }

        // Reset index if it exceeds array bounds.
        probeIndex = probeIndex % candidates.count
        let id = candidates[probeIndex]
        probeIndex += 1

        return members[id]
    }

    // MARK: - Garbage Collection

    /// Removes dead members whose death is older than `retentionMillis`,
    /// measured against the injected `nowMillis`.
    ///
    /// Dead members are kept for a period to allow gossip propagation. After the
    /// retention period, they are removed from memory.
    ///
    /// - Parameters:
    ///   - retentionMillis: Retention window in milliseconds.
    ///   - nowMillis: The current monotonic time in milliseconds.
    /// - Returns: IDs of removed members.
    public mutating func removeDeadMembers(
        olderThanMillis retentionMillis: UInt64,
        nowMillis: UInt64
    ) -> [MemberID] {
        var removed: [MemberID] = []

        for (id, timestamp) in deadTimestamps {
            // Elapsed since death, guarding against a non-monotonic clock skew.
            let elapsed = nowMillis >= timestamp ? nowMillis - timestamp : 0
            if elapsed > retentionMillis {
                members.removeValue(forKey: id)
                deadMembers.remove(id)
                deadTimestamps.removeValue(forKey: id)
                removed.append(id)
            }
        }

        return removed
    }

    // MARK: - Mutation Operations

    /// Updates a member, enforcing precedence rules. Trusts its input completely
    /// (used for locally-originated state); use ``applyGossip(_:maxIncarnationDelta:maxMemberCount:nowMillis:)``
    /// for unauthenticated gossip.
    ///
    /// Update rules:
    /// 1. Higher incarnation always wins.
    /// 2. If same incarnation, higher severity status wins (dead > suspect > alive).
    /// 3. A new member is always added.
    ///
    /// - Parameters:
    ///   - member: The member state to apply.
    ///   - nowMillis: The current monotonic time, used to record dead timestamps.
    /// - Returns: The membership change if applied, or nil if superseded.
    @discardableResult
    public mutating func update(_ member: Member, nowMillis: UInt64) -> MembershipChange? {
        if let existing = members[member.id] {
            return applyExistingUpdate(member: member, existing: existing, nowMillis: nowMillis)
        } else {
            return insertNewMember(member, nowMillis: nowMillis)
        }
    }

    /// Applies a gossiped member update through the trust boundary.
    ///
    /// Unlike ``update(_:nowMillis:)`` (which trusts its input completely), this
    /// variant enforces the sanity bounds that make the trust boundary explicit
    /// for *unauthenticated* gossip:
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
    ///   - nowMillis: The current monotonic time, used to record dead timestamps.
    /// - Returns: The membership change if applied, or nil if superseded.
    /// - Throws: ``MemberListRejection`` if a sanity bound is violated.
    @discardableResult
    public mutating func applyGossip(
        _ member: Member,
        maxIncarnationDelta: UInt64?,
        maxMemberCount: Int?,
        nowMillis: UInt64
    ) throws(MemberListRejection) -> MembershipChange? {
        if let existing = members[member.id] {
            // Sanity bound only applies to forward jumps. A non-advancing update
            // can never inflate the logical clock, so it is harmless here and
            // will be filtered by the normal precedence rules below.
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
            return applyExistingUpdate(member: member, existing: existing, nowMillis: nowMillis)
        } else {
            // New member: enforce the absolute incarnation bound (a fresh member
            // is "known" at .initial) and the table-size cap.
            if let maxDelta = maxIncarnationDelta,
               member.incarnation.value > maxDelta {
                throw MemberListRejection.incarnationJumpTooLarge(
                    memberID: member.id,
                    known: .initial,
                    proposed: member.incarnation,
                    maxDelta: maxDelta
                )
            }
            if let limit = maxMemberCount, members.count >= limit {
                throw MemberListRejection.memberTableFull(
                    memberID: member.id,
                    limit: limit
                )
            }
            return insertNewMember(member, nowMillis: nowMillis)
        }
    }

    /// Removes a member from the table.
    ///
    /// - Returns: The removed member, or nil if not found.
    @discardableResult
    public mutating func remove(_ id: MemberID) -> Member? {
        guard let member = members.removeValue(forKey: id) else {
            return nil
        }
        aliveMembers.remove(id)
        suspectMembers.remove(id)
        deadMembers.remove(id)
        deadTimestamps.removeValue(forKey: id)
        return member
    }

    /// Marks a member as suspect.
    ///
    /// Only applies if the member is currently alive and the incarnation matches.
    @discardableResult
    public mutating func markSuspect(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        guard var member = members[id] else { return nil }
        guard member.status == .alive, member.incarnation == incarnation else { return nil }

        let previousStatus = member.status
        member.status = .suspect
        members[id] = member
        Self.updateStatusSets(&self, for: member, previousStatus: previousStatus)

        return .statusChanged(member, from: previousStatus)
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
    /// invalidates the pending kill via strict equality.
    ///
    /// - Parameters:
    ///   - id: The member to mark dead.
    ///   - incarnation: The incarnation captured when suspicion started.
    ///   - nowMillis: The current monotonic time, recorded for GC.
    /// - Returns: The membership change if the kill applied, otherwise nil.
    @discardableResult
    public mutating func markDead(
        _ id: MemberID,
        incarnation: Incarnation,
        nowMillis: UInt64
    ) -> MembershipChange? {
        guard var member = members[id] else { return nil }
        // Strict precondition: still suspect AND exact captured incarnation. Any
        // refutation (status -> .alive or incarnation bump) invalidates this
        // pending kill.
        guard member.status == .suspect, member.incarnation == incarnation else {
            return nil
        }

        let previousStatus = member.status
        member.status = .dead
        members[id] = member
        Self.updateStatusSets(&self, for: member, previousStatus: previousStatus)

        // Record timestamp for GC.
        deadTimestamps[id] = nowMillis

        return .statusChanged(member, from: previousStatus)
    }

    /// Marks a member as alive with a new incarnation. Used when a member refutes
    /// a suspicion.
    @discardableResult
    public mutating func markAlive(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        guard var member = members[id] else { return nil }

        // Must have higher incarnation to refute.
        guard incarnation > member.incarnation else { return nil }

        let previousStatus = member.status
        member.status = .alive
        member.incarnation = incarnation
        members[id] = member
        Self.updateStatusSets(&self, for: member, previousStatus: previousStatus)

        // Clear dead timestamp if recovering from dead status.
        if previousStatus == .dead {
            deadTimestamps.removeValue(forKey: id)
        }

        if previousStatus != .alive {
            return .statusChanged(member, from: previousStatus)
        }
        return nil
    }

    // MARK: - Private Helpers

    /// Applies an update for an already-known member, enforcing precedence rules.
    private mutating func applyExistingUpdate(
        member: Member,
        existing: Member,
        nowMillis: UInt64
    ) -> MembershipChange? {
        guard Self.shouldApplyUpdate(existing: existing, update: member) else {
            return nil
        }

        let previousStatus = existing.status
        members[member.id] = member
        Self.updateStatusSets(&self, for: member, previousStatus: previousStatus)

        // Track dead timestamp for GC (learned via gossip).
        if member.status == .dead && previousStatus != .dead {
            deadTimestamps[member.id] = nowMillis
        }
        // Clear dead timestamp if member recovered.
        if member.status != .dead && previousStatus == .dead {
            deadTimestamps.removeValue(forKey: member.id)
        }

        if previousStatus != member.status {
            return .statusChanged(member, from: previousStatus)
        }
        return nil
    }

    /// Inserts a brand-new member.
    private mutating func insertNewMember(
        _ member: Member,
        nowMillis: UInt64
    ) -> MembershipChange? {
        members[member.id] = member
        Self.updateStatusSets(&self, for: member)
        // Track dead timestamp for new dead members (learned via gossip).
        if member.status == .dead {
            deadTimestamps[member.id] = nowMillis
        }
        return .joined(member)
    }

    private static func shouldApplyUpdate(existing: Member, update: Member) -> Bool {
        // Higher incarnation always wins.
        if update.incarnation > existing.incarnation {
            return true
        }
        if update.incarnation < existing.incarnation {
            return false
        }

        // Same incarnation: higher severity wins.
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
        _ state: inout MembershipState,
        for member: Member,
        previousStatus: MemberStatus? = nil
    ) {
        let id = member.id

        // Remove from previous status set if known.
        if let previous = previousStatus {
            switch previous {
            case .alive: state.aliveMembers.remove(id)
            case .suspect: state.suspectMembers.remove(id)
            case .dead: state.deadMembers.remove(id)
            }
        } else {
            // Remove from all sets (for new members or unknown previous).
            state.aliveMembers.remove(id)
            state.suspectMembers.remove(id)
            state.deadMembers.remove(id)
        }

        // Add to new status set.
        switch member.status {
        case .alive: state.aliveMembers.insert(id)
        case .suspect: state.suspectMembers.insert(id)
        case .dead: state.deadMembers.insert(id)
        }
    }
}
