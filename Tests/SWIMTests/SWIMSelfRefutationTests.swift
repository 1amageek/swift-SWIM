/// SWIM Self-Refutation Tests
///
/// Tests for the SWIM self-refutation mechanism where a node
/// increments its incarnation number when falsely accused of being
/// suspect or dead.

import Foundation
import Testing
@testable import SWIM

@Suite("SWIM Self-Refutation Tests")
struct SWIMSelfRefutationTests {

    @Test("Refutes suspect status by incrementing incarnation", .timeLimit(.minutes(1)))
    func refutesSuspectWithHigherIncarnation() async throws {
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

        // Someone claims we are suspect with same incarnation
        let accuser = MemberID(id: "node2", address: "127.0.0.1:8001")
        let falseReport = Member(id: localMemberID, status: .suspect, incarnation: Incarnation(value: 5))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: falseReport)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: accuser)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        // Check incarnation was incremented
        let events = await eventTask.value
        let incarnationIncremented = events.contains { event in
            if case .incarnationIncremented(let inc) = event {
                return inc.value > 5
            }
            return false
        }
        #expect(incarnationIncremented, "Should increment incarnation when falsely accused of suspect")
    }

    @Test("Refutes dead status by incrementing incarnation", .timeLimit(.minutes(1)))
    func refutesDeadWithHigherIncarnation() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMemberID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let localMember = Member(id: localMemberID, incarnation: Incarnation(value: 3))

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

        // Someone claims we are dead
        let accuser = MemberID(id: "node2", address: "127.0.0.1:8001")
        let falseReport = Member(id: localMemberID, status: .dead, incarnation: Incarnation(value: 3))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: falseReport)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: accuser)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()

        // Check incarnation was incremented
        let events = await eventTask.value
        let incarnationIncremented = events.contains { event in
            if case .incarnationIncremented(let inc) = event {
                return inc.value > 3
            }
            return false
        }
        #expect(incarnationIncremented, "Should increment incarnation when falsely accused of dead")
    }

    @Test("Updates local member incarnation after refutation", .timeLimit(.minutes(1)))
    func updatesLocalMemberAfterRefutation() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMemberID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let localMember = Member(id: localMemberID, incarnation: Incarnation(value: 1))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Verify initial incarnation
        let initialLocal = await instance.local
        #expect(initialLocal.incarnation.value == 1, "Initial incarnation should be 1")

        // Someone claims we are suspect
        let accuser = MemberID(id: "node2", address: "127.0.0.1:8001")
        let falseReport = Member(id: localMemberID, status: .suspect, incarnation: Incarnation(value: 1))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: falseReport)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: accuser)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(50))

        // Verify local member's incarnation was updated
        let updatedLocal = await instance.local
        #expect(updatedLocal.incarnation.value > 1, "Local incarnation should be incremented after refutation")
        #expect(updatedLocal.status == .alive, "Local status should remain alive")

        await instance.stop()
    }

    @Test("Ignores old incarnation suspect accusation", .timeLimit(.minutes(1)))
    func ignoresOldIncarnationSuspectAccusation() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMemberID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let localMember = Member(id: localMemberID, incarnation: Incarnation(value: 10))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events with timeout - returns Bool
        let eventTask = Task<Bool, Never> {
            for await event in instance.events {
                if case .incarnationIncremented = event {
                    return true
                }
            }
            return false
        }

        // Someone claims we are suspect with OLD incarnation
        let accuser = MemberID(id: "node2", address: "127.0.0.1:8001")
        let oldReport = Member(id: localMemberID, status: .suspect, incarnation: Incarnation(value: 5))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: oldReport)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: accuser)

        // Wait a bit
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()
        eventTask.cancel()

        // Should NOT have incremented incarnation
        // Since we stopped and cancelled, the task should not have returned true
        let receivedEvent = await eventTask.value
        #expect(!receivedEvent, "Should NOT increment incarnation for old accusation")
    }

    @Test("Does not refute alive status", .timeLimit(.minutes(1)))
    func doesNotRefuteAliveStatus() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMemberID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let localMember = Member(id: localMemberID, incarnation: Incarnation(value: 5))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Collect events with timeout - returns Bool
        let eventTask = Task<Bool, Never> {
            for await event in instance.events {
                if case .incarnationIncremented = event {
                    return true
                }
            }
            return false
        }

        // Someone says we are alive (no need to refute)
        let sender = MemberID(id: "node2", address: "127.0.0.1:8001")
        let aliveReport = Member(id: localMemberID, status: .alive, incarnation: Incarnation(value: 5))
        let gossipPayload = GossipPayload(updates: [MembershipUpdate(member: aliveReport)])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipPayload)

        transport.receive(ping, from: sender)

        // Wait a bit
        try await Task.sleep(for: .milliseconds(100))

        await instance.stop()
        eventTask.cancel()

        // Should NOT have incremented incarnation
        let receivedEvent = await eventTask.value
        #expect(!receivedEvent, "Should NOT increment incarnation when reported as alive")
    }
}
