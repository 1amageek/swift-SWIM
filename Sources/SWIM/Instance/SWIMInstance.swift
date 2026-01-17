/// SWIM Instance
///
/// Main SWIM protocol instance that coordinates failure detection and gossip.

import Foundation

/// Main SWIM protocol instance.
///
/// This actor coordinates all SWIM protocol activities:
/// - Periodic failure detection probes
/// - Gossip dissemination
/// - Membership management
/// - Event emission
///
/// ## Usage
/// ```swift
/// let transport = MyTransport()
/// let swim = SWIMInstance(
///     localMember: Member(id: MemberID(id: "node1", address: "127.0.0.1:8000")),
///     config: .default,
///     transport: transport
/// )
///
/// await swim.start()
/// try await swim.join(seeds: [seedMemberID])
///
/// for await event in swim.events {
///     // Handle membership events
/// }
/// ```
public actor SWIMInstance {
    // MARK: - Properties

    private let config: SWIMConfiguration
    private let memberList: MemberList
    private let disseminator: Disseminator
    private let suspicionTimer: SuspicionTimer
    private let transport: any SWIMTransport

    private var localMember: Member
    private var protocolTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isRunning: Bool = false

    /// Pending probes awaiting ack responses.
    private var pendingProbes: [UInt64: PendingProbe] = [:]

    /// Sequence number generator for probes.
    private var sequenceNumber: UInt64 = 0

    private let eventContinuation: AsyncStream<SWIMEvent>.Continuation

    /// Stream of SWIM events.
    ///
    /// Subscribe to this stream to receive membership change notifications.
    /// This property is nonisolated since AsyncStream is Sendable and the
    /// stream is created during initialization and never mutated.
    public nonisolated let events: AsyncStream<SWIMEvent>

    /// Represents a pending probe awaiting ack.
    private struct PendingProbe {
        let target: MemberID
        let startTime: ContinuousClock.Instant
        var ackReceived: Bool = false
        var isIndirect: Bool = false
        /// For indirect probes: who requested this probe
        var requester: MemberID? = nil
    }

    // MARK: - Initialization

    /// Creates a new SWIM instance.
    ///
    /// - Parameters:
    ///   - localMember: The local member (this node)
    ///   - config: SWIM configuration
    ///   - transport: Transport for sending/receiving messages
    public init(
        localMember: Member,
        config: SWIMConfiguration = .default,
        transport: any SWIMTransport
    ) {
        self.localMember = localMember
        self.config = config
        self.transport = transport
        self.memberList = MemberList(members: [localMember])
        self.disseminator = Disseminator(
            maxPayloadSize: config.maxPayloadSize,
            disseminationLimit: config.disseminationLimit(memberCount: 1)
        )
        self.suspicionTimer = SuspicionTimer()

        // Create event stream
        var continuation: AsyncStream<SWIMEvent>.Continuation!
        self.events = AsyncStream<SWIMEvent> { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Starts the SWIM protocol.
    ///
    /// This begins the periodic failure detection loop and message receiving.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Start receiving messages
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }

        // Start protocol loop
        protocolTask = Task { [weak self] in
            guard let self else { return }
            await self.protocolLoop()
        }
    }

    /// Stops the SWIM protocol.
    ///
    /// This cancels the protocol loop and cleans up resources.
    public func stop() async {
        isRunning = false
        protocolTask?.cancel()
        receiveTask?.cancel()
        await suspicionTimer.cancelAll()
        eventContinuation.finish()
    }

    // MARK: - Membership

    /// Joins the cluster by contacting seed members.
    ///
    /// Sends a ping to each seed member to announce our presence
    /// and learn about other cluster members.
    ///
    /// - Parameter seeds: List of seed member IDs to contact
    /// - Throws: `SWIMError.joinFailed` if no seeds respond
    public func join(seeds: [MemberID]) async throws {
        guard !seeds.isEmpty else {
            throw SWIMError.joinFailed(reason: "No seed members provided")
        }

        var joinedAny = false
        var validSeeds = 0

        for seed in seeds {
            // Skip ourselves
            if seed == localMember.id { continue }

            validSeeds += 1

            // Add seed to member list
            let seedMember = Member(id: seed)
            memberList.update(seedMember)

            // Send ping to announce ourselves
            let payload = disseminator.getPayloadForMessage()
            let ping = SWIMMessage.ping(sequenceNumber: 0, payload: payload)

            do {
                try await transport.send(ping, to: seed)
                joinedAny = true
            } catch {
                // Ignore individual failures, try next seed
                continue
            }
        }

        // Fail if we couldn't contact ANY valid seed
        if !joinedAny && validSeeds > 0 {
            throw SWIMError.joinFailed(reason: "Could not contact any seed members")
        }
    }

    /// Leaves the cluster gracefully.
    ///
    /// Broadcasts a dead status for ourselves before stopping.
    public func leave() async {
        // Mark ourselves as dead
        localMember.status = .dead

        // Disseminate our departure
        let update = MembershipUpdate(member: localMember)
        disseminator.enqueue(update)

        // Send a few messages to propagate the update
        let targets = memberList.randomAliveMembers(count: 3, excluding: [localMember.id])
        let payload = GossipPayload(updates: [update])
        let ping = SWIMMessage.ping(sequenceNumber: 0, payload: payload)

        for target in targets {
            try? await transport.send(ping, to: target.id)
        }

        eventContinuation.yield(.memberLeft(localMember.id))

        await stop()
    }

    /// Returns all current members.
    public var members: [Member] {
        memberList.allMembers
    }

    /// Returns the count of alive members.
    public var aliveCount: Int {
        memberList.aliveCount
    }

    /// Returns the local member.
    public var local: Member {
        localMember
    }

    // MARK: - Protocol Loop

    private func protocolLoop() async {
        while isRunning && !Task.isCancelled {
            await runProtocolPeriod()

            do {
                try await Task.sleep(for: config.protocolPeriod)
            } catch {
                break
            }
        }
    }

    private func runProtocolPeriod() async {
        // Select a random member to probe
        guard let target = memberList.randomProbableTarget(excluding: [localMember.id]) else {
            return  // No members to probe
        }

        // Probe the target
        let result = await probe(target)

        switch result {
        case .alive, .aliveIndirect:
            // Member is alive, nothing to do
            break

        case .suspect:
            // Mark as suspect and start suspicion timer
            await markSuspect(target)

        case .dead:
            // Already handled by suspicion timer
            break

        case .timeout:
            // Treat as suspect
            await markSuspect(target)
        }
    }

    // MARK: - Probing

    private func nextSequenceNumber() -> UInt64 {
        sequenceNumber &+= 1
        return sequenceNumber
    }

    private func probe(_ target: Member) async -> ProbeResult {
        let seq = nextSequenceNumber()
        let payload = disseminator.getPayloadForMessage()
        let ping = SWIMMessage.ping(sequenceNumber: seq, payload: payload)

        // Register pending probe
        pendingProbes[seq] = PendingProbe(
            target: target.id,
            startTime: .now
        )

        // Send direct ping
        do {
            try await transport.send(ping, to: target.id)
        } catch {
            pendingProbes.removeValue(forKey: seq)
            return .timeout
        }

        // Wait for ack with polling
        let result = await waitForAck(sequenceNumber: seq, timeout: config.pingTimeout)

        if result == .alive {
            pendingProbes.removeValue(forKey: seq)
            return .alive
        }

        // Direct ping failed, try indirect probes
        let indirectResult = await indirectProbe(target, originalSeq: seq)

        pendingProbes.removeValue(forKey: seq)
        return indirectResult
    }

    private func waitForAck(sequenceNumber: UInt64, timeout: Duration) async -> ProbeResult {
        let deadline = ContinuousClock.now + timeout
        let checkInterval = Duration.milliseconds(5)

        while ContinuousClock.now < deadline {
            // Check if ack was received
            if let probe = pendingProbes[sequenceNumber], probe.ackReceived {
                return .alive
            }

            // Probe was removed (completed elsewhere)
            if pendingProbes[sequenceNumber] == nil {
                return .alive
            }

            try? await Task.sleep(for: checkInterval)
        }

        return .timeout
    }

    private func indirectProbe(_ target: Member, originalSeq: UInt64) async -> ProbeResult {
        let probers = memberList.randomAliveMembers(
            count: config.indirectProbeCount,
            excluding: [localMember.id, target.id]
        )

        guard !probers.isEmpty else {
            return .suspect
        }

        let payload = disseminator.getPayloadForMessage()

        // Mark probe as indirect
        if var probe = pendingProbes[originalSeq] {
            probe.isIndirect = true
            pendingProbes[originalSeq] = probe
        }

        for prober in probers {
            let pingReq = SWIMMessage.pingRequest(
                sequenceNumber: originalSeq,
                target: target.id,
                payload: payload
            )

            try? await transport.send(pingReq, to: prober.id)
        }

        // Wait for any indirect ack
        let result = await waitForAck(sequenceNumber: originalSeq, timeout: config.pingTimeout)

        if result == .alive {
            return .aliveIndirect
        }

        return .suspect
    }

    // MARK: - State Management

    private func markSuspect(_ member: Member) async {
        guard member.status == .alive else { return }

        if let change = memberList.markSuspect(member.id, incarnation: member.incarnation) {
            // Emit event
            if case .statusChanged(let updated, _) = change {
                eventContinuation.yield(.memberSuspected(updated))
            }

            // Disseminate
            if let updatedMember = memberList.member(for: member.id) {
                disseminator.enqueue(member: updatedMember)
            }

            // Start suspicion timer
            let timeout = config.suspicionTimeout(memberCount: memberList.count)
            await suspicionTimer.startSuspicion(
                for: member.id,
                timeout: timeout
            ) { [weak self] in
                Task { [weak self] in
                    await self?.markDead(member.id)
                }
            }
        }
    }

    private func markDead(_ memberID: MemberID) async {
        guard let member = memberList.member(for: memberID) else { return }
        guard member.status != .dead else { return }

        if let change = memberList.markDead(memberID, incarnation: member.incarnation) {
            // Emit event
            if case .statusChanged(let updated, _) = change {
                eventContinuation.yield(.memberFailed(updated))
            }

            // Disseminate
            if let updatedMember = memberList.member(for: memberID) {
                disseminator.enqueue(member: updatedMember)
            }
        }
    }

    // MARK: - Message Handling

    private func receiveLoop() async {
        for await (message, sender) in transport.incomingMessages {
            await handleMessage(message, from: sender)
        }
    }

    private func handleMessage(_ message: SWIMMessage, from sender: MemberID) async {
        // Process gossip payload first
        if let payload = message.payload {
            processPayload(payload)
        }

        switch message {
        case .ping(let seq, _):
            await handlePing(sequenceNumber: seq, from: sender)

        case .pingRequest(let seq, let target, _):
            await handlePingRequest(sequenceNumber: seq, target: target, from: sender)

        case .ack(let seq, let target, _):
            await handleAck(sequenceNumber: seq, target: target, from: sender)

        case .nack:
            // Ignore nacks for now
            break
        }
    }

    private func handlePing(sequenceNumber: UInt64, from sender: MemberID) async {
        // Add sender to member list if new
        let senderMember = Member(id: sender)
        if let change = memberList.update(senderMember) {
            if case .joined(let member) = change {
                eventContinuation.yield(.memberJoined(member))
            }
        }

        // Send ack
        let payload = disseminator.getPayloadForMessage()
        let ack = SWIMMessage.ack(
            sequenceNumber: sequenceNumber,
            target: localMember.id,
            payload: payload
        )

        try? await transport.send(ack, to: sender)
    }

    private func handlePingRequest(
        sequenceNumber: UInt64,
        target: MemberID,
        from sender: MemberID
    ) async {
        // Create a new sequence number for our probe to the target
        let probeSeq = nextSequenceNumber()

        // Register pending probe with requester info for forwarding
        pendingProbes[probeSeq] = PendingProbe(
            target: target,
            startTime: .now,
            isIndirect: true,
            requester: sender
        )

        // Ping the target on behalf of the requester
        let payload = disseminator.getPayloadForMessage()
        let ping = SWIMMessage.ping(sequenceNumber: probeSeq, payload: payload)

        do {
            try await transport.send(ping, to: target)
        } catch {
            // Failed to send, send nack immediately
            pendingProbes.removeValue(forKey: probeSeq)
            let nack = SWIMMessage.nack(sequenceNumber: sequenceNumber, target: target)
            try? await transport.send(nack, to: sender)
            return
        }

        // Wait for ack from target
        let result = await waitForAck(sequenceNumber: probeSeq, timeout: config.pingTimeout)

        pendingProbes.removeValue(forKey: probeSeq)

        if result == .alive {
            // Forward ack back to original requester
            let ackPayload = disseminator.getPayloadForMessage()
            let ack = SWIMMessage.ack(
                sequenceNumber: sequenceNumber,  // Use original seq for requester
                target: target,
                payload: ackPayload
            )
            try? await transport.send(ack, to: sender)
        } else {
            // Target didn't respond, send nack
            let nack = SWIMMessage.nack(sequenceNumber: sequenceNumber, target: target)
            try? await transport.send(nack, to: sender)
        }
    }

    private func handleAck(
        sequenceNumber: UInt64,
        target: MemberID,
        from sender: MemberID
    ) async {
        // Mark pending probe as received (if exists)
        if var probe = pendingProbes[sequenceNumber] {
            // Validate that the ack is from the expected target
            if probe.target == sender {
                probe.ackReceived = true
                pendingProbes[sequenceNumber] = probe
            }
        }

        // Cancel suspicion for the sender
        await suspicionTimer.cancelSuspicion(for: sender)

        // Mark sender as alive if it was suspect
        if let member = memberList.member(for: sender), member.status == .suspect {
            if let change = memberList.markAlive(sender, incarnation: member.incarnation.incremented()) {
                if case .statusChanged(let updated, _) = change {
                    eventContinuation.yield(.memberRecovered(updated))
                    disseminator.enqueue(member: updated)
                }
            }
        }
    }

    private func processPayload(_ payload: GossipPayload) {
        for update in payload.updates {
            // Check if this is about us
            if update.memberID == localMember.id {
                handleUpdateAboutSelf(update)
                continue
            }

            let member = update.toMember()
            if let change = memberList.update(member) {
                switch change {
                case .joined(let m):
                    eventContinuation.yield(.memberJoined(m))
                case .statusChanged(let m, let from):
                    switch m.status {
                    case .alive:
                        if from == .suspect {
                            eventContinuation.yield(.memberRecovered(m))
                        }
                    case .suspect:
                        eventContinuation.yield(.memberSuspected(m))
                    case .dead:
                        eventContinuation.yield(.memberFailed(m))
                    }
                case .left(let id):
                    eventContinuation.yield(.memberLeft(id))
                }

                // Re-disseminate
                disseminator.enqueue(update)
            }
        }
    }

    private func handleUpdateAboutSelf(_ update: MembershipUpdate) {
        // If someone says we're suspect or dead, refute by incrementing incarnation
        if update.status != .alive && update.incarnation >= localMember.incarnation {
            localMember.incarnation = update.incarnation.incremented()
            eventContinuation.yield(.incarnationIncremented(localMember.incarnation))

            // Disseminate our new incarnation
            disseminator.enqueue(member: localMember)
            memberList.update(localMember)
        }
    }
}
