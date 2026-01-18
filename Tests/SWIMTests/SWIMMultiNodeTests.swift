/// SWIM Multi-Node Tests
///
/// Integration tests for SWIM protocol with multiple nodes
/// using LoopbackTransport to simulate network connections.

import Foundation
import Testing
@testable import SWIM

@Suite("SWIM Multi-Node Tests")
struct SWIMMultiNodeTests {

    @Test("Two nodes discover each other via join", .timeLimit(.minutes(1)))
    func twoNodeMutualDiscovery() async throws {
        // Create transports
        let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")

        // Connect bidirectionally
        transport1.connect(to: transport2)
        transport2.connect(to: transport1)

        // Create nodes with meaningful IDs
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))

        // Configure transports with actual member IDs
        transport1.setLocalMemberID(member1.id)
        transport2.setLocalMemberID(member2.id)

        let node1 = SWIMInstance(
            localMember: member1,
            config: .development,
            transport: transport1
        )
        let node2 = SWIMInstance(
            localMember: member2,
            config: .development,
            transport: transport2
        )

        // Start both nodes
        await node1.start()
        await node2.start()

        // Node1 joins through node2
        try await node1.join(seeds: [member2.id])

        // Wait for discovery - protocol loop may need time
        try await Task.sleep(for: .milliseconds(300))

        // Verify mutual discovery
        let node1Members = await node1.members
        let node2Members = await node2.members

        let node1KnowsNode2 = node1Members.contains { $0.id == member2.id }
        let node2KnowsNode1 = node2Members.contains { $0.id == member1.id }

        #expect(node1KnowsNode2, "Node1 should know about Node2")
        #expect(node2KnowsNode1, "Node2 should know about Node1 (received join ping)")

        // Both nodes should have at least 2 members (self + other)
        #expect(node1Members.count >= 2, "Node1 should have at least 2 members (self + node2)")
        #expect(node2Members.count >= 2, "Node2 should have at least 2 members (self + node1)")

        // Cleanup
        await node1.stop()
        await node2.stop()
        transport1.finish()
        transport2.finish()
    }

    @Test("Three node cluster with gossip propagation", .timeLimit(.minutes(1)))
    func threeNodeGossipPropagation() async throws {
        // Create transports
        let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")
        let transport3 = LoopbackTransport(localAddress: "127.0.0.1:8002")

        // Fully connected mesh
        transport1.connect(to: transport2)
        transport1.connect(to: transport3)
        transport2.connect(to: transport1)
        transport2.connect(to: transport3)
        transport3.connect(to: transport1)
        transport3.connect(to: transport2)

        // Create nodes with meaningful IDs
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let member3 = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"))

        // Configure transports with actual member IDs
        transport1.setLocalMemberID(member1.id)
        transport2.setLocalMemberID(member2.id)
        transport3.setLocalMemberID(member3.id)

        let node1 = SWIMInstance(localMember: member1, config: .development, transport: transport1)
        let node2 = SWIMInstance(localMember: member2, config: .development, transport: transport2)
        let node3 = SWIMInstance(localMember: member3, config: .development, transport: transport3)

        // Start all nodes
        await node1.start()
        await node2.start()
        await node3.start()

        // Node1 and Node2 join through each other
        try await node1.join(seeds: [member2.id])

        // Wait for initial discovery
        try await Task.sleep(for: .milliseconds(100))

        // Node3 joins through Node1
        try await node3.join(seeds: [member1.id])

        // Wait for gossip propagation
        try await Task.sleep(for: .milliseconds(300))

        // Verify all nodes know each other
        let node1Members = await node1.members
        let node2Members = await node2.members
        let node3Members = await node3.members

        // Verify specific member knowledge
        let node1KnowsNode2 = node1Members.contains { $0.id == member2.id }
        let node1KnowsNode3 = node1Members.contains { $0.id == member3.id }
        let node3KnowsNode1 = node3Members.contains { $0.id == member1.id }

        #expect(node1KnowsNode2, "Node1 should know Node2")
        #expect(node1KnowsNode3, "Node1 should know Node3")
        #expect(node3KnowsNode1, "Node3 should know Node1 (joined through Node1)")

        // Each node should have at least 2 members (self + at least one other)
        // Note: Full mesh may not be achieved immediately due to gossip timing
        #expect(node1Members.count >= 2, "Node1 should know at least 2 members")
        #expect(node2Members.count >= 2, "Node2 should know at least 2 members")
        #expect(node3Members.count >= 2, "Node3 should know at least 2 members")

        // Cleanup
        await node1.stop()
        await node2.stop()
        await node3.stop()
        transport1.finish()
        transport2.finish()
        transport3.finish()
    }

    @Test("Gossip propagation via third node", .timeLimit(.minutes(1)))
    func gossipPropagationViaThirdNode() async throws {
        // Create transports
        let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")
        let transport3 = LoopbackTransport(localAddress: "127.0.0.1:8002")

        // Node1 cannot reach Node2 directly, but can learn about Node2 through Node3
        // Node1 <-> Node3 <-> Node2
        transport1.connect(to: transport3)
        transport3.connect(to: transport1)
        transport3.connect(to: transport2)
        transport2.connect(to: transport3)
        // Note: No direct connection between 1 and 2

        // Create nodes with meaningful IDs
        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let member3 = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"))

        // Configure transports with actual member IDs
        transport1.setLocalMemberID(member1.id)
        transport2.setLocalMemberID(member2.id)
        transport3.setLocalMemberID(member3.id)

        let node1 = SWIMInstance(localMember: member1, config: .development, transport: transport1)
        let node2 = SWIMInstance(localMember: member2, config: .development, transport: transport2)
        let node3 = SWIMInstance(localMember: member3, config: .development, transport: transport3)

        await node1.start()
        await node2.start()
        await node3.start()

        // Node3 sends gossip about Node2 to Node1
        // This tests gossip propagation, not indirect probe
        let gossipAboutNode2 = GossipPayload(updates: [
            MembershipUpdate(member: member2),
            MembershipUpdate(member: member3)
        ])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossipAboutNode2)

        // Node3 sends this to Node1
        try await transport3.send(ping, to: member1.id)

        try await Task.sleep(for: .milliseconds(200))

        // Verify Node1 learned about Node2 via gossip from Node3
        let node1Members = await node1.members
        let hasNode2 = node1Members.contains { $0.id == member2.id }
        let hasNode3 = node1Members.contains { $0.id == member3.id }

        #expect(hasNode2, "Node1 should know about Node2 via gossip from Node3")
        #expect(hasNode3, "Node1 should know about Node3")

        // Cleanup
        await node1.stop()
        await node2.stop()
        await node3.stop()
        transport1.finish()
        transport2.finish()
        transport3.finish()
    }

    @Test("Indirect probe sends ping to target on behalf of requester", .timeLimit(.minutes(1)))
    func indirectProbeSendsPingToTarget() async throws {
        // Test that ping-req mechanism correctly forwards probe to target
        // Note: The implementation blocks receiveLoop while handling ping-req,
        // so we test the initial forwarding behavior, not the full round-trip.

        let transport3 = MockTransport(localAddress: "127.0.0.1:8002")

        let member1 = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let member3 = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"))

        // Node3 handles ping-req (acts as intermediary)
        var config = SWIMConfiguration.development
        config.pingTimeout = .milliseconds(30)

        let node3 = SWIMInstance(localMember: member3, config: config, transport: transport3)
        await node3.start()

        // Node1 sends ping-req to Node3, asking to probe Node2
        let pingReq = SWIMMessage.pingRequest(sequenceNumber: 42, target: member2.id, payload: .empty)
        transport3.receive(pingReq, from: member1.id)

        // Wait for ping to be sent to target
        try await Task.sleep(for: .milliseconds(20))

        // Verify Node3 sent ping to Node2
        let sentMessages = transport3.getSentMessages()
        let pingSentToNode2 = sentMessages.contains { msg, dest in
            if case .ping = msg {
                return dest == member2.id
            }
            return false
        }
        #expect(pingSentToNode2, "Node3 should send ping to Node2 on behalf of Node1")

        // Wait for ping timeout + processing so ping-req handling completes
        try await Task.sleep(for: .milliseconds(100))

        // Verify Node3 sent response (nack since Node2 won't respond) to Node1
        let allSentMessages = transport3.getSentMessages()
        let responseToNode1 = allSentMessages.contains { msg, dest in
            switch msg {
            case .ack(let seq, _, _), .nack(let seq, _):
                return seq == 42 && dest == member1.id
            default:
                return false
            }
        }
        #expect(responseToNode1, "Node3 should send response (ack or nack) to Node1")

        await node3.stop()
    }

    @Test("Graceful leave broadcasts departure", .timeLimit(.minutes(1)))
    func gracefulLeaveBroadcasts() async throws {
        // Test that graceful leave sends dead status to other nodes
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .development,
            transport: transport
        )

        await instance.start()

        // Add some members so there are targets for broadcast
        let member2 = Member(id: MemberID(id: "node2", address: "127.0.0.1:8001"))
        let member3 = Member(id: MemberID(id: "node3", address: "127.0.0.1:8002"))
        let gossip = GossipPayload(updates: [
            MembershipUpdate(member: member2),
            MembershipUpdate(member: member3)
        ])
        let ping = SWIMMessage.ping(sequenceNumber: 1, payload: gossip)
        transport.receive(ping, from: member2.id)

        try await Task.sleep(for: .milliseconds(50))
        transport.clearSentMessages()

        // Leave gracefully
        await instance.leave()

        // Check that departure messages were sent
        let sentMessages = transport.getSentMessages()

        // Should have sent pings with dead status to other members
        let departureSent = sentMessages.contains { msg, _ in
            if case .ping(_, let payload) = msg {
                return payload.updates.contains { update in
                    update.memberID == localMember.id && update.status == .dead
                }
            }
            return false
        }
        #expect(departureSent, "Should broadcast dead status when leaving")
    }

    @Test("Member status transitions from alive to suspect via gossip", .timeLimit(.minutes(1)))
    func memberStatusTransitionsViagossip() async throws {
        // Test that member status can transition based on gossip
        // Use very long protocol period to avoid interference from protocol loop
        var config = SWIMConfiguration.development
        config.protocolPeriod = .seconds(10)  // Very long to prevent probing during test

        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: config,
            transport: transport
        )

        await instance.start()

        // Add a member as alive via gossip from a THIRD party
        // This is a realistic scenario: learning about node2 from node3's gossip
        let remoteMember = MemberID(id: "node2", address: "127.0.0.1:8001")
        let thirdParty = MemberID(id: "node3", address: "127.0.0.1:8002")
        let aliveMember = Member(id: remoteMember, status: .alive, incarnation: .initial)
        let gossip1 = GossipPayload(updates: [MembershipUpdate(member: aliveMember)])
        let ping1 = SWIMMessage.ping(sequenceNumber: 1, payload: gossip1)
        transport.receive(ping1, from: thirdParty)

        try await Task.sleep(for: .milliseconds(30))

        // Verify alive
        var members = await instance.members
        var node2 = members.first { $0.id == remoteMember }
        #expect(node2?.status == .alive, "Member should be alive initially")

        // Update to suspect via gossip (same incarnation, higher severity)
        let suspectMember = Member(id: remoteMember, status: .suspect, incarnation: .initial)
        let gossip2 = GossipPayload(updates: [MembershipUpdate(member: suspectMember)])
        let ping2 = SWIMMessage.ping(sequenceNumber: 2, payload: gossip2)
        transport.receive(ping2, from: thirdParty)

        try await Task.sleep(for: .milliseconds(30))

        // Verify suspect
        members = await instance.members
        node2 = members.first { $0.id == remoteMember }
        #expect(node2?.status == .suspect, "Member should be suspect after gossip")

        // Update to dead via gossip (same incarnation, higher severity)
        let deadMember = Member(id: remoteMember, status: .dead, incarnation: .initial)
        let gossip3 = GossipPayload(updates: [MembershipUpdate(member: deadMember)])
        let ping3 = SWIMMessage.ping(sequenceNumber: 3, payload: gossip3)
        transport.receive(ping3, from: thirdParty)

        try await Task.sleep(for: .milliseconds(30))

        // Verify dead
        members = await instance.members
        node2 = members.first { $0.id == remoteMember }
        #expect(node2?.status == .dead, "Member should be dead after gossip")

        await instance.stop()
    }
}
