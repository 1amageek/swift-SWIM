/// MessageCodec Tests

import Foundation
import Testing
@testable import SWIM

@Suite("MessageCodec Tests")
struct MessageCodecTests {

    // MARK: - Ping Message

    @Test("Encode and decode ping with empty payload")
    func pingEmptyPayload() throws {
        let original = SWIMMessage.ping(sequenceNumber: 12345, payload: .empty)
        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .ping(let seq, let payload) = decoded {
            #expect(seq == 12345)
            #expect(payload.updates.isEmpty)
        } else {
            Issue.record("Expected ping message")
        }
    }

    @Test("Encode and decode ping with payload")
    func pingWithPayload() throws {
        let update = MembershipUpdate(
            member: Member(
                id: MemberID(id: "node1", address: "127.0.0.1:8000"),
                status: .suspect,
                incarnation: Incarnation(value: 5)
            )
        )
        let payload = GossipPayload(updates: [update])
        let original = SWIMMessage.ping(sequenceNumber: 999, payload: payload)

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .ping(let seq, let decodedPayload) = decoded {
            #expect(seq == 999)
            #expect(decodedPayload.updates.count == 1)
            #expect(decodedPayload.updates[0].memberID.id == "node1")
            #expect(decodedPayload.updates[0].status == .suspect)
            #expect(decodedPayload.updates[0].incarnation.value == 5)
        } else {
            Issue.record("Expected ping message")
        }
    }

    // MARK: - PingRequest Message

    @Test("Encode and decode pingRequest")
    func pingRequest() throws {
        let target = MemberID(id: "target", address: "192.168.1.1:9000")
        let original = SWIMMessage.pingRequest(
            sequenceNumber: 54321,
            target: target,
            payload: .empty
        )

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .pingRequest(let seq, let decodedTarget, let payload) = decoded {
            #expect(seq == 54321)
            #expect(decodedTarget == target)
            #expect(payload.updates.isEmpty)
        } else {
            Issue.record("Expected pingRequest message")
        }
    }

    @Test("Encode and decode pingRequest with payload")
    func pingRequestWithPayload() throws {
        let target = MemberID(id: "target", address: "192.168.1.1:9000")
        let update = MembershipUpdate(
            member: Member(
                id: MemberID(id: "node2", address: "10.0.0.1:7000"),
                status: .dead,
                incarnation: Incarnation(value: 10)
            )
        )
        let payload = GossipPayload(updates: [update])
        let original = SWIMMessage.pingRequest(
            sequenceNumber: 11111,
            target: target,
            payload: payload
        )

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .pingRequest(let seq, let decodedTarget, let decodedPayload) = decoded {
            #expect(seq == 11111)
            #expect(decodedTarget == target)
            #expect(decodedPayload.updates.count == 1)
            #expect(decodedPayload.updates[0].memberID.id == "node2")
            #expect(decodedPayload.updates[0].status == .dead)
        } else {
            Issue.record("Expected pingRequest message")
        }
    }

    // MARK: - Ack Message

    @Test("Encode and decode ack")
    func ack() throws {
        let target = MemberID(id: "responder", address: "10.0.0.5:8080")
        let original = SWIMMessage.ack(
            sequenceNumber: 12345,
            target: target,
            payload: .empty
        )

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .ack(let seq, let decodedTarget, let payload) = decoded {
            #expect(seq == 12345)
            #expect(decodedTarget == target)
            #expect(payload.updates.isEmpty)
        } else {
            Issue.record("Expected ack message")
        }
    }

    // MARK: - Nack Message

    @Test("Encode and decode nack")
    func nack() throws {
        let target = MemberID(id: "unreachable", address: "10.0.0.99:8080")
        let original = SWIMMessage.nack(sequenceNumber: 77777, target: target)

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .nack(let seq, let decodedTarget) = decoded {
            #expect(seq == 77777)
            #expect(decodedTarget == target)
        } else {
            Issue.record("Expected nack message")
        }
    }

    // MARK: - Multiple Updates

    @Test("Encode and decode multiple gossip updates")
    func multipleUpdates() throws {
        let updates = [
            MembershipUpdate(
                member: Member(
                    id: MemberID(id: "node1", address: "127.0.0.1:8000"),
                    status: .alive,
                    incarnation: Incarnation(value: 1)
                )
            ),
            MembershipUpdate(
                member: Member(
                    id: MemberID(id: "node2", address: "127.0.0.1:8001"),
                    status: .suspect,
                    incarnation: Incarnation(value: 3)
                )
            ),
            MembershipUpdate(
                member: Member(
                    id: MemberID(id: "node3", address: "127.0.0.1:8002"),
                    status: .dead,
                    incarnation: Incarnation(value: 7)
                )
            ),
        ]
        let payload = GossipPayload(updates: updates)
        let original = SWIMMessage.ping(sequenceNumber: 1, payload: payload)

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .ping(_, let decodedPayload) = decoded {
            #expect(decodedPayload.updates.count == 3)

            #expect(decodedPayload.updates[0].memberID.id == "node1")
            #expect(decodedPayload.updates[0].status == .alive)
            #expect(decodedPayload.updates[0].incarnation.value == 1)

            #expect(decodedPayload.updates[1].memberID.id == "node2")
            #expect(decodedPayload.updates[1].status == .suspect)
            #expect(decodedPayload.updates[1].incarnation.value == 3)

            #expect(decodedPayload.updates[2].memberID.id == "node3")
            #expect(decodedPayload.updates[2].status == .dead)
            #expect(decodedPayload.updates[2].incarnation.value == 7)
        } else {
            Issue.record("Expected ping message")
        }
    }

    // MARK: - Edge Cases

    @Test("Sequence number max value")
    func maxSequenceNumber() throws {
        let original = SWIMMessage.ping(sequenceNumber: UInt64.max, payload: .empty)
        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .ping(let seq, _) = decoded {
            #expect(seq == UInt64.max)
        } else {
            Issue.record("Expected ping message")
        }
    }

    @Test("Empty string MemberID")
    func emptyStringMemberID() throws {
        let target = MemberID(id: "", address: "")
        let original = SWIMMessage.nack(sequenceNumber: 1, target: target)

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .nack(_, let decodedTarget) = decoded {
            #expect(decodedTarget.id == "")
            #expect(decodedTarget.address == "")
        } else {
            Issue.record("Expected nack message")
        }
    }

    @Test("Long MemberID strings")
    func longMemberIDStrings() throws {
        let longID = String(repeating: "a", count: 1000)
        let longAddress = String(repeating: "b", count: 1000)
        let target = MemberID(id: longID, address: longAddress)
        let original = SWIMMessage.nack(sequenceNumber: 1, target: target)

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .nack(_, let decodedTarget) = decoded {
            #expect(decodedTarget.id == longID)
            #expect(decodedTarget.address == longAddress)
        } else {
            Issue.record("Expected nack message")
        }
    }

    @Test("Unicode in MemberID")
    func unicodeMemberID() throws {
        let target = MemberID(id: "ノード1", address: "日本語:8000")
        let original = SWIMMessage.nack(sequenceNumber: 1, target: target)

        let data = SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)

        if case .nack(_, let decodedTarget) = decoded {
            #expect(decodedTarget.id == "ノード1")
            #expect(decodedTarget.address == "日本語:8000")
        } else {
            Issue.record("Expected nack message")
        }
    }

    // MARK: - Error Cases

    @Test("Decode empty data throws error")
    func decodeEmptyData() {
        #expect(throws: SWIMCodecError.self) {
            _ = try SWIMMessageCodec.decode(Data())
        }
    }

    @Test("Decode invalid message type throws error")
    func decodeInvalidType() {
        var data = Data()
        data.append(0xFF)  // Invalid type
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])  // Sequence number

        #expect(throws: SWIMCodecError.self) {
            _ = try SWIMMessageCodec.decode(data)
        }
    }

    @Test("Decode truncated data throws error")
    func decodeTruncatedData() {
        var data = Data()
        data.append(0x01)  // Ping type
        data.append(contentsOf: [0, 0, 0])  // Truncated sequence number

        #expect(throws: SWIMCodecError.self) {
            _ = try SWIMMessageCodec.decode(data)
        }
    }
}
