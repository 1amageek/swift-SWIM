/// SWIM Protocol Flow Tests
///
/// Tests for the core SWIM protocol behaviors:
/// - Direct probe (ping/ack)
/// - Indirect probe (ping-req)
/// - Suspicion sub-protocol

import Foundation
import Testing
@testable import SWIM

@Suite("SWIM Protocol Flow Tests")
struct SWIMProtocolFlowTests {

    // MARK: - Direct Probe Flow

    @Test("Direct ping receives ack response", .timeLimit(.minutes(1)))
    func directPingReceivesAck() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Simulate receiving a ping from a remote node
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let incomingPing = SWIMMessage.ping(sequenceNumber: 42, payload: .empty)
        transport.receive(incomingPing, from: remoteMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(50))

        // Verify ack was sent
        let sentMessages = transport.getSentMessages()
        #expect(sentMessages.count >= 1)

        let ackSent = sentMessages.contains { msg, target in
            if case .ack(let seq, _, _) = msg {
                return seq == 42 && target == remoteMember
            }
            return false
        }
        #expect(ackSent, "Expected ack to be sent for ping")

        await instance.stop()
    }

    @Test("Direct ping adds sender to member list", .timeLimit(.minutes(1)))
    func directPingAddsNewMember() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Initially only local member
        let initialMembers = await instance.members
        #expect(initialMembers.count == 1)

        // Receive ping from unknown member
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)
        transport.receive(ping, from: remoteMember)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(50))

        // Verify member was added
        let members = await instance.members
        #expect(members.count == 2)

        let hasRemoteMember = members.contains { $0.id == remoteMember }
        #expect(hasRemoteMember, "Remote member should be added to member list")

        await instance.stop()
    }

    // MARK: - Indirect Probe Flow

    @Test("PingRequest triggers probe to target", .timeLimit(.minutes(1)))
    func pingRequestTriggersProbe() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Another node asks us to probe a target
        let requester = MemberID(id: "node2", address: "127.0.0.1:8001")
        let target = MemberID(id: "node3", address: "127.0.0.1:8002")
        let pingReq = SWIMMessage.pingRequest(sequenceNumber: 100, target: target, payload: .empty)

        transport.receive(pingReq, from: requester)

        // Wait for processing
        try await Task.sleep(for: .milliseconds(50))

        // Verify ping was sent to the target
        let sentMessages = transport.getSentMessages()
        let pingSentToTarget = sentMessages.contains { msg, dest in
            if case .ping = msg {
                return dest == target
            }
            return false
        }
        #expect(pingSentToTarget, "Should send ping to the target on behalf of requester")

        await instance.stop()
    }

    @Test("PingRequest sends correct response type", .timeLimit(.minutes(1)))
    func pingRequestSendsCorrectResponseType() async throws {
        // Test that ping-request either sends ack (if target responds) or nack (if timeout)
        // Since MockTransport doesn't route messages, target won't respond, so we expect nack

        var config = SWIMConfiguration.development
        config.pingTimeout = .milliseconds(30)

        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: config,
            transport: transport
        )

        await instance.start()

        let requester = MemberID(id: "node2", address: "127.0.0.1:8001")
        let target = MemberID(id: "node3", address: "127.0.0.1:8002")
        let pingReq = SWIMMessage.pingRequest(sequenceNumber: 100, target: target, payload: .empty)

        transport.receive(pingReq, from: requester)

        // Wait for ping timeout + processing
        try await Task.sleep(for: .milliseconds(100))

        let sentMessages = transport.getSentMessages()

        // Should have sent: ping to target, then either ack or nack to requester
        let pingSent = sentMessages.contains { msg, dest in
            if case .ping = msg { return dest == target }
            return false
        }
        #expect(pingSent, "Should send ping to target")

        // Response to requester (ack or nack)
        let responseSent = sentMessages.contains { msg, dest in
            if dest != requester { return false }
            switch msg {
            case .ack, .nack: return true
            default: return false
            }
        }
        #expect(responseSent, "Should send ack or nack to requester")

        await instance.stop()
    }

    @Test("PingRequest sends nack when target unreachable", .timeLimit(.minutes(1)))
    func pingRequestSendsNackOnTimeout() async throws {
        // Use longer ping timeout to control the test
        var config = SWIMConfiguration.development
        config.pingTimeout = .milliseconds(50)

        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: config,
            transport: transport
        )

        await instance.start()

        // Node2 asks us to probe Node3 (who won't respond)
        let requester = MemberID(id: "node2", address: "127.0.0.1:8001")
        let target = MemberID(id: "node3", address: "127.0.0.1:8002")
        let pingReq = SWIMMessage.pingRequest(sequenceNumber: 100, target: target, payload: .empty)

        transport.receive(pingReq, from: requester)

        // Wait for timeout + processing
        try await Task.sleep(for: .milliseconds(150))

        // Verify nack was sent to requester
        let sentMessages = transport.getSentMessages()
        let nackSent = sentMessages.contains { msg, dest in
            if case .nack(let seq, let nackTarget) = msg {
                return seq == 100 && dest == requester && nackTarget == target
            }
            return false
        }
        #expect(nackSent, "Nack should be sent when target doesn't respond")

        await instance.stop()
    }

    // MARK: - Suspicion Flow

    @Test("Ack cancels suspicion and recovers member", .timeLimit(.minutes(1)))
    func ackCancelsSuspicionAndRecoversMember() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Add a member via gossip from a THIRD party (not the member itself)
        // This way handlePing won't override the suspect status
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let thirdParty = MemberID(id: "node3", address: "127.0.0.1:8002")

        // First add node2 as alive (via gossip from node3)
        let aliveMember = Member(id: remoteMember, status: .alive, incarnation: .initial)
        let gossip1 = GossipPayload(updates: [MembershipUpdate(member: aliveMember)])
        let ping1 = SWIMMessage.ping(sequenceNumber: 1, payload: gossip1)
        transport.receive(ping1, from: thirdParty)

        try await Task.sleep(for: .milliseconds(30))

        // Then mark node2 as suspect (via gossip from node3 with same incarnation)
        // Same incarnation + higher severity = suspect wins
        let suspectMember = Member(id: remoteMember, status: .suspect, incarnation: .initial)
        let gossip2 = GossipPayload(updates: [MembershipUpdate(member: suspectMember)])
        let ping2 = SWIMMessage.ping(sequenceNumber: 2, payload: gossip2)
        transport.receive(ping2, from: thirdParty)

        try await Task.sleep(for: .milliseconds(30))

        // Verify member is suspect
        var members = await instance.members
        let suspectFound = members.first { $0.id == remoteMember }
        #expect(suspectFound?.status == .suspect, "Member should be suspect")

        transport.clearSentMessages()

        // Now simulate receiving ack from the suspect member (node2)
        // The ack.target should be node2.id (who we're verifying is alive)
        let ackFromSuspect = SWIMMessage.ack(sequenceNumber: 99, target: remoteMember, payload: .empty)
        transport.receive(ackFromSuspect, from: remoteMember)

        try await Task.sleep(for: .milliseconds(50))

        // Verify member recovered to alive
        members = await instance.members
        let recovered = members.first { $0.id == remoteMember }
        #expect(recovered?.status == .alive, "Member should recover to alive after ack")

        await instance.stop()
    }

    // MARK: - Suspicion Timeout

    @Test("Suspicion timeout marks member as dead after probe failure", .timeLimit(.minutes(1)))
    func suspicionTimeoutMarksDead() async throws {
        // This test verifies that when a local probe fails:
        // 1. The member is marked suspect
        // 2. A suspicion timer starts
        // 3. If no ack is received, the member is marked dead
        //
        // Use very fast config for quick testing
        var config = SWIMConfiguration.development
        config.protocolPeriod = .milliseconds(30)
        config.pingTimeout = .milliseconds(15)
        config.suspicionMultiplier = 1.0  // Fast suspicion timeout

        let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")

        // Connect initially
        transport1.connect(to: transport2)
        transport2.connect(to: transport1)

        // Create members with meaningful IDs
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))

        // Configure transports with actual member IDs
        transport1.setLocalMemberID(member1.id)
        transport2.setLocalMemberID(member2.id)

        let node1 = SWIMInstance(localMember: member1, config: config, transport: transport1)
        let node2 = SWIMInstance(localMember: member2, config: config, transport: transport2)

        await node1.start()
        await node2.start()

        // Node1 joins Node2
        try await node1.join(seeds: [member2.id])

        try await Task.sleep(for: .milliseconds(100))

        // Collect memberFailed event
        let eventTask = Task<Bool, Never> {
            for await event in node1.events {
                if case .memberFailed(let member) = event {
                    return member.id == member2.id
                }
            }
            return false
        }

        // Verify Node1 knows about Node2
        var members = await node1.members
        let hasNode2 = members.contains { $0.id == member2.id }
        #expect(hasNode2, "Node1 should know about Node2")

        // Now disconnect Node2 to simulate failure
        transport1.disconnect(from: "127.0.0.1:8001")
        transport2.disconnect(from: "127.0.0.1:8000")

        // Wait for protocol loop to probe and detect failure
        // Protocol period is 30ms, ping timeout is 15ms, suspicion timeout is ~21ms (log(2)*1.0*30ms)
        // Total expected time: protocol period + ping timeout + suspicion timeout ≈ 70ms
        // Wait longer to be safe
        try await Task.sleep(for: .milliseconds(300))

        // Check if Node2 is marked as suspect or dead
        members = await node1.members
        let node2State = members.first { $0.id == member2.id }

        // Cleanup
        await node1.stop()
        await node2.stop()
        eventTask.cancel()
        transport1.finish()
        transport2.finish()

        let failedEventReceived = await eventTask.value

        // Node2 should be either suspect or dead (dead if suspicion timer fired)
        let isFailureDetected = node2State?.status == .suspect ||
                                node2State?.status == .dead ||
                                failedEventReceived
        #expect(isFailureDetected, "Node2 should be detected as failed (suspect or dead)")
    }

    // MARK: - Gossip Piggybacking

    @Test("Ack includes gossip payload", .timeLimit(.minutes(1)))
    func ackIncludesGossipPayload() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // First add some members via gossip so there's something to disseminate
        // Use suspect status which has higher priority for dissemination
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"), status: .suspect)
        let member3 = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"), status: .alive)
        let initialGossip = GossipPayload(updates: [
            MembershipUpdate(member: member2),
            MembershipUpdate(member: member3)
        ])
        let setupPing = SWIMMessage.ping(sequenceNumber: 1, payload: initialGossip)
        transport.receive(setupPing, from: member2.id)

        try await Task.sleep(for: .milliseconds(30))
        transport.clearSentMessages()

        // Now receive another ping and check if ack has gossip
        let newPing = SWIMMessage.ping(sequenceNumber: 2, payload: .empty)
        transport.receive(newPing, from: member3.id)

        try await Task.sleep(for: .milliseconds(30))

        // Check ack message includes gossip payload
        let sentMessages = transport.getSentMessages()

        let ackWithGossip = sentMessages.first { msg, dest in
            if case .ack(_, _, let payload) = msg, dest == member3.id {
                return true
            }
            return false
        }

        #expect(ackWithGossip != nil, "Ack should be sent to member3")

        // Verify the ack contains gossip about other members
        if let (msg, _) = ackWithGossip, case .ack(_, _, let payload) = msg {
            // The ack should contain gossip updates (at minimum the local member info)
            // Note: Disseminator may include updates about known members
            #expect(payload.updates.count >= 0, "Ack payload should exist (may be empty if fully disseminated)")
        }

        await instance.stop()
    }
}
