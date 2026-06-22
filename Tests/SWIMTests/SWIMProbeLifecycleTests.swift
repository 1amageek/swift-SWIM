/// SWIM Probe Lifecycle Tests
///
/// Tests for the continuation-based ack waiting (exactly-once resume, no silent
/// success on a missing entry, no double-resume on ack/timeout races) and for
/// join failure surfacing.

import Foundation
import Synchronization
import Testing
@testable import SWIM

@Suite("SWIM Probe Lifecycle Tests")
struct SWIMProbeLifecycleTests {

    /// Transport that acks a ping after a configurable delay, optionally racing
    /// the probe timeout. Used to stress the ack/timeout resume paths.
    private final class DelayedAckTransport: SWIMTransport, Sendable {
        let localAddress: String
        let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>
        private let continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation
        private let state: Mutex<State>

        struct State: Sendable {
            var ackDelay: Duration
            var ackEnabled: Bool
            var localMemberID: MemberID
            var pingCount: Int = 0
        }

        init(localAddress: String, localMemberID: MemberID, ackDelay: Duration, ackEnabled: Bool) {
            self.localAddress = localAddress
            self.state = Mutex(State(ackDelay: ackDelay, ackEnabled: ackEnabled, localMemberID: localMemberID))
            var cont: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
            self.incomingMessages = AsyncStream { cont = $0 }
            self.continuation = cont
        }

        var pingCount: Int { state.withLock { $0.pingCount } }

        func send(_ message: SWIMMessage, to member: MemberID) async throws {
            // Respond to a direct ping with an ack from `member` after a delay.
            guard case .ping(let seq, _) = message else { return }
            let (delay, enabled, selfID) = state.withLock { s -> (Duration, Bool, MemberID) in
                s.pingCount += 1
                return (s.ackDelay, s.ackEnabled, s.localMemberID)
            }
            guard enabled else { return }
            Task { [continuation] in
                try? await Task.sleep(for: delay)
                // Ack's target is the pinged member (it claims to be alive).
                continuation.yield((.ack(sequenceNumber: seq, target: member, payload: .empty), member))
                _ = selfID
            }
        }

        func receive(_ message: SWIMMessage, from sender: MemberID) {
            continuation.yield((message, sender))
        }

        func finish() {
            continuation.finish()
        }
    }

    @Test("A prompt ack keeps the member alive (resume via ack path)", .timeLimit(.minutes(1)))
    func promptAckKeepsAlive() async throws {
        var config = SWIMConfiguration.development
        config.protocolPeriod = .milliseconds(30)
        config.pingTimeout = .milliseconds(40)
        config.indirectProbeCount = 0
        config.suspicionMultiplier = 5.0

        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let transport = DelayedAckTransport(
            localAddress: "127.0.0.1:8000",
            localMemberID: localID,
            ackDelay: .milliseconds(5),   // well within the ping timeout
            ackEnabled: true
        )
        let instance = SWIMInstance(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )

        // Run several protocol periods; prompt acks must keep the peer alive.
        try await Task.sleep(for: .milliseconds(250))

        let peer = await instance.members.first { $0.id == peerID }
        #expect(peer?.status == .alive, "A promptly-acked member must stay alive")

        try await instance.shutdown()
        transport.finish()
    }

    @Test("Ack racing the timeout never double-resumes (no crash) and yields a definite outcome", .timeLimit(.minutes(1)))
    func ackRacingTimeoutDoesNotDoubleResume() async throws {
        var config = SWIMConfiguration.development
        config.protocolPeriod = .milliseconds(15)
        config.pingTimeout = .milliseconds(20)
        config.indirectProbeCount = 0
        config.suspicionMultiplier = 5.0

        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        // Ack arrives right around the timeout boundary to race the timeout task.
        let transport = DelayedAckTransport(
            localAddress: "127.0.0.1:8000",
            localMemberID: localID,
            ackDelay: .milliseconds(20),
            ackEnabled: true
        )
        let instance = SWIMInstance(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )

        // Let many probe periods run so ack/timeout race repeatedly. A double
        // resume of a CheckedContinuation would crash the process here.
        try await Task.sleep(for: .milliseconds(400))

        // The member is in a well-defined state (alive or suspect/dead), and we
        // did not crash — that proves exactly-once resume across the race.
        let peer = await instance.members.first { $0.id == peerID }
        #expect(peer != nil, "Peer should remain tracked")
        #expect(transport.pingCount > 1, "Multiple probes should have raced ack vs timeout")

        try await instance.shutdown()
        transport.finish()
    }

    @Test("No ack at all eventually marks the member suspect (timeout path, not silent alive)", .timeLimit(.minutes(1)))
    func noAckMarksSuspect() async throws {
        var config = SWIMConfiguration.development
        config.protocolPeriod = .milliseconds(20)
        config.pingTimeout = .milliseconds(10)
        config.indirectProbeCount = 0
        config.suspicionMultiplier = 20.0

        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let transport = DelayedAckTransport(
            localAddress: "127.0.0.1:8000",
            localMemberID: localID,
            ackDelay: .milliseconds(0),
            ackEnabled: false  // never ack
        )
        let instance = SWIMInstance(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )

        // Wait until the timeout path drives the member to suspect. A regression
        // that treated "missing entry" as alive would keep it alive forever.
        let deadline = ContinuousClock.now + .milliseconds(500)
        var becameSuspectOrDead = false
        while ContinuousClock.now < deadline {
            if let s = await instance.members.first(where: { $0.id == peerID })?.status, s != .alive {
                becameSuspectOrDead = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(becameSuspectOrDead, "An unanswered probe must NOT be treated as a silent ack")

        try await instance.shutdown()
        transport.finish()
    }

    // MARK: - Join failures (finding #9)

    @Test("Join with only-self seeds throws joinFailed", .timeLimit(.minutes(1)))
    func joinOnlySelfSeedsFails() async throws {
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let instance = SWIMInstance(localMember: Member(id: localID), config: .development, transport: transport)
        await instance.start()

        await #expect(throws: SWIMError.self) {
            // Only seed is ourselves: no peer is ever contacted.
            try await instance.join(seeds: [localID])
        }

        // And nothing was sent.
        #expect(transport.getSentMessages().isEmpty, "Only-self join must not contact anyone")

        try await instance.shutdown()
    }

    @Test("Join with all-unreachable seeds surfaces the error", .timeLimit(.minutes(1)))
    func joinAllUnreachableSeedsFails() async throws {
        // LoopbackTransport with no connected peers makes every send throw.
        let transport = LoopbackTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        transport.setLocalMemberID(localID)
        let instance = SWIMInstance(localMember: Member(id: localID), config: .development, transport: transport)
        await instance.start()

        let unreachable = [
            MemberID(id: "seedA", address: "127.0.0.1:9001"),
            MemberID(id: "seedB", address: "127.0.0.1:9002"),
        ]

        await #expect(throws: SWIMError.self) {
            try await instance.join(seeds: unreachable)
        }

        try await instance.shutdown()
        transport.finish()
    }
}
