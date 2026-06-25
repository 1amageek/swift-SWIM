/// SWIM Member List
///
/// Thread-safe collection of cluster members with efficient random selection for
/// failure detection.
///
/// ## Caller-locked + clock-seam adapter
///
/// This is the caller-locked adapter over the Embedded-clean value-type state
/// machine `SWIMWire.MembershipState`. It owns the two things the core
/// deliberately does NOT:
///
/// 1. **Synchronization** — a ``FacadeLock`` wraps the value type (host:
///    `Synchronization.Mutex`; Embedded: an `Atomic`-spinlock box); every public
///    method delegates to the core's `mutating` methods under the lock, so
///    `MemberList` keeps its existing `Sendable`, thread-safe behavior.
/// 2. **The clock** — the core takes a monotonic `nowMillis` parameter instead of
///    reading a clock. This adapter reads the injected ``SWIMClock`` (relative to
///    a fixed epoch captured at init) and injects the milliseconds value, instead
///    of `ContinuousClock` which is unavailable under Embedded.
/// 3. **Randomness** — the core exposes deterministic candidate enumeration; the
///    random probe selectors here pick from those candidates with the system RNG.
///
/// Observable behavior is identical to the previous Mutex/ContinuousClock-backed
/// implementation.

import SWIMWire

/// Thread-safe member list for SWIM protocol.
///
/// Provides efficient operations for:
/// - Adding/updating/removing members
/// - Random member selection for probing
/// - Status-based queries
///
/// Generic over the injected ``SWIMClock`` so the type is Embedded-clean: an
/// `any SWIMClock` existential is rejected under Embedded Swift, whereas a
/// concrete `Clock` type parameter monomorphizes cleanly.
public final class MemberList<Clock: SWIMClock>: Sendable {
    /// The monotonic clock seam. `nowMillis()` is measured relative to the epoch
    /// captured at init.
    private let clock: Clock

    private let state: FacadeLock<MembershipState>

    /// Monotonic epoch (nanoseconds) captured at init.
    private let epochNanos: UInt64

    /// Current monotonic time in milliseconds since the epoch.
    private func nowMillis() -> UInt64 {
        // Saturating, never negative since the clock is monotonic and the epoch
        // precedes now.
        let elapsed = clock.monotonicNanos() &- epochNanos
        return elapsed / 1_000_000
    }

    /// Converts a retention `Duration` to milliseconds (saturating, non-negative).
    private static func millis(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let secondsMillis = UInt64(max(0, components.seconds)) &* 1000
        let attoMillis = UInt64(max(0, components.attoseconds) / 1_000_000_000_000_000)
        return secondsMillis &+ attoMillis
    }

    /// Creates an empty member list driven by the given clock seam.
    public init(clock: Clock) {
        self.clock = clock
        self.epochNanos = clock.monotonicNanos()
        self.state = FacadeLock(MembershipState())
    }

    /// Creates a member list with initial members driven by the given clock seam.
    public init(members: [Member], clock: Clock) {
        self.clock = clock
        self.epochNanos = clock.monotonicNanos()
        self.state = FacadeLock(MembershipState(members: members))
    }

    // MARK: - Query Operations

    /// Returns the member with the given ID, if present.
    public func member(for id: MemberID) -> Member? {
        state.withLock { $0.member(for: id) }
    }

    /// Returns all members in the list.
    public var allMembers: [Member] {
        state.withLock { $0.allMembers }
    }

    /// Returns the number of members in the list.
    public var count: Int {
        state.withLock { $0.count }
    }

    /// Returns the number of alive members.
    public var aliveCount: Int {
        state.withLock { $0.aliveCount }
    }

    /// Returns the number of suspect members.
    public var suspectCount: Int {
        state.withLock { $0.suspectCount }
    }

    /// Returns all alive members.
    public var aliveMembers: [Member] {
        state.withLock { $0.aliveMemberList }
    }

    /// Returns all suspect members.
    public var suspectMembers: [Member] {
        state.withLock { $0.suspectMemberList }
    }

    /// Returns whether the list contains a member with the given ID.
    public func contains(_ id: MemberID) -> Bool {
        state.withLock { $0.contains(id) }
    }

    // MARK: - Random Selection

    /// Returns a random alive member, excluding specified IDs.
    public func randomAliveMember(excluding: Set<MemberID> = []) -> Member? {
        state.withLock { state in
            let candidates = state.aliveCandidates(excluding: excluding)
            guard let id = candidates.randomElement() else { return nil }
            return state.member(for: id)
        }
    }

    /// Returns multiple random alive members, excluding specified IDs.
    public func randomAliveMembers(count: Int, excluding: Set<MemberID> = []) -> [Member] {
        state.withLock { state in
            var candidates = state.aliveCandidates(excluding: excluding)
            guard !candidates.isEmpty else { return [] }

            let selectCount = min(count, candidates.count)
            var selected: [Member] = []
            selected.reserveCapacity(selectCount)

            for _ in 0..<selectCount {
                let index = Int.random(in: 0..<candidates.count)
                let id = candidates.remove(at: index)
                if let member = state.member(for: id) {
                    selected.append(member)
                }
            }

            return selected
        }
    }

    /// Returns a random member from alive or suspect, excluding specified IDs.
    public func randomProbableTarget(excluding: Set<MemberID> = []) -> Member? {
        state.withLock { state in
            let candidates = state.probableCandidates(excluding: excluding)
            guard let id = candidates.randomElement() else { return nil }
            return state.member(for: id)
        }
    }

    /// Returns the next probe target using round-robin selection.
    public func nextRoundRobinTarget(excluding: Set<MemberID> = []) -> Member? {
        state.withLock { state in
            state.nextRoundRobinTarget(excluding: excluding)
        }
    }

    /// Removes dead members older than the specified retention period.
    @discardableResult
    public func removeDeadMembers(olderThan retention: Duration) -> [MemberID] {
        let retentionMillis = Self.millis(retention)
        let now = nowMillis()
        return state.withLock { state in
            state.removeDeadMembers(olderThanMillis: retentionMillis, nowMillis: now)
        }
    }

    // MARK: - Mutation Operations

    /// Updates a member in the list.
    @discardableResult
    public func update(_ member: Member) -> MembershipChange? {
        let now = nowMillis()
        return state.withLock { state in
            state.update(member, nowMillis: now)
        }
    }

    /// Applies a gossiped member update through the trust boundary.
    ///
    /// Rejections are surfaced as ``MemberListRejection`` rather than silently
    /// dropped, so the caller can decide how to react.
    @discardableResult
    public func applyGossip(
        _ member: Member,
        maxIncarnationDelta: UInt64?,
        maxMemberCount: Int?
    ) throws(MemberListRejection) -> MembershipChange? {
        let now = nowMillis()
        return try state.withLock { (state) throws(MemberListRejection) in
            try state.applyGossip(
                member,
                maxIncarnationDelta: maxIncarnationDelta,
                maxMemberCount: maxMemberCount,
                nowMillis: now
            )
        }
    }

    /// Removes a member from the list.
    @discardableResult
    public func remove(_ id: MemberID) -> Member? {
        state.withLock { state in
            state.remove(id)
        }
    }

    /// Marks a member as suspect.
    @discardableResult
    public func markSuspect(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        state.withLock { state in
            state.markSuspect(id, incarnation: incarnation)
        }
    }

    /// Marks a suspected member as dead because its suspicion timeout expired.
    @discardableResult
    public func markDead(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        let now = nowMillis()
        return state.withLock { state in
            state.markDead(id, incarnation: incarnation, nowMillis: now)
        }
    }

    /// Marks a member as alive with a new incarnation.
    @discardableResult
    public func markAlive(_ id: MemberID, incarnation: Incarnation) -> MembershipChange? {
        state.withLock { state in
            state.markAlive(id, incarnation: incarnation)
        }
    }
}

#if !hasFeature(Embedded)
extension MemberList where Clock == SystemSWIMClock {
    /// Creates an empty member list backed by the host system clock.
    ///
    /// HOST-ONLY: ``SystemSWIMClock`` does not exist under Embedded; an Embedded
    /// caller must use ``init(clock:)`` and inject its own clock.
    public convenience init() {
        self.init(clock: SystemSWIMClock())
    }

    /// Creates a member list with initial members backed by the host system clock.
    ///
    /// HOST-ONLY: see ``init()``.
    public convenience init(members: [Member]) {
        self.init(members: members, clock: SystemSWIMClock())
    }
}
#endif

extension MemberList: CustomStringConvertible {
    public var description: String {
        let (total, alive, suspect) = state.withLock { (state) -> (Int, Int, Int) in
            (state.count, state.aliveCount, state.suspectCount)
        }
        return "MemberList(total: \(total), alive: \(alive), suspect: \(suspect))"
    }
}
