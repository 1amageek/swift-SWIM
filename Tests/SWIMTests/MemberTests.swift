/// Member Tests

import Testing
@testable import SWIM

@Suite("Member Tests")
struct MemberTests {

    // MARK: - MemberID Tests

    @Test("MemberID equality")
    func memberIDEquality() {
        let id1 = MemberID(id: "node1", address: "127.0.0.1:8000")
        let id2 = MemberID(id: "node1", address: "127.0.0.1:8000")
        let id3 = MemberID(id: "node2", address: "127.0.0.1:8001")

        #expect(id1 == id2)
        #expect(id1 != id3)
    }

    @Test("MemberID hashing")
    func memberIDHashing() {
        let id1 = MemberID(id: "node1", address: "127.0.0.1:8000")
        let id2 = MemberID(id: "node1", address: "127.0.0.1:8000")

        var set = Set<MemberID>()
        set.insert(id1)
        set.insert(id2)

        #expect(set.count == 1)
    }

    @Test("MemberID description")
    func memberIDDescription() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        #expect(id.description.contains("node1"))
        #expect(id.description.contains("127.0.0.1:8000"))
    }

    // MARK: - Member Tests

    @Test("Member creation with defaults")
    func memberCreationDefaults() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member = Member(id: id)

        #expect(member.id == id)
        #expect(member.status == .alive)
        #expect(member.incarnation == .initial)
    }

    @Test("Member creation with custom values")
    func memberCreationCustom() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let incarnation = Incarnation(value: 5)
        let member = Member(id: id, status: .suspect, incarnation: incarnation)

        #expect(member.id == id)
        #expect(member.status == .suspect)
        #expect(member.incarnation == incarnation)
    }

    @Test("Member status mutation")
    func memberStatusMutation() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        var member = Member(id: id)

        #expect(member.status == .alive)

        member.status = .suspect
        #expect(member.status == .suspect)

        member.status = .dead
        #expect(member.status == .dead)
    }

    @Test("Member incarnation mutation")
    func memberIncarnationMutation() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        var member = Member(id: id)

        #expect(member.incarnation == .initial)

        member.incarnation = member.incarnation.incremented()
        #expect(member.incarnation.value == 1)
    }

    @Test("Member equality includes all properties")
    func memberEquality() {
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let member1 = Member(id: id, status: .alive, incarnation: .initial)
        let member2 = Member(id: id, status: .alive, incarnation: .initial)
        let member3 = Member(id: id, status: .suspect, incarnation: Incarnation(value: 5))

        // Members are equal if all properties match
        #expect(member1 == member2)
        // Members with different status/incarnation are not equal
        #expect(member1 != member3)
    }
}

@Suite("MemberStatus Tests")
struct MemberStatusTests {

    @Test("Status raw values")
    func statusRawValues() {
        #expect(MemberStatus.alive.rawValue == 0)
        #expect(MemberStatus.suspect.rawValue == 1)
        #expect(MemberStatus.dead.rawValue == 2)
    }

    @Test("Status comparison - dead is highest priority")
    func statusComparison() {
        #expect(MemberStatus.alive < MemberStatus.suspect)
        #expect(MemberStatus.suspect < MemberStatus.dead)
        #expect(MemberStatus.alive < MemberStatus.dead)
    }

    @Test("Status dissemination priority")
    func statusDisseminationPriority() {
        // Dead should have highest priority for dissemination
        #expect(MemberStatus.dead.disseminationPriority > MemberStatus.suspect.disseminationPriority)
        #expect(MemberStatus.suspect.disseminationPriority > MemberStatus.alive.disseminationPriority)
    }

    @Test("Status from raw value")
    func statusFromRawValue() {
        #expect(MemberStatus(rawValue: 0) == .alive)
        #expect(MemberStatus(rawValue: 1) == .suspect)
        #expect(MemberStatus(rawValue: 2) == .dead)
        #expect(MemberStatus(rawValue: 99) == nil)
    }
}
