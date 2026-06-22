/// Message Buffer Safety Tests
///
/// Tests for decoder robustness against attacker-controlled headers and for
/// encoder validation of over-long length-prefixed strings.

import Foundation
import Testing
@testable import SWIM

@Suite("Message Buffer Safety Tests")
struct MessageBufferSafetyTests {

    // MARK: - Oversized gossip count (finding #12)

    @Test("GossipPayload.decode with an oversized count on a short buffer fails without over-reserving")
    func oversizedCountOnShortBufferFails() {
        // Build a ping whose gossip count header claims 65535 updates but the
        // buffer holds none. The decoder must reject it (return nil overall)
        // without reserving capacity for 65535 elements.
        var bytes: [UInt8] = []
        bytes.append(0x01) // ping type
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // sequence number
        bytes.append(contentsOf: [0xFF, 0xFF]) // gossip count = 65535
        // No update bytes follow.

        // Decoding must fail cleanly (truncated), not crash or hang.
        #expect(throws: SWIMCodecError.self) {
            _ = try SWIMMessageCodec.decode(bytes)
        }
    }

    @Test("GossipPayload.decode reserves at most the buffer-bounded number of updates")
    func decodeReservationIsBounded() {
        // Directly exercise GossipPayload.decode with a header claiming a large
        // count but a buffer too short to hold them. It must return nil rather
        // than attempt a 65535-element reservation against a few bytes.
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0xFF, 0xFF]) // count = 65535
        // Provide bytes for far fewer than 65535 updates (just a partial one).
        bytes.append(contentsOf: [0x00, 0x01]) // would-be id length

        let result: GossipPayload? = bytes.withUnsafeBytes { raw in
            let buffer = ReadBuffer(raw)
            var offset = 0
            return GossipPayload.decode(from: buffer, at: &offset)
        }
        #expect(result == nil, "An impossible count on a short buffer must fail to decode")
    }

    @Test("GossipPayload round-trips a legitimate count")
    func legitimateCountRoundTrips() throws {
        let updates = (0..<3).map { i in
            MembershipUpdate(member: Member(
                id: MemberID(id: "node\(i)", address: "127.0.0.1:800\(i)"),
                status: .alive,
                incarnation: Incarnation(value: UInt64(i))
            ))
        }
        let original = SWIMMessage.ping(sequenceNumber: 1, payload: GossipPayload(updates: updates))
        let data = try SWIMMessageCodec.encode(original)
        let decoded = try SWIMMessageCodec.decode(data)
        if case .ping(_, let payload) = decoded {
            #expect(payload.updates.count == 3)
        } else {
            Issue.record("Expected ping")
        }
    }

    // MARK: - Over-long length-prefixed string (finding #14)

    @Test("Encoding a MemberID with an over-long id throws instead of trapping")
    func overLongStringThrows() {
        // A string longer than the 16-bit length field can hold.
        let tooLong = String(repeating: "x", count: Int(UInt16.max) + 1)
        let target = MemberID(id: tooLong, address: "127.0.0.1:8000")
        let message = SWIMMessage.nack(sequenceNumber: 1, target: target)

        #expect(throws: SWIMCodecError.self) {
            _ = try SWIMMessageCodec.encode(message)
        }
    }

    @Test("Encoding a string exactly at the 16-bit limit succeeds")
    func maxLengthStringSucceeds() throws {
        let maxLen = String(repeating: "y", count: Int(UInt16.max))
        let target = MemberID(id: maxLen, address: "a")
        let message = SWIMMessage.nack(sequenceNumber: 1, target: target)
        // Encoding succeeds; the message exceeds the codec's max wire size, but
        // that is a separate concern from the string-length validation.
        let data = try SWIMMessageCodec.encode(message)
        #expect(data.count > Int(UInt16.max))
    }

    @Test("writeLengthPrefixedString surfaces a typed error for an over-long string")
    func writeLengthPrefixedStringThrowsTyped() {
        let tooLong = String(repeating: "z", count: Int(UInt16.max) + 5)
        #expect(throws: SWIMCodecError.stringTooLong(byteCount: Int(UInt16.max) + 5)) {
            var buffer = WriteBuffer()
            try buffer.writeLengthPrefixedString(tooLong)
        }
    }
}
