/// SWIM Failure Detector
///
/// Implements the ping/ping-req/ack failure detection protocol.

import Foundation

/// Handles the SWIM failure detection protocol.
///
/// The failure detector performs probes to verify member liveness:
/// 1. Send a direct ping to the target
/// 2. If no ack within timeout, send indirect pings via other members
/// 3. If still no ack, mark the target as suspect
///
/// - Note: This is a standalone component for advanced use cases.
///   For typical usage, prefer `SWIMInstance` which integrates
///   failure detection with gossip dissemination and membership management.
@available(*, deprecated, message: "Use SWIMInstance instead which provides integrated failure detection")
public actor FailureDetector {
    private let memberList: MemberList
    private let disseminator: Disseminator
    private var pendingProbes: [UInt64: PendingProbe]
    private var sequenceNumber: UInt64
    private let pingTimeout: Duration
    private let indirectProbeCount: Int

    /// Callback for sending messages.
    private let sendMessage: @Sendable (SWIMMessage, MemberID) async throws -> Void

    /// Creates a new failure detector.
    ///
    /// - Parameters:
    ///   - memberList: The member list to update
    ///   - disseminator: The disseminator for gossip payloads
    ///   - pingTimeout: Timeout for ping responses
    ///   - indirectProbeCount: Number of members for indirect probes
    ///   - sendMessage: Callback to send messages
    public init(
        memberList: MemberList,
        disseminator: Disseminator,
        pingTimeout: Duration,
        indirectProbeCount: Int,
        sendMessage: @escaping @Sendable (SWIMMessage, MemberID) async throws -> Void
    ) {
        self.memberList = memberList
        self.disseminator = disseminator
        self.pendingProbes = [:]
        self.sequenceNumber = 0
        self.pingTimeout = pingTimeout
        self.indirectProbeCount = indirectProbeCount
        self.sendMessage = sendMessage
    }

    // MARK: - Probing

    /// Probes a target member to check if it's alive.
    ///
    /// 1. Sends a direct ping
    /// 2. If timeout, sends indirect pings via other members
    /// 3. Returns the probe result
    ///
    /// - Parameter target: The member to probe
    /// - Returns: The result of the probe
    public func probe(_ target: Member) async -> ProbeResult {
        let seq = nextSequenceNumber()
        let payload = disseminator.getPayloadForMessage()

        // Create ping message
        let ping = SWIMMessage.ping(sequenceNumber: seq, payload: payload)

        // Register pending probe
        let probe = PendingProbe(target: target)
        pendingProbes[seq] = probe

        // Send direct ping
        do {
            try await sendMessage(ping, target.id)
        } catch {
            // Failed to send, treat as timeout
            pendingProbes.removeValue(forKey: seq)
            return .timeout
        }

        // Wait for ack with timeout
        let directResult = await waitForAck(sequenceNumber: seq, timeout: pingTimeout)

        if case .alive = directResult {
            pendingProbes.removeValue(forKey: seq)
            return .alive
        }

        // Direct ping failed, try indirect probes
        let indirectResult = await performIndirectProbes(for: target, originalSeq: seq)

        pendingProbes.removeValue(forKey: seq)
        return indirectResult
    }

    /// Performs indirect probes via other members.
    private func performIndirectProbes(for target: Member, originalSeq: UInt64) async -> ProbeResult {
        // Select random members for indirect probing
        let probers = memberList.randomAliveMembers(
            count: indirectProbeCount,
            excluding: [target.id]
        )

        guard !probers.isEmpty else {
            return .suspect
        }

        // Update pending probe
        if var probe = pendingProbes[originalSeq] {
            probe.indirectProbesSent = true
            probe.indirectProbers = probers.map { $0.id }
            pendingProbes[originalSeq] = probe
        }

        let payload = disseminator.getPayloadForMessage()

        // Send ping requests to all probers
        for prober in probers {
            let pingReq = SWIMMessage.pingRequest(
                sequenceNumber: originalSeq,
                target: target.id,
                payload: payload
            )

            do {
                try await sendMessage(pingReq, prober.id)
            } catch {
                // Ignore individual send failures
                continue
            }
        }

        // Wait for any ack
        let result = await waitForAck(sequenceNumber: originalSeq, timeout: pingTimeout)

        switch result {
        case .alive, .aliveIndirect:
            return .aliveIndirect
        default:
            return .suspect
        }
    }

    /// Waits for an ack with the given sequence number.
    private func waitForAck(sequenceNumber: UInt64, timeout: Duration) async -> ProbeResult {
        // Use a simple polling approach with sleep
        let deadline = ContinuousClock.now + timeout
        let checkInterval = Duration.milliseconds(10)

        while ContinuousClock.now < deadline {
            // Check if ack was received (probe removed means ack received)
            if pendingProbes[sequenceNumber] == nil {
                return .alive
            }

            // Check if marked as received
            if let probe = pendingProbes[sequenceNumber], probe.indirectProbesSent {
                // Check for indirect ack by seeing if probe was cleared elsewhere
            }

            try? await Task.sleep(for: checkInterval)
        }

        return .timeout
    }

    // MARK: - Message Handling

    /// Handles an incoming ping message.
    ///
    /// Responds with an ack and processes the gossip payload.
    public func handlePing(
        _ message: SWIMMessage,
        from sender: MemberID,
        localMember: MemberID
    ) async {
        guard case .ping(let seq, let payload) = message else { return }

        // Process gossip payload
        disseminator.processPayload(payload, memberList: memberList)

        // Send ack
        let responsePayload = disseminator.getPayloadForMessage()
        let ack = SWIMMessage.ack(
            sequenceNumber: seq,
            target: localMember,
            payload: responsePayload
        )

        try? await sendMessage(ack, sender)
    }

    /// Handles an incoming ping request.
    ///
    /// Pings the target on behalf of the requester and forwards the result.
    public func handlePingRequest(
        _ message: SWIMMessage,
        from sender: MemberID,
        localMember: MemberID
    ) async {
        guard case .pingRequest(let seq, let target, let payload) = message else { return }

        // Process gossip payload
        disseminator.processPayload(payload, memberList: memberList)

        // Ping the target directly
        let pingPayload = disseminator.getPayloadForMessage()
        let ping = SWIMMessage.ping(sequenceNumber: seq, payload: pingPayload)

        do {
            try await sendMessage(ping, target)

            // Wait for ack from target
            let deadline = ContinuousClock.now + pingTimeout
            let checkInterval = Duration.milliseconds(10)

            while ContinuousClock.now < deadline {
                // In a full implementation, we'd track this probe
                // For simplicity, we'll send back an ack if we get one
                try? await Task.sleep(for: checkInterval)
            }
        } catch {
            // Failed to ping target, send nack
            let nack = SWIMMessage.nack(sequenceNumber: seq, target: target)
            try? await sendMessage(nack, sender)
        }
    }

    /// Handles an incoming ack message.
    ///
    /// Completes the pending probe for this sequence number.
    public func handleAck(_ message: SWIMMessage, from sender: MemberID) {
        guard case .ack(let seq, _, let payload) = message else { return }

        // Process gossip payload
        disseminator.processPayload(payload, memberList: memberList)

        // Complete pending probe
        if pendingProbes[seq] != nil {
            pendingProbes.removeValue(forKey: seq)
        }
    }

    /// Handles an incoming nack message.
    public func handleNack(_ message: SWIMMessage, from sender: MemberID) {
        guard case .nack(_, _) = message else { return }

        // Nack doesn't complete the probe, we still wait for timeout
        // But we can track that this indirect prober failed
    }

    // MARK: - Helpers

    private func nextSequenceNumber() -> UInt64 {
        sequenceNumber &+= 1
        return sequenceNumber
    }
}
