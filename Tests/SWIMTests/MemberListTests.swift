/// MemberList Tests

import Testing
@testable import SWIM

@Suite("MemberList Tests")
struct MemberListTests {

    // MARK: - Basic Operations

    @Test("Empty member list")
    func emptyList() {
        let list = MemberList()

        #expect(list.count == 0)
        #expect(list.aliveCount == 0)
        #expect(list.allMembers.isEmpty)
    }

    @Test("Initialize with members")
    func initWithMembers() {
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let list = MemberList(members: [member1, member2])

        #expect(list.count == 2)
        #expect(list.aliveCount == 2)
    }

    @Test("Add new member")
    func addNewMember() {
        let list = MemberList()
        let member = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let change = list.update(member)

        #expect(list.count == 1)
        if case .joined(let m) = change {
            #expect(m.id == member.id)
        } else {
            Issue.record("Expected joined change")
        }
    }

    @Test("Update existing member - no change")
    func updateNoChange() {
        let member = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let list = MemberList(members: [member])

        // Same member, no change
        let change = list.update(member)
        #expect(change == nil)
    }

    @Test("Get member by ID")
    func getMemberByID() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id)
        let list = MemberList(members: [member])

        let retrieved = list.member(for: id)
        #expect(retrieved?.id == id)
        #expect(retrieved?.status == .alive)
    }

    @Test("Get nonexistent member")
    func getNonexistentMember() {
        let list = MemberList()
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")

        let retrieved = list.member(for: id)
        #expect(retrieved == nil)
    }

    // MARK: - Status Transitions

    @Test("Mark member suspect")
    func markSuspect() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id)
        let list = MemberList(members: [member])

        let change = list.markSuspect(id, incarnation: .initial)

        if case .statusChanged(let updated, let from) = change {
            #expect(updated.status == .suspect)
            #expect(from == .alive)
        } else {
            Issue.record("Expected status change")
        }

        #expect(list.aliveCount == 0)
    }

    @Test("Mark member dead")
    func markDead() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id, status: .suspect)
        let list = MemberList(members: [member])

        let change = list.markDead(id, incarnation: .initial)

        if case .statusChanged(let updated, let from) = change {
            #expect(updated.status == .dead)
            #expect(from == .suspect)
        } else {
            Issue.record("Expected status change")
        }
    }

    @Test("Mark member alive from suspect")
    func markAliveFromSuspect() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id, status: .suspect)
        let list = MemberList(members: [member])

        let newIncarnation = Incarnation(value: 1)
        let change = list.markAlive(id, incarnation: newIncarnation)

        if case .statusChanged(let updated, let from) = change {
            #expect(updated.status == .alive)
            #expect(updated.incarnation == newIncarnation)
            #expect(from == .suspect)
        } else {
            Issue.record("Expected status change")
        }

        #expect(list.aliveCount == 1)
    }

    // MARK: - Incarnation Rules

    @Test("Higher incarnation wins - same status")
    func higherIncarnationWins() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id, incarnation: Incarnation(value: 1))
        let list = MemberList(members: [member])

        // Update with higher incarnation but same status
        let updated = Member(id: id, incarnation: Incarnation(value: 5))
        let change = list.update(updated)

        // Should update the incarnation
        let retrieved = list.member(for: id)
        #expect(retrieved?.incarnation.value == 5)
        // No MembershipChange returned because status didn't change
        #expect(change == nil)
    }

    @Test("Lower incarnation ignored")
    func lowerIncarnationIgnored() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id, incarnation: Incarnation(value: 5))
        let list = MemberList(members: [member])

        // Update with lower incarnation
        let updated = Member(id: id, incarnation: Incarnation(value: 1))
        let change = list.update(updated)

        // Should ignore
        let retrieved = list.member(for: id)
        #expect(retrieved?.incarnation.value == 5)
        #expect(change == nil)
    }

    @Test("Same incarnation - higher severity wins")
    func samIncarnationHigherSeverityWins() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id, status: .alive, incarnation: Incarnation(value: 1))
        let list = MemberList(members: [member])

        // Update with same incarnation but higher severity (suspect > alive)
        let updated = Member(id: id, status: .suspect, incarnation: Incarnation(value: 1))
        let change = list.update(updated)

        // Should update to suspect
        let retrieved = list.member(for: id)
        #expect(retrieved?.status == .suspect)
        #expect(change != nil)
    }

    @Test("Same incarnation - lower severity ignored")
    func sameIncarnationLowerSeverityIgnored() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id, status: .suspect, incarnation: Incarnation(value: 1))
        let list = MemberList(members: [member])

        // Update with same incarnation but lower severity (alive < suspect)
        let updated = Member(id: id, status: .alive, incarnation: Incarnation(value: 1))
        let change = list.update(updated)

        // Should ignore
        let retrieved = list.member(for: id)
        #expect(retrieved?.status == .suspect)
        #expect(change == nil)
    }

    // MARK: - Random Selection

    @Test("Random alive member")
    func randomAliveMember() {
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"), status: .dead)
        let list = MemberList(members: [member1, member2])

        // Should only return alive member
        let random = list.randomAliveMember(excluding: [])
        #expect(random?.id == member1.id)
    }

    @Test("Random alive member with exclusion")
    func randomAliveMemberWithExclusion() {
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let list = MemberList(members: [member1, member2])

        // Exclude member1
        let random = list.randomAliveMember(excluding: [member1.id])
        #expect(random?.id == member2.id)
    }

    @Test("Random alive members count")
    func randomAliveMembers() {
        let members = (0..<10).map { i in
            Member(id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"))
        }
        let list = MemberList(members: members)

        let random = list.randomAliveMembers(count: 3, excluding: [])
        #expect(random.count == 3)

        // All should be unique
        let ids = Set(random.map(\.id))
        #expect(ids.count == 3)
    }

    @Test("Random alive members - fewer available than requested")
    func randomAliveMembersFewerAvailable() {
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let list = MemberList(members: [member1, member2])

        // Request more than available
        let random = list.randomAliveMembers(count: 10, excluding: [])
        #expect(random.count == 2)
    }

    @Test("Random probable target")
    func randomProbableTarget() {
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"), status: .suspect)
        let member3 = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"), status: .dead)
        let list = MemberList(members: [member1, member2, member3])

        // Should return alive or suspect, but not dead
        var foundAlive = false
        var foundSuspect = false

        for _ in 0..<100 {
            if let target = list.randomProbableTarget(excluding: []) {
                #expect(target.status != .dead)
                if target.status == .alive { foundAlive = true }
                if target.status == .suspect { foundSuspect = true }
            }
        }

        // Over 100 tries, should find both alive and suspect
        #expect(foundAlive)
        #expect(foundSuspect)
    }

    // MARK: - Removal

    @Test("Remove member")
    func removeMember() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id)
        let list = MemberList(members: [member])

        let removed = list.remove(id)

        #expect(list.count == 0)
        #expect(removed?.id == id)
    }

    @Test("Remove nonexistent member")
    func removeNonexistentMember() {
        let list = MemberList()
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")

        let removed = list.remove(id)
        #expect(removed == nil)
    }
}
