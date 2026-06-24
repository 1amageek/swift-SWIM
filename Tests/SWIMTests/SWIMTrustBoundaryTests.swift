/// SWIM Trust Boundary Tests
///
/// Tests for the explicit trust boundary on unauthenticated gossip: forged
/// incarnation jumps and table-overflow joins are rejected, an optional
/// authenticator rejects unverifiable datagrams, and self-refutation cannot be
/// permanently out-run by a forged incarnation.

import Foundation
import Testing
@testable import SWIM

@Suite("SWIM Trust Boundary Tests")
struct SWIMTrustBoundaryTests {

    /// Authenticator that accepts or rejects every message based on a fixed flag.
    private struct FixedAuthenticator: SWIMMessageAuthenticator {
        let accept: Bool
        func sign(message: SWIMMessage) throws -> [UInt8] { [] }
        func verify(message: SWIMMessage) -> Bool { accept }
    }

    private func collectError(
        from instance: SWIMCluster,
        matching predicate: @escaping @Sendable (SWIMError) -> Bool
    ) -> Task<Bool, Never> {
        Task {
            for await event in instance.events {
                if case .error(let error) = event, predicate(error) {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Forged incarnation jump (finding #5a)

    @Test("Forged incarnation jump beyond the bound is rejected by the instance", .timeLimit(.minutes(1)))
    func forgedJumpRejectedByInstance() async throws {
        var config = SWIMConfiguration.development
        config.maxIncarnationDelta = 8
        // Disable the protocol loop's own probing so this test isolates the
        // forged-gossip rejection (otherwise an unanswered local probe would
        // legitimately move the peer to suspect, which is unrelated).
        config.protocolPeriod = .seconds(3600)
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let errorTask = collectError(from: instance) { error in
            if case .protocolError(let msg) = error { return msg.contains("Rejected gossip") }
            return false
        }

        // First learn the peer at a low incarnation.
        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )
        try await Task.sleep(for: .milliseconds(30))

        // Now a forged huge incarnation that would mark the peer dead.
        transport.receive(
            .ping(sequenceNumber: 2, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, status: .dead, incarnation: Incarnation(value: 1_000_000)))
            ])),
            from: peerID
        )
        try await Task.sleep(for: .milliseconds(50))

        // The forged update must have been rejected: the peer is neither dead nor
        // promoted to the forged incarnation.
        let peer = await instance.members.first { $0.id == peerID }
        #expect(peer?.status != .dead, "Forged incarnation jump must not mark the peer dead")
        #expect(peer?.incarnation.value == 1, "Forged incarnation must not be adopted")

        try await instance.shutdown()
        let surfaced = await errorTask.value
        #expect(surfaced, "Rejection must be surfaced as an error event, not silently dropped")
    }

    // MARK: - Authenticator (finding #5b)

    @Test("With an authenticator configured, an unverifiable datagram is rejected", .timeLimit(.minutes(1)))
    func unverifiableDatagramRejected() async throws {
        var config = SWIMConfiguration.development
        config.authenticator = FixedAuthenticator(accept: false)
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let errorTask = collectError(from: instance) { error in
            if case .protocolError(let msg) = error { return msg.contains("unverifiable") }
            return false
        }

        // A forged ping that tries to introduce a peer. Verification fails, so
        // its gossip must never be applied.
        let peerID = MemberID(id: "attacker", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )
        try await Task.sleep(for: .milliseconds(50))

        let members = await instance.members
        #expect(!members.contains { $0.id == peerID }, "Unverifiable gossip must not be applied")

        try await instance.shutdown()
        #expect(await errorTask.value, "Rejection of an unverifiable datagram must be surfaced")
    }

    @Test("With an accepting authenticator, a verifiable datagram is processed", .timeLimit(.minutes(1)))
    func verifiableDatagramAccepted() async throws {
        var config = SWIMConfiguration.development
        config.authenticator = FixedAuthenticator(accept: true)
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let peerID = MemberID(id: "node2", address: "127.0.0.1:8001")
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: peerID, incarnation: Incarnation(value: 1)))
            ])),
            from: peerID
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(await instance.members.contains { $0.id == peerID }, "Verified gossip must be applied")

        try await instance.shutdown()
    }

    // MARK: - Member-table cap at the instance level (finding #7)

    @Test("Gossiping beyond the member-table cap is rejected by the instance", .timeLimit(.minutes(1)))
    func memberTableCapRejectedByInstance() async throws {
        var config = SWIMConfiguration.development
        config.maxMemberCount = 3  // includes the local member
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let errorTask = collectError(from: instance) { error in
            if case .protocolError(let msg) = error { return msg.contains("Rejected gossip") }
            return false
        }

        // Flood with more members than the cap allows.
        var updates: [MembershipUpdate] = []
        for i in 0..<10 {
            updates.append(MembershipUpdate(member: Member(id: MemberID(id: "ghost\(i)", address: "127.0.0.1:90\(i)"))))
        }
        transport.receive(.ping(sequenceNumber: 1, payload: GossipPayload(updates: updates)), from: localID)
        try await Task.sleep(for: .milliseconds(60))

        let count = await instance.members.count
        #expect(count <= 3, "Member table must not grow past the configured cap (was \(count))")

        try await instance.shutdown()
        #expect(await errorTask.value, "Overflow joins must be surfaced as rejections")
    }

    @Test("Pinging beyond the member-table cap from spoofed sources is rejected by the instance", .timeLimit(.minutes(1)))
    func memberTableCapHoldsViaPingPath() async throws {
        var config = SWIMConfiguration.development
        config.maxMemberCount = 3  // includes the local member
        // Disable the protocol loop's own probing so this test isolates the
        // ping-sender admission path.
        config.protocolPeriod = .seconds(3600)
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        let instance = SWIMCluster(localMember: Member(id: localID), config: config, transport: transport)
        await instance.start()

        let errorTask = collectError(from: instance) { error in
            if case .protocolError(let msg) = error { return msg.contains("Rejected ping sender") }
            return false
        }

        // Flood the instance with pings from many distinct (spoofed) source
        // addresses, far exceeding the cap. Each carries an empty gossip payload,
        // so the only admission path exercised is the ping-sender admission in
        // handlePing.
        for i in 0..<50 {
            let spoofed = MemberID(id: "spoof\(i)", address: "127.0.0.1:9\(String(format: "%03d", i))")
            transport.receive(.ping(sequenceNumber: UInt64(i), payload: .empty), from: spoofed)
        }
        try await Task.sleep(for: .milliseconds(120))

        // The cap must hold via the ping path, mirroring the gossip-path cap test:
        // the member table must not grow past maxMemberCount regardless of how
        // many spoofed senders ping us.
        let count = await instance.members.count
        #expect(count <= 3, "Member table must not grow past the configured cap via the ping path (was \(count))")

        try await instance.shutdown()
        #expect(await errorTask.value, "Overflow ping-sender admissions must be surfaced as rejections")
    }

    // MARK: - Self-refutation against forged max incarnation (finding #3)

    @Test("Self-refutation against a forged max incarnation produces a strictly greater local incarnation", .timeLimit(.minutes(1)))
    func selfRefutationAgainstForgedMaxIncarnation() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        // Start at a modest local incarnation.
        let instance = SWIMCluster(
            localMember: Member(id: localID, incarnation: Incarnation(value: 3)),
            config: .development,
            transport: transport
        )
        await instance.start()

        // Attacker forges a near-max incarnation accusing us of being suspect.
        let forged = Incarnation(value: UInt64.max - 1)
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: localID, status: .suspect, incarnation: forged))
            ])),
            from: MemberID(id: "attacker", address: "127.0.0.1:8001")
        )
        try await Task.sleep(for: .milliseconds(60))

        let local = await instance.local
        // We must out-rank the forged accusation (max-based refutation), and the
        // result must be strictly greater than the forged value without wrapping.
        #expect(local.incarnation > forged, "Refutation must strictly out-rank the forged incarnation")
        #expect(local.incarnation.value == UInt64.max, "max-1 incremented saturates to max (no wrap to 0)")
        #expect(local.status == .alive)

        try await instance.shutdown()
    }

    @Test("Self-refutation never decreases the local incarnation", .timeLimit(.minutes(1)))
    func selfRefutationNeverDecreases() async throws {
        let transport = MockTransport(localAddress: "127.0.0.1:8000")
        let localID = MemberID(id: "node1", address: "127.0.0.1:8000")
        // Local incarnation is already high.
        let instance = SWIMCluster(
            localMember: Member(id: localID, incarnation: Incarnation(value: 100)),
            config: .development,
            transport: transport
        )
        await instance.start()

        // Accusation carries a lower-but-equal-or-higher incarnation than... here
        // exactly equal to local, which currently triggers refutation.
        transport.receive(
            .ping(sequenceNumber: 1, payload: GossipPayload(updates: [
                MembershipUpdate(member: Member(id: localID, status: .suspect, incarnation: Incarnation(value: 100)))
            ])),
            from: MemberID(id: "attacker", address: "127.0.0.1:8001")
        )
        try await Task.sleep(for: .milliseconds(60))

        let local = await instance.local
        #expect(local.incarnation.value == 101, "Refutation advances our own monotonic counter by one")
        #expect(local.incarnation.value >= 100, "Local incarnation must never decrease")

        try await instance.shutdown()
    }
}
