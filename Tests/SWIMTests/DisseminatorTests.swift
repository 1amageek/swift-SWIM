/// Disseminator Tests

import Testing
@testable import SWIM

@Suite("Disseminator Tests")
struct DisseminatorTests {

    @Test("Enqueue member update")
    func enqueueMember() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 3)
        let member = Member(
            id: MemberID(id: "node1", address: "127.0.0.1:8000"),
            status: .suspect,
            incarnation: Incarnation(value: 1)
        )

        disseminator.enqueue(member: member)

        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.count == 1)
        #expect(payload.updates[0].memberID.id == "node1")
        #expect(payload.updates[0].status == .suspect)
    }

    @Test("Enqueue membership update")
    func enqueueUpdate() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 3)
        let update = MembershipUpdate(
            member: Member(
                id: MemberID(id: "node1", address: "127.0.0.1:8000"),
                status: .dead,
                incarnation: Incarnation(value: 5)
            )
        )

        disseminator.enqueue(update)

        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.count == 1)
        #expect(payload.updates[0].status == .dead)
        #expect(payload.updates[0].incarnation.value == 5)
    }

    @Test("Max payload size limits updates")
    func maxPayloadSize() {
        let disseminator = Disseminator(maxPayloadSize: 3, disseminationLimit: 10)

        // Enqueue 5 updates
        for i in 0..<5 {
            let member = Member(
                id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"),
                status: .alive,
                incarnation: Incarnation(value: UInt64(i))
            )
            disseminator.enqueue(member: member)
        }

        // Should only return maxPayloadSize updates
        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.count == 3)
    }

    @Test("Dissemination limit removes old updates")
    func disseminationLimit() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 2)
        let member = Member(
            id: MemberID(id: "node1", address: "127.0.0.1:8000")
        )

        disseminator.enqueue(member: member)

        // First payload - count = 1
        let payload1 = disseminator.getPayloadForMessage()
        #expect(payload1.updates.count == 1)

        // Second payload - count = 2
        let payload2 = disseminator.getPayloadForMessage()
        #expect(payload2.updates.count == 1)

        // Third payload - update should be removed (count exceeded limit)
        let payload3 = disseminator.getPayloadForMessage()
        #expect(payload3.updates.isEmpty)
    }

    @Test("Priority ordering - dead > suspect > alive")
    func priorityOrdering() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 10)

        // Add in reverse priority order
        let alive = Member(
            id: MemberID(id: "alive", address: "127.0.0.1:8000"),
            status: .alive,
            incarnation: Incarnation(value: 1)
        )
        let suspect = Member(
            id: MemberID(id: "suspect", address: "127.0.0.1:8001"),
            status: .suspect,
            incarnation: Incarnation(value: 1)
        )
        let dead = Member(
            id: MemberID(id: "dead", address: "127.0.0.1:8002"),
            status: .dead,
            incarnation: Incarnation(value: 1)
        )

        disseminator.enqueue(member: alive)
        disseminator.enqueue(member: suspect)
        disseminator.enqueue(member: dead)

        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.count == 3)

        // Dead should be first, then suspect, then alive
        #expect(payload.updates[0].memberID.id == "dead")
        #expect(payload.updates[1].memberID.id == "suspect")
        #expect(payload.updates[2].memberID.id == "alive")
    }

    @Test("Same member update replaces older one")
    func duplicateReplacement() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 10)
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")

        // Add member as alive
        let alive = Member(id: id, status: .alive, incarnation: Incarnation(value: 1))
        disseminator.enqueue(member: alive)

        // Add same member as suspect with higher incarnation
        let suspect = Member(id: id, status: .suspect, incarnation: Incarnation(value: 2))
        disseminator.enqueue(member: suspect)

        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.count == 1)
        #expect(payload.updates[0].status == .suspect)
        #expect(payload.updates[0].incarnation.value == 2)
    }

    @Test("Empty payload when no updates")
    func emptyPayload() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 10)
        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.isEmpty)
    }

    @Test("Clear pending updates")
    func clearUpdates() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 10)
        let member = Member(
            id: MemberID(id: "node1", address: "127.0.0.1:8000")
        )

        disseminator.enqueue(member: member)
        #expect(!disseminator.isEmpty)

        disseminator.clear()
        #expect(disseminator.isEmpty)

        let payload = disseminator.getPayloadForMessage()
        #expect(payload.updates.isEmpty)
    }
}

@Suite("BroadcastQueue Tests")
struct BroadcastQueueTests {

    @Test("Push and pop single item")
    func pushPopSingle() {
        var queue = BroadcastQueue()
        let update = MembershipUpdate(
            member: Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        )

        queue.push(update)
        #expect(!queue.isEmpty)
        #expect(queue.count == 1)

        let popped = queue.pop()
        #expect(popped?.memberID.id == "node1")
        #expect(queue.isEmpty)
    }

    @Test("Priority ordering")
    func priorityOrdering() {
        var queue = BroadcastQueue()

        let alive = MembershipUpdate(
            member: Member(
                id: MemberID(id: "alive", address: "127.0.0.1:8000"),
                status: .alive
            )
        )
        let dead = MembershipUpdate(
            member: Member(
                id: MemberID(id: "dead", address: "127.0.0.1:8001"),
                status: .dead
            )
        )

        queue.push(alive)
        queue.push(dead)

        // Dead should come out first (higher priority)
        let first = queue.pop()
        #expect(first?.memberID.id == "dead")

        let second = queue.pop()
        #expect(second?.memberID.id == "alive")
    }

    @Test("Pop from empty queue returns nil")
    func popEmpty() {
        var queue = BroadcastQueue()
        #expect(queue.pop() == nil)
    }

    @Test("Peek returns items without removing")
    func peekItems() {
        var queue = BroadcastQueue()

        for i in 0..<5 {
            let member = Member(
                id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"),
                status: i % 2 == 0 ? .alive : .suspect
            )
            queue.push(MembershipUpdate(member: member))
        }

        let peeked = queue.peek(count: 3)
        #expect(peeked.count == 3)
        #expect(queue.count == 5)  // Nothing removed

        // Suspect should come before alive
        #expect(peeked[0].status == .suspect)
        #expect(peeked[1].status == .suspect)
    }
}
