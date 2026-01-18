/// SWIM Event Tests
///
/// Tests for SWIM event emission to verify that the protocol
/// correctly notifies observers about membership changes.

import Foundation
import Testing
@testable import SWIM

@Suite("SWIM Event Tests")
struct SWIMEventTests {

    @Test("Emits memberJoined when new member discovered via ping", .timeLimit(.minutes(1)))
    func emitsMemberJoinedOnNewMemberViaPing() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .memberJoined = event { break }
            }
            return events
        }

        // New member sends a ping
        let newMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)
        transport.receive(ping, from: newMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        let events = await eventTask.value
        let joinedEvent = events.first { event in
            if case .memberJoined(let member) = event {
                return member.id == newMember
            }
            return false
        }
        #expect(joinedEvent != nil, "Should emit memberJoined event when new member sends ping")
    }

    @Test("Emits memberJoined when new member discovered via gossip", .timeLimit(.minutes(1)))
    func emitsMemberJoinedOnNewMemberViaGossip() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .memberJoined(let m) = event, m.id.id == "node3" { break }
            }
            return events
        }

        // Existing member sends gossip about a new member
        let existingMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let newMember = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: newMember)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: existingMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        let events = await eventTask.value
        let joinedEvent = events.first { event in
            if case .memberJoined(let member) = event {
                return member.id.id == "node3"
            }
            return false
        }
        #expect(joinedEvent != nil, "Should emit memberJoined event when new member discovered via gossip")
    }

    @Test("Emits memberSuspected when member status changes to suspect", .timeLimit(.minutes(1)))
    func emitsMemberSuspectedOnStatusChange() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .memberSuspected = event { break }
            }
            return events
        }

        // First add member as alive
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let aliveMember = Member(id: remoteMember, status: .alive)
        let gossip1 = GossipPayload(updates: [MembershipUpdate(member: aliveMember)])
        let ping1 = SWIMMessage.ping(sequenceNumber: 1, payload: gossip1)
        transport.receive(ping1, from: remoteMember)

        try await Task.sleep(for: .milliseconds(30))

        // Now gossip says member is suspect with same incarnation (higher severity)
        let suspectMember = Member(id: remoteMember, status: .suspect, incarnation: .initial)
        let gossip2 = GossipPayload(updates: [MembershipUpdate(member: suspectMember)])
        let ping2 = SWIMMessage.ping(sequenceNumber: 2, payload: gossip2)
        transport.receive(ping2, from: remoteMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        let events = await eventTask.value
        let suspectedEvent = events.first { event in
            if case .memberSuspected(let member) = event {
                return member.id == remoteMember
            }
            return false
        }
        #expect(suspectedEvent != nil, "Should emit memberSuspected event")
    }

    @Test("Emits memberFailed when member status changes to dead", .timeLimit(.minutes(1)))
    func emitsMemberFailedOnStatusChange() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .memberFailed = event { break }
            }
            return events
        }

        // Add member as suspect first
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let suspectMember = Member(id: remoteMember, status: .suspect)
        let gossip1 = GossipPayload(updates: [MembershipUpdate(member: suspectMember)])
        let ping1 = SWIMMessage.ping(sequenceNumber: 1, payload: gossip1)
        transport.receive(ping1, from: remoteMember)

        try await Task.sleep(for: .milliseconds(30))

        // Now gossip says member is dead
        let deadMember = Member(id: remoteMember, status: .dead, incarnation: .initial)
        let gossip2 = GossipPayload(updates: [MembershipUpdate(member: deadMember)])
        let ping2 = SWIMMessage.ping(sequenceNumber: 2, payload: gossip2)
        transport.receive(ping2, from: remoteMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        let events = await eventTask.value
        let failedEvent = events.first { event in
            if case .memberFailed(let member) = event {
                return member.id == remoteMember
            }
            return false
        }
        #expect(failedEvent != nil, "Should emit memberFailed event")
    }

    @Test("Emits memberRecovered when suspect member becomes alive", .timeLimit(.minutes(1)))
    func emitsMemberRecoveredOnRecovery() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .memberRecovered = event { break }
            }
            return events
        }

        // Add member as suspect first
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let suspectMember = Member(id: remoteMember, status: .suspect, incarnation: Incarnation(value: 1))
        let gossip1 = GossipPayload(updates: [MembershipUpdate(member: suspectMember)])
        let ping1 = SWIMMessage.ping(sequenceNumber: 1, payload: gossip1)
        transport.receive(ping1, from: remoteMember)

        try await Task.sleep(for: .milliseconds(30))

        // Member sends ack (proves alive)
        let ack = SWIMMessage.ack(sequenceNumber: 99, target: localMember.id, payload: .empty)
        transport.receive(ack, from: remoteMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        let events = await eventTask.value
        let recoveredEvent = events.first { event in
            if case .memberRecovered(let member) = event {
                return member.id == remoteMember
            }
            return false
        }
        #expect(recoveredEvent != nil, "Should emit memberRecovered event when suspect sends ack")
    }

    @Test("Emits incarnationIncremented on self-refutation", .timeLimit(.minutes(1)))
    func emitsIncarnationIncrementedOnRefutation() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMemberID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let localMember = Member(id: localMemberID, incarnation: Incarnation(value: 5))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .incarnationIncremented = event { break }
            }
            return events
        }

        // Someone says we are suspect
        let accuser = MemberID(id: "node2", address: "127.0.0.1:8001")
        let falseReport = Member(id: localMemberID, status: .suspect, incarnation: Incarnation(value: 5))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: falseReport)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: accuser)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        let events = await eventTask.value
        let incrementedEvent = events.first { event in
            if case .incarnationIncremented(let inc) = event {
                return inc.value == 6  // 5 + 1
            }
            return false
        }
        #expect(incrementedEvent != nil, "Should emit incarnationIncremented event on self-refutation")
    }

    @Test("Emits memberLeft on graceful leave", .timeLimit(.minutes(1)))
    func emitsMemberLeftOnLeave() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events
        let eventTask = Task<[SWIMEvent], Never> {
            var events: [SWIMEvent] = []
            for await event in instance.events {
                events.append(event)
                if case .memberLeft = event { break }
            }
            return events
        }

        // Graceful leave
        await instance.leave()

        let events = await eventTask.value
        let leftEvent = events.first { event in
            if case .memberLeft(let id) = event {
                return id == localMember.id
            }
            return false
        }
        #expect(leftEvent != nil, "Should emit memberLeft event on graceful leave")
    }
}
