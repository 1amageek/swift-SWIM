/// SWIMTransportUDP Tests

import Foundation
import Testing
import Synchronization
@testable import SWIM
@testable import SWIMTransportUDP

@Suite("SWIMTransportUDP Tests")
struct SWIMTransportUDPTests {

    // MARK: - Initialization Tests

    @Test("Create transport with default host")
    func createWithDefaultHost() {
        let transport = SWIMUDPTransport(host: "0.0.0.0", port: 0)
        #expect(transport.localAddress.contains("0.0.0.0"))
    }

    @Test("Create transport with specific port")
    func createWithSpecificPort() {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 7946)
        #expect(transport.localAddress == "127.0.0.1:7946")
    }

    // MARK: - Lifecycle Tests

    @Test("Start and stop transport")
    func startAndStopTransport() async throws {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport.start()

        // After start, local address should have actual port
        let address = transport.localAddress
        #expect(!address.contains(":0"))

        await transport.stop()
    }

    @Test("Local address updates after start")
    func localAddressUpdatesAfterStart() async throws {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        // Before start, address has port 0
        let beforeAddress = transport.localAddress
        #expect(beforeAddress == "127.0.0.1:0")

        try await transport.start()

        // After start, address should have assigned port
        let afterAddress = transport.localAddress
        #expect(afterAddress != "127.0.0.1:0")
        #expect(afterAddress.hasPrefix("127.0.0.1:"))

        await transport.stop()
    }

    // MARK: - Send/Receive Tests

    @Test("Send and receive ping message")
    func sendAndReceivePing() async throws {
        // Create two transports
        let transport1 = SWIMUDPTransport(host: "127.0.0.1", port: 0)
        let transport2 = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport1.start()
        try await transport2.start()

        let address2 = transport2.localAddress

        // Set up receiver
        let receivedMessage = Mutex<SWIMMessage?>(nil)
        let receivedFrom = Mutex<MemberID?>(nil)

        let receiveTask = Task {
            for await (message, from) in transport2.incomingMessages {
                receivedMessage.withLock { $0 = message }
                receivedFrom.withLock { $0 = from }
                break
            }
        }

        // Give receiver time to start
        try await Task.sleep(for: .milliseconds(50))

        // Send ping from transport1 to transport2
        let pingMessage = SWIMMessage.ping(sequenceNumber: 12345, payload: .empty)
        let targetMember = MemberID(id: "node2", address: address2)
        try await transport1.send(pingMessage, to: targetMember)

        // Wait for message
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if receivedMessage.withLock({ $0 != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        receiveTask.cancel()

        // Verify
        let received = receivedMessage.withLock { $0 }
        #expect(received != nil)
        if case .ping(let seq, let payload) = received {
            #expect(seq == 12345)
            #expect(payload.updates.isEmpty)
        } else {
            Issue.record("Expected ping message")
        }

        await transport1.stop()
        await transport2.stop()
    }

    @Test("Send and receive ack message with payload")
    func sendAndReceiveAckWithPayload() async throws {
        let transport1 = SWIMUDPTransport(host: "127.0.0.1", port: 0)
        let transport2 = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport1.start()
        try await transport2.start()

        let address2 = transport2.localAddress

        let receivedMessage = Mutex<SWIMMessage?>(nil)

        let receiveTask = Task {
            for await (message, _) in transport2.incomingMessages {
                receivedMessage.withLock { $0 = message }
                break
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Create ack with gossip payload
        let update = MembershipUpdate(
            member: Member(
                id: MemberID(id: "node1", address: "192.168.1.10:8000"),
                status: .suspect,
                incarnation: Incarnation(value: 5)
            )
        )
        let payload = GossipPayload(updates: [update])
        let target = MemberID(id: "responder", address: address2)
        let ackMessage = SWIMMessage.ack(sequenceNumber: 54321, target: target, payload: payload)

        try await transport1.send(ackMessage, to: target)

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if receivedMessage.withLock({ $0 != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        receiveTask.cancel()

        let received = receivedMessage.withLock { $0 }
        #expect(received != nil)
        if case .ack(let seq, let decodedTarget, let decodedPayload) = received {
            #expect(seq == 54321)
            #expect(decodedTarget == target)
            #expect(decodedPayload.updates.count == 1)
            #expect(decodedPayload.updates[0].memberID.id == "node1")
            #expect(decodedPayload.updates[0].status == .suspect)
        } else {
            Issue.record("Expected ack message")
        }

        await transport1.stop()
        await transport2.stop()
    }

    @Test("Send and receive pingRequest message")
    func sendAndReceivePingRequest() async throws {
        let transport1 = SWIMUDPTransport(host: "127.0.0.1", port: 0)
        let transport2 = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport1.start()
        try await transport2.start()

        let address2 = transport2.localAddress

        let receivedMessage = Mutex<SWIMMessage?>(nil)

        let receiveTask = Task {
            for await (message, _) in transport2.incomingMessages {
                receivedMessage.withLock { $0 = message }
                break
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        let target = MemberID(id: "suspect-node", address: "10.0.0.1:9000")
        let pingReqMessage = SWIMMessage.pingRequest(
            sequenceNumber: 99999,
            target: target,
            payload: .empty
        )
        let recipient = MemberID(id: "node2", address: address2)
        try await transport1.send(pingReqMessage, to: recipient)

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if receivedMessage.withLock({ $0 != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        receiveTask.cancel()

        let received = receivedMessage.withLock { $0 }
        #expect(received != nil)
        if case .pingRequest(let seq, let decodedTarget, let payload) = received {
            #expect(seq == 99999)
            #expect(decodedTarget == target)
            #expect(payload.updates.isEmpty)
        } else {
            Issue.record("Expected pingRequest message")
        }

        await transport1.stop()
        await transport2.stop()
    }

    // MARK: - Error Handling Tests

    @Test("Send before start throws error")
    func sendBeforeStartThrows() async {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)
        let target = MemberID(id: "node", address: "127.0.0.1:8000")

        await #expect(throws: SWIMError.self) {
            try await transport.send(message, to: target)
        }
    }

    @Test("Send to invalid address throws error")
    func sendToInvalidAddressThrows() async throws {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)
        try await transport.start()

        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)
        let target = MemberID(id: "node", address: "invalid-address")

        await #expect(throws: SWIMError.self) {
            try await transport.send(message, to: target)
        }

        await transport.stop()
    }

    @Test("Double start throws error")
    func doubleStartThrows() async throws {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport.start()

        // Second start should throw
        await #expect(throws: SWIMError.self) {
            try await transport.start()
        }

        await transport.stop()
    }

    @Test("Restart after stop throws error")
    func restartAfterStopThrows() async throws {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport.start()
        await transport.stop()

        // Start after stop should throw (single-use)
        await #expect(throws: SWIMError.self) {
            try await transport.start()
        }
    }

    @Test("Send after stop throws error")
    func sendAfterStopThrows() async throws {
        let transport = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport.start()
        await transport.stop()

        let message = SWIMMessage.ping(sequenceNumber: 1, payload: .empty)
        let target = MemberID(id: "node", address: "127.0.0.1:8000")

        await #expect(throws: SWIMError.self) {
            try await transport.send(message, to: target)
        }
    }

    // MARK: - Multiple Messages Test

    @Test("Send multiple messages in sequence")
    func sendMultipleMessages() async throws {
        let transport1 = SWIMUDPTransport(host: "127.0.0.1", port: 0)
        let transport2 = SWIMUDPTransport(host: "127.0.0.1", port: 0)

        try await transport1.start()
        try await transport2.start()

        let address2 = transport2.localAddress
        let receivedCount = Mutex<Int>(0)

        let receiveTask = Task {
            for await _ in transport2.incomingMessages {
                receivedCount.withLock { $0 += 1 }
                if receivedCount.withLock({ $0 >= 5 }) {
                    break
                }
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        let target = MemberID(id: "node2", address: address2)

        // Send 5 messages
        for i in 0..<5 {
            let message = SWIMMessage.ping(sequenceNumber: UInt64(i), payload: .empty)
            try await transport1.send(message, to: target)
        }

        // Wait for all messages
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if receivedCount.withLock({ $0 >= 5 }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        receiveTask.cancel()

        let count = receivedCount.withLock { $0 }
        #expect(count == 5)

        await transport1.stop()
        await transport2.stop()
    }
}
