/// MemberList Safety Tests
///
/// Tests for the core SWIM safety property at the member-list layer:
/// "a node that refutes a suspicion must not be declared dead." These encode the
/// strict markDead precondition (still-suspect + exact captured incarnation) and
/// the gossip trust-boundary (incarnation jump bound + member-table cap).

import Testing
@testable import SWIM

@Suite("MemberList Safety Tests")
struct MemberListSafetyTests {

    // MARK: - markDead strictness (findings #1, #6)

    @Test("Stale dead@N does not kill a member currently alive@N")
    func staleDeadDoesNotKillAliveAtSameIncarnation() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        // Member is alive at incarnation N.
        let member = Member(id: id, status: .alive, incarnation: Incarnation(value: 5))
        let list = MemberList(members: [member])

        // A stale timer captured "suspect at N" earlier, but the member is now
        // alive at the same incarnation N. The strict precondition (must be
        // .suspect) rejects the kill.
        let change = list.markDead(id, incarnation: Incarnation(value: 5))

        #expect(change == nil, "markDead must not kill a member that is currently alive")
        #expect(list.member(for: id)?.status == .alive)
    }

    @Test("Already-refuted member (incarnation bumped) is not killed by old timer")
    func refutedMemberNotKilledByOldTimer() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let list = MemberList(members: [Member(id: id, status: .alive, incarnation: Incarnation(value: 5))])

        // Member becomes suspect at incarnation 5 (captured by the timer).
        let suspected = list.markSuspect(id, incarnation: Incarnation(value: 5))
        #expect(suspected != nil)

        // Member refutes: status -> alive, incarnation bumped to 6.
        let refuted = list.markAlive(id, incarnation: Incarnation(value: 6))
        #expect(refuted != nil)
        #expect(list.member(for: id)?.status == .alive)
        #expect(list.member(for: id)?.incarnation.value == 6)

        // The old timer fires with the captured incarnation 5. Strict equality
        // (and the status check) rejects the kill.
        let killed = list.markDead(id, incarnation: Incarnation(value: 5))
        #expect(killed == nil, "An already-refuted member must not be killed by the old timer")
        #expect(list.member(for: id)?.status == .alive)
    }

    @Test("markDead kills only a still-suspect member at the exact captured incarnation")
    func killsStillSuspectAtCapturedIncarnation() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let list = MemberList(members: [Member(id: id, status: .alive, incarnation: Incarnation(value: 2))])

        list.markSuspect(id, incarnation: Incarnation(value: 2))

        // Same incarnation, still suspect -> kill applies.
        let killed = list.markDead(id, incarnation: Incarnation(value: 2))
        if case .statusChanged(let updated, let from)? = killed {
            #expect(updated.status == .dead)
            #expect(from == .suspect)
            // Incarnation is preserved (no longer overwritten by markDead).
            #expect(updated.incarnation.value == 2)
        } else {
            Issue.record("Expected the still-suspect member to be killed")
        }
    }

    @Test("markDead with a different captured incarnation does not kill a suspect")
    func differentCapturedIncarnationDoesNotKill() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let list = MemberList(members: [Member(id: id, status: .alive, incarnation: Incarnation(value: 3))])

        // Suspect at 3, then suspicion re-armed at a higher incarnation 4
        // (e.g. re-suspected after a refutation cycle).
        list.markSuspect(id, incarnation: Incarnation(value: 3))
        list.markAlive(id, incarnation: Incarnation(value: 4))
        list.markSuspect(id, incarnation: Incarnation(value: 4))

        // A stale timer captured incarnation 3 fires; the member is suspect but
        // at incarnation 4, so strict equality rejects the kill.
        let killed = list.markDead(id, incarnation: Incarnation(value: 3))
        #expect(killed == nil)
        #expect(list.member(for: id)?.status == .suspect)
    }

    // MARK: - Gossip trust boundary: incarnation jump bound (finding #5a)

    @Test("Forged incarnation jump beyond the sanity bound is rejected for an existing member")
    func forgedIncarnationJumpRejectedExisting() throws {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let list = MemberList(members: [Member(id: id, status: .alive, incarnation: Incarnation(value: 1))])

        // A peer forges an implausibly high incarnation to win every conflict.
        let forged = Member(id: id, status: .dead, incarnation: Incarnation(value: 1_000_000))

        #expect(throws: MemberListRejection.self) {
            try list.applyGossip(forged, maxIncarnationDelta: 16, maxMemberCount: 10_000)
        }
        // The forged update was not applied.
        #expect(list.member(for: id)?.status == .alive)
        #expect(list.member(for: id)?.incarnation.value == 1)
    }

    @Test("Forged incarnation jump beyond the sanity bound is rejected for a new member")
    func forgedIncarnationJumpRejectedNew() throws {
        let list = MemberList()
        let id = MemberID(id: "ghost", address: "127.0.0.1:9000")
        // A brand-new member is "known" at .initial; a huge incarnation exceeds
        // the absolute bound.
        let forged = Member(id: id, status: .alive, incarnation: Incarnation(value: 5000))

        #expect(throws: MemberListRejection.self) {
            try list.applyGossip(forged, maxIncarnationDelta: 16, maxMemberCount: 10_000)
        }
        #expect(list.member(for: id) == nil, "Rejected gossip must not create the member")
    }

    @Test("Plausible incarnation advance within the bound is accepted")
    func plausibleAdvanceAccepted() throws {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let list = MemberList(members: [Member(id: id, status: .alive, incarnation: Incarnation(value: 1))])

        // Within the bound: should apply normally.
        let change = try list.applyGossip(
            Member(id: id, status: .suspect, incarnation: Incarnation(value: 5)),
            maxIncarnationDelta: 16,
            maxMemberCount: 10_000
        )
        #expect(change != nil)
        #expect(list.member(for: id)?.status == .suspect)
        #expect(list.member(for: id)?.incarnation.value == 5)
    }

    @Test("Non-advancing gossip is never rejected by the incarnation bound")
    func nonAdvancingGossipNotRejected() throws {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let list = MemberList(members: [Member(id: id, status: .alive, incarnation: Incarnation(value: 100))])

        // A lower incarnation can never inflate the clock; it is simply
        // superseded (returns nil), never thrown.
        let change = try list.applyGossip(
            Member(id: id, status: .dead, incarnation: Incarnation(value: 1)),
            maxIncarnationDelta: 16,
            maxMemberCount: 10_000
        )
        #expect(change == nil)
        #expect(list.member(for: id)?.status == .alive)
    }

    // MARK: - Gossip trust boundary: member-table cap (finding #7)

    @Test("Gossiping a new member beyond the table cap is rejected")
    func memberTableCapRejectsNewMembers() throws {
        let list = MemberList()
        let cap = 3

        // Fill up to the cap.
        for i in 0..<cap {
            let member = Member(id: MemberID(id: "node\(i)", address: "127.0.0.1:800\(i)"))
            let change = try list.applyGossip(member, maxIncarnationDelta: 16, maxMemberCount: cap)
            #expect(change != nil)
        }
        #expect(list.count == cap)

        // One more new member must be rejected.
        let overflow = Member(id: MemberID(id: "overflow", address: "127.0.0.1:9999"))
        #expect(throws: MemberListRejection.self) {
            try list.applyGossip(overflow, maxIncarnationDelta: 16, maxMemberCount: cap)
        }
        #expect(list.count == cap, "Table must not grow past the cap")
        #expect(list.member(for: overflow.id) == nil)
    }

    @Test("Updates to existing members are allowed even when the table is at capacity")
    func updatesAllowedAtCapacity() throws {
        let list = MemberList()
        let cap = 2
        let idA = MemberID(id: "a", address: "127.0.0.1:8001")
        let idB = MemberID(id: "b", address: "127.0.0.1:8002")
        try list.applyGossip(Member(id: idA), maxIncarnationDelta: 16, maxMemberCount: cap)
        try list.applyGossip(Member(id: idB), maxIncarnationDelta: 16, maxMemberCount: cap)
        #expect(list.count == cap)

        // Updating an already-known member must not be blocked by the cap.
        let change = try list.applyGossip(
            Member(id: idA, status: .suspect, incarnation: Incarnation(value: 1)),
            maxIncarnationDelta: 16,
            maxMemberCount: cap
        )
        #expect(change != nil)
        #expect(list.member(for: idA)?.status == .suspect)
    }

    @Test("Disabled bounds (nil) accept any plausible gossip")
    func disabledBoundsAcceptAll() throws {
        let list = MemberList()
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let change = try list.applyGossip(
            Member(id: id, status: .alive, incarnation: Incarnation(value: 999_999)),
            maxIncarnationDelta: nil,
            maxMemberCount: nil
        )
        #expect(change != nil)
        #expect(list.member(for: id)?.incarnation.value == 999_999)
    }
}
