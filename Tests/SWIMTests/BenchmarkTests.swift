/// SWIM Benchmark Tests
///
/// Performance benchmarks for message encoding/decoding.

import Foundation
import Testing
@testable import SWIM

@Suite("Benchmark Tests")
struct BenchmarkTests {

    // MARK: - Encoding Benchmarks

    @Test("Benchmark: Encode ping message")
    func benchmarkEncodePing() {
        let payload = GossipPayload.empty
        let message = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)

        let iterations = 100_000
        let start = ContinuousClock.now

        for _ in 0..<iterations {
            _ = SWIMMessageCodec.encode(message)
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Encode ping: \(perIteration) per iteration (\(iterations) iterations)")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }

    @Test("Benchmark: Encode ping with payload")
    func benchmarkEncodePingWithPayload() {
        let updates = (0..<5).map { i in
            MembershipUpdate(
                member: Member(
                    id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"),
                    status: .alive,
                    incarnation: Incarnation(value: UInt64(i))
                )
            )
        }
        let payload = GossipPayload(updates: updates)
        let message = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)

        let iterations = 50_000
        let start = ContinuousClock.now

        for _ in 0..<iterations {
            _ = SWIMMessageCodec.encode(message)
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Encode ping with 5 updates: \(perIteration) per iteration (\(iterations) iterations)")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }

    @Test("Benchmark: Encode to bytes vs Data")
    func benchmarkEncodeToBytes() {
        let payload = GossipPayload.empty
        let message = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)

        let iterations = 100_000

        // Benchmark encode to Data
        let startData = ContinuousClock.now
        for _ in 0..<iterations {
            _ = SWIMMessageCodec.encode(message)
        }
        let elapsedData = ContinuousClock.now - startData

        // Benchmark encode to bytes
        let startBytes = ContinuousClock.now
        for _ in 0..<iterations {
            _ = SWIMMessageCodec.encodeToBytes(message)
        }
        let elapsedBytes = ContinuousClock.now - startBytes

        print("Encode to Data: \(elapsedData / iterations) per iteration")
        print("Encode to bytes: \(elapsedBytes / iterations) per iteration")
    }

    // MARK: - Decoding Benchmarks

    @Test("Benchmark: Decode ping message")
    func benchmarkDecodePing() throws {
        let payload = GossipPayload.empty
        let message = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)
        let data = SWIMMessageCodec.encode(message)

        let iterations = 100_000
        let start = ContinuousClock.now

        for _ in 0..<iterations {
            _ = try SWIMMessageCodec.decode(data)
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Decode ping: \(perIteration) per iteration (\(iterations) iterations)")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }

    @Test("Benchmark: Decode ping with payload")
    func benchmarkDecodePingWithPayload() throws {
        let updates = (0..<5).map { i in
            MembershipUpdate(
                member: Member(
                    id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"),
                    status: .alive,
                    incarnation: Incarnation(value: UInt64(i))
                )
            )
        }
        let payload = GossipPayload(updates: updates)
        let message = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)
        let data = SWIMMessageCodec.encode(message)

        let iterations = 50_000
        let start = ContinuousClock.now

        for _ in 0..<iterations {
            _ = try SWIMMessageCodec.decode(data)
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Decode ping with 5 updates: \(perIteration) per iteration (\(iterations) iterations)")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }

    @Test("Benchmark: Decode from bytes vs Data")
    func benchmarkDecodeFromBytes() throws {
        let payload = GossipPayload.empty
        let message = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)
        let data = SWIMMessageCodec.encode(message)
        let bytes = SWIMMessageCodec.encodeToBytes(message)

        let iterations = 100_000

        // Benchmark decode from Data
        let startData = ContinuousClock.now
        for _ in 0..<iterations {
            _ = try SWIMMessageCodec.decode(data)
        }
        let elapsedData = ContinuousClock.now - startData

        // Benchmark decode from bytes
        let startBytes = ContinuousClock.now
        for _ in 0..<iterations {
            _ = try SWIMMessageCodec.decode(bytes)
        }
        let elapsedBytes = ContinuousClock.now - startBytes

        print("Decode from Data: \(elapsedData / iterations) per iteration")
        print("Decode from bytes: \(elapsedBytes / iterations) per iteration")
    }

    // MARK: - Round-trip Benchmarks

    @Test("Benchmark: Full encode/decode round-trip")
    func benchmarkRoundTrip() throws {
        let updates = (0..<3).map { i in
            MembershipUpdate(
                member: Member(
                    id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"),
                    status: i % 2 == 0 ? .alive : .suspect,
                    incarnation: Incarnation(value: UInt64(i))
                )
            )
        }
        let payload = GossipPayload(updates: updates)
        let original = SWIMMessage.ping(sequenceNumber: 12345, payload: payload)

        let iterations = 50_000
        let start = ContinuousClock.now

        for _ in 0..<iterations {
            let data = SWIMMessageCodec.encode(original)
            _ = try SWIMMessageCodec.decode(data)
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Round-trip with 3 updates: \(perIteration) per iteration (\(iterations) iterations)")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) round-trips/sec")
    }

    // MARK: - MemberList Benchmarks

    @Test("Benchmark: MemberList random selection")
    func benchmarkMemberListRandomSelection() {
        let members = (0..<100).map { i in
            Member(id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"))
        }
        let list = MemberList(members: members)

        let iterations = 100_000
        let start = ContinuousClock.now

        for _ in 0..<iterations {
            _ = list.randomAliveMembers(count: 3, excluding: [])
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Random selection (3 from 100): \(perIteration) per iteration")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }

    @Test("Benchmark: MemberList update")
    func benchmarkMemberListUpdate() {
        let list = MemberList()
        let members = (0..<100).map { i in
            Member(id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"))
        }

        // Pre-populate
        for member in members {
            _ = list.update(member)
        }

        let iterations = 100_000
        let start = ContinuousClock.now

        for i in 0..<iterations {
            var member = members[i % members.count]
            member.incarnation = Incarnation(value: UInt64(i))
            _ = list.update(member)
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("MemberList update: \(perIteration) per iteration")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }

    // MARK: - Disseminator Benchmarks

    @Test("Benchmark: Disseminator enqueue and get payload")
    func benchmarkDisseminator() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 6)
        let members = (0..<50).map { i in
            Member(
                id: MemberID(id: "node\(i)", address: "127.0.0.1:\(8000 + i)"),
                status: i % 3 == 0 ? .suspect : .alive,
                incarnation: Incarnation(value: UInt64(i))
            )
        }

        let iterations = 50_000
        let start = ContinuousClock.now

        for i in 0..<iterations {
            disseminator.enqueue(member: members[i % members.count])
            _ = disseminator.getPayloadForMessage()
        }

        let elapsed = ContinuousClock.now - start
        let perIteration = elapsed / iterations

        print("Disseminator enqueue+get: \(perIteration) per iteration")
        print("  Throughput: \(Double(iterations) / elapsed.totalSeconds) ops/sec")
    }
}

// MARK: - Duration Helper

extension Duration {
    var totalSeconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
