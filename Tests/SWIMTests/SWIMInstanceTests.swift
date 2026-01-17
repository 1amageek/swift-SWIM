/// SWIMInstance Tests

import Foundation
import Testing
@testable import SWIM

@Suite("SWIMInstance Tests")
struct SWIMInstanceTests {

    @Test("Create instance")
    func createInstance() async {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .default,
            transport: transport
        )

        let local = await instance.local
        #expect(local.id == localMember.id)
    }

    @Test("Start and stop")
    func startStop() async {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .default,
            transport: transport
        )

        await instance.start()

        // Give it a moment to start
        try? await Task.sleep(for: .milliseconds(50))

        await instance.stop()
    }

    @Test("Join sends ping to seeds")
    func joinSendsPing() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .default,
            transport: transport
        )

        await instance.start()

        let seed = MemberID(id: "seed", address: "127.0.0.1:9000")
        try await instance.join(seeds: [seed])

        let sentMessages = transport.getSentMessages()
        #expect(sentMessages.count >= 1)

        // First message should be a ping to the seed
        if case .ping = sentMessages[0].0 {
            #expect(sentMessages[0].1 == seed)
        } else {
            Issue.record("Expected ping message")
        }

        await instance.stop()
    }

    @Test("Join with empty seeds throws error")
    func joinEmptySeeds() async {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .default,
            transport: transport
        )

        await instance.start()

        do {
            try await instance.join(seeds: [])
            Issue.record("Expected error for empty seeds")
        } catch {
            // Expected
        }

        await instance.stop()
    }

    @Test("Members list")
    func membersList() async {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .default,
            transport: transport
        )

        let members = await instance.members
        #expect(members.count == 1)
        #expect(members[0].id == localMember.id)
    }

    @Test("Alive count")
    func aliveCount() async {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localMember = Member(id: MemberID(id: "node1", address: "127.0.0.1:8000"))

        let instance = SWIMInstance(
            localMember: localMember,
            config: .default,
            transport: transport
        )

        let count = await instance.aliveCount
        #expect(count == 1)
    }
}

@Suite("MockTransport Tests")
struct MockTransportTests {

    @Test("Send records message")
    func sendRecords() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let target = MemberID(id: "target", address: "127.0.0.1:9000")
        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)

        try await transport.send(message, to: target)

        let sent = transport.getSentMessages()
        #expect(sent.count == 1)
        #expect(sent[0].1 == target)
    }

    @Test("Clear sent messages")
    func clearSent() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let target = MemberID(id: "target", address: "127.0.0.1:9000")
        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)

        try await transport.send(message, to: target)
        #expect(transport.getSentMessages().count == 1)

        transport.clearSentMessages()
        #expect(transport.getSentMessages().isEmpty)
    }

    @Test("Receive message")
    func receiveMessage() async {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let sender = MemberID(id: "sender", address: "127.0.0.1:9000")
        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)

        // Simulate receiving a message
        transport.receive(message, from: sender)

        // Read from incoming messages
        var receivedMessage: SWIMMessage?
        var receivedSender: MemberID?

        for await (msg, from) in transport.incomingMessages {
            receivedMessage = msg
            receivedSender = from
            break
        }

        if case .ping(let seq, _) = receivedMessage {
            #expect(seq == 1)
        } else {
            Issue.record("Expected ping message")
        }
        #expect(receivedSender == sender)
    }
}

@Suite("LoopbackTransport Tests")
struct LoopbackTransportTests {

    @Test("Send to connected peer")
    func sendToConnectedPeer() async throws {
        let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")

        // Connect transports
        transport1.connect(to: transport2)
        transport2.connect(to: transport1)

        let target = MemberID(id: "node2", address: "127.0.0.1:8001")
        let message = SWIMMessage.ping(sequenceNumber: 42, payload: .empty)

        try await transport1.send(message, to: target)

        // Check transport2 received it
        var receivedMessage: SWIMMessage?

        // Use a task to read with timeout
        let receiveTask = Task<SWIMMessage?, Never> {
            for await (msg, _) in transport2.incomingMessages {
                return msg
            }
            return nil
        }

        // Wait a bit then finish
        try await Task.sleep(for: .milliseconds(50))
        transport2.finish()

        receivedMessage = await receiveTask.value

        if case .ping(let seq, _) = receivedMessage {
            #expect(seq == 42)
        } else {
            Issue.record("Expected ping message")
        }
    }

    @Test("Send to disconnected peer throws error")
    func sendToDisconnectedPeer() async {
        let transport = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let target = MemberID(id: "unknown", address: "127.0.0.1:9999")
        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)

        do {
            try await transport.send(message, to: target)
            Issue.record("Expected error for disconnected peer")
        } catch {
            // Expected
        }
    }

    @Test("Disconnect from peer")
    func disconnectFromPeer() async {
        let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")

        transport1.connect(to: transport2)

        let target = MemberID(id: "node2", address: "127.0.0.1:8001")
        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)

        // Should work
        try? await transport1.send(message, to: target)

        // Disconnect
        transport1.disconnect(from: "127.0.0.1:8001")

        // Should fail now
        do {
            try await transport1.send(message, to: target)
            Issue.record("Expected error after disconnect")
        } catch {
            // Expected
        }
    }
}

@Suite("SWIMConfiguration Tests")
struct SWIMConfigurationTests {

    @Test("Default configuration")
    func defaultConfig() {
        let config = SWIMConfiguration.default

        #expect(config.protocolPeriod == .milliseconds(200))
        #expect(config.pingTimeout == .milliseconds(100))
        #expect(config.indirectProbeCount == 3)
        #expect(config.suspicionMultiplier == 5.0)
        #expect(config.maxPayloadSize == 10)
        #expect(config.baseDisseminationLimit == 3)
    }

    @Test("Custom configuration")
    func customConfig() {
        var config = SWIMConfiguration()
        config.protocolPeriod = .seconds(1)
        config.pingTimeout = .milliseconds(500)
        config.indirectProbeCount = 5
        config.suspicionMultiplier = 10.0

        #expect(config.protocolPeriod == .seconds(1))
        #expect(config.pingTimeout == .milliseconds(500))
        #expect(config.indirectProbeCount == 5)
        #expect(config.suspicionMultiplier == 10.0)
    }

    @Test("Suspicion timeout scales with member count")
    func suspicionTimeoutScaling() {
        let config = SWIMConfiguration.default

        let timeout1 = config.suspicionTimeout(memberCount: 1)
        let timeout10 = config.suspicionTimeout(memberCount: 10)
        let timeout100 = config.suspicionTimeout(memberCount: 100)

        // Larger clusters should have longer suspicion timeouts
        #expect(timeout10 > timeout1)
        #expect(timeout100 > timeout10)
    }

    @Test("Dissemination limit scales with member count")
    func disseminationLimitScaling() {
        let config = SWIMConfiguration.default

        let limit1 = config.disseminationLimit(memberCount: 1)
        let limit10 = config.disseminationLimit(memberCount: 10)
        let limit100 = config.disseminationLimit(memberCount: 100)

        // Larger clusters should have higher dissemination limits
        #expect(limit10 >= limit1)
        #expect(limit100 >= limit10)
    }
}
