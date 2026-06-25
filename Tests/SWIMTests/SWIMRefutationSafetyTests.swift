/// SWIM Refutation Safety Tests
///
/// End-to-end tests for the core SWIM safety property at the instance level:
/// once a suspicion is refuted (via gossiped alive+higher incarnation or via the
/// peer's own gossip), the running suspicion timer must be cancelled so the
/// member is never declared dead after the timeout elapses.

import Foundation
import Synchronization
import Testing
@testable import SWIM

@Suite("SWIM Refutation Safety Tests")
struct SWIMRefutationSafetyTests {

    /// A transport that initially never acks (forcing the target into suspicion)
    /// but can be switched to ack future pings. After a refutation we enable
    /// acking so re-probes succeed; this isolates the test to the *original*
    /// suspicion timer that must have been cancelled by the refutation.
    private final class SilentTransport: SWIMTransport, Sendable {
        let localAddress: String
        let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>
        private let continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation
        private let acking: Mutex<Bool>

        init(localAddress: String) {
            self.localAddress = localAddress
            self.acking = Mutex(false)
            var cont: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
            self.incomingMessages = AsyncStream { cont = $0 }
            self.continuation = cont
        }

        /// Enables acking of future pings (the target now responds).
        func enableAcking() {
            acking.withLock { $0 = true }
        }

        func send(_ message: SWIMMessage, to member: MemberID) async throws {
            guard case .ping(let seq, _) = message else { return }
            guard acking.withLock({ $0 }) else { return }
            // Respond with an ack from the pinged member so re-probes succeed.
            continuation.yield((.ack(sequenceNumber: seq, target: member, payload: .empty), member))
        }

        func receive(_ message: SWIMMessage, from sender: MemberID) {
            continuation.yield((message, sender))
        }

        func finish() {
            continuation.finish()
        }
    }

    /// Builds a config that enters suspicion quickly and keeps a long suspicion
    /// timeout so a refutation lands well inside the kill window. We probe only
    /// once (then stop) by giving a very long protocol period, so the only
    /// suspicion timer is the one we then refute.
    private func refutationConfig() -> SWIMConfiguration {
        var config = SWIMConfiguration.development
        config.protocolPeriod = .milliseconds(20)
        config.pingTimeout = .milliseconds(10)
        config.indirectProbeCount = 0
        // suspicionTimeout(memberCount: 2) = log(2) * suspicionMultiplier * period.
        // With multiplier 30 and period 20ms => ~415ms kill window to refute within.
        config.suspicionMultiplier = 30.0
        config.probeSelectionStrategy = .roundRobin
        return config
    }

    /// Polls for `duration`, returning true if the member is ever observed dead.
    private func everBecomesDead<Transport: SWIMTransport, Clock: SWIMClock>(
        _ instance: SWIMCluster<Transport, Clock>,
        target: MemberID,
        within duration: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if await instance.members.first(where: { $0.id == target })?.status == .dead {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitUntilSuspect<Transport: SWIMTransport, Clock: SWIMClock>(
        _ instance: SWIMCluster<Transport, Clock>,
        target: MemberID,
        timeout: Duration = .milliseconds(800)
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let members = await instance.members
            if members.first(where: { $0.id == target })?.status == .suspect {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("Gossiped alive+higher incarnation cancels the pending kill", .timeLimit(.minutes(1)))
    func gossipedRecoveryCancelsKill() async throws {
        let transport = SilentTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(
            localMember: Member(id: localID),
            config: refutationConfig(),
            transport: transport
        )
        await instance.start()

        // Introduce a peer the instance will probe; the probe will time out.
        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        let introducer = MemberID(id: "node3", address: "127.0.0.1:8002")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: introducer
        )

        // Wait until the peer is suspected by the local probe failure.
        let becameSuspect = try await waitUntilSuspect(instance, target: peerID)
        #expect(becameSuspect, "Peer should become suspect after probe timeout")

        // Refute via gossiped alive at a HIGHER incarnation. This transitions the
        // peer suspect -> alive and must cancel the running suspicion timer.
        transport.receive(
            .ping(sequenceNumber: 2, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, status: .alive, incarnation: Incarnation(value: 2)))
            ])),
            from: introducer
        )
        // Enable acking so re-probes succeed and the peer is not driven into a
        // fresh, unrelated suspicion; this isolates the original timer.
        transport.enableAcking()

        // Give the recovery a moment to process.
        try await Task.sleep(for: .milliseconds(30))
        let afterRefute = await instance.members.first { $0.id == peerID }
        #expect(afterRefute?.status == .alive, "Gossiped recovery must bring the peer back to alive")

        // Wait well past the original suspicion timeout. If the original timer
        // was not cancelled it would fire markDead during this window.
        let died = try await everBecomesDead(instance, target: peerID, within: .milliseconds(600))
        #expect(!died, "Refuted member must NOT be marked dead after the suspicion timeout")

        try await instance.shutdown()
        transport.finish()
    }

    @Test("Peer self-refutation gossip cancels the pending kill", .timeLimit(.minutes(1)))
    func selfRefutationGossipCancelsKill() async throws {
        // Models the peer refuting our suspicion by gossiping its own
        // alive+higher incarnation (which reaches us as a normal gossip update
        // about that peer).
        let transport = SilentTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(
            localMember: Member(id: localID),
            config: refutationConfig(),
            transport: transport
        )
        await instance.start()

        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 4)))
            ])),
            from: peerID
        )

        let becameSuspect = try await waitUntilSuspect(instance, target: peerID)
        #expect(becameSuspect, "Peer should become suspect after probe timeout")

        // The peer itself refutes: gossips its own alive state with a higher
        // incarnation. Delivered as a ping carrying that update.
        transport.receive(
            .ping(sequenceNumber: 2, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, status: .alive, incarnation: Incarnation(value: 5)))
            ])),
            from: peerID
        )
        transport.enableAcking()

        try await Task.sleep(for: .milliseconds(30))
        #expect(await instance.members.first { $0.id == peerID }?.status == .alive)

        // Wait past the suspicion timeout; the original timer must not fire.
        let died = try await everBecomesDead(instance, target: peerID, within: .milliseconds(600))
        #expect(!died, "Self-refuted member must NOT be marked dead after the suspicion timeout")

        try await instance.shutdown()
        transport.finish()
    }

    @Test("Unrefuted suspect is still marked dead after the timeout", .timeLimit(.minutes(1)))
    func unrefutedSuspectIsKilled() async throws {
        // Control test: with no refutation, the suspicion timer must still fire,
        // confirming the refutation tests above prove cancellation (not a dead
        // timer).
        var config = refutationConfig()
        // Shorter suspicion window so the kill happens quickly.
        config.suspicionMultiplier = 3.0  // ~42ms window
        let transport = SilentTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(
            localMember: Member(id: localID),
            config: config,
            transport: transport
        )
        await instance.start()

        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )

        // Wait long enough for: probe timeout -> suspect -> suspicion timeout -> dead.
        let deadline = ContinuousClock.now + .milliseconds(800)
        var isDead = false
        while ContinuousClock.now < deadline {
            if await instance.members.first(where: { $0.id == peerID })?.status == .dead {
                isDead = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(isDead, "An unrefuted suspect must eventually be marked dead")

        try await instance.shutdown()
        transport.finish()
    }
}
