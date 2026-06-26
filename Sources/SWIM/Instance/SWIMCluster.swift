/// SWIM Cluster
///
/// Tier-1 orchestration actor that coordinates failure detection and gossip.

import _Concurrency
import SWIMWire

/// The SWIM cluster orchestration actor.
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
/// let swim = SWIMCluster(
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
///
/// Generic over the injected ``SWIMTransport`` and ``SWIMClock`` so the actor is
/// Embedded-clean: `any SWIMTransport` / `any SWIMClock` existentials are rejected
/// under Embedded Swift, whereas concrete `Transport` / `Clock` type parameters
/// monomorphize cleanly. On host, ``SystemSWIMClock`` is the conventional `Clock`;
/// callers select it via ``init(localMember:config:transport:)``.
public actor SWIMCluster<Transport: SWIMTransport, Clock: SWIMClock> {
    // MARK: - Properties

    private let config: SWIMConfiguration
    private let memberList: MemberList<Clock>
    private let disseminator: Disseminator
    private let suspicionTimer: SuspicionTimer<Clock>
    /// Transport for sending/receiving messages.
    private let transport: Transport
    /// The monotonic clock + sleep seam that drives the protocol period, ping
    /// timeout, and suspicion timeout — instead of `Task.sleep(for:)` +
    /// `ContinuousClock`, both unavailable under Embedded.
    private let clock: Clock

    private var localMember: Member
    private var protocolTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isRunning: Bool = false

    /// Pending probes awaiting ack responses, keyed by sequence number.
    ///
    /// Each entry holds a single continuation that is resumed exactly once —
    /// either by `handleAck` (with `.alive`) or by its dedicated timeout task
    /// (with `.timeout`). On shutdown all pending waiters are resumed with
    /// `.timeout` so no continuation is leaked.
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
    ///
    /// The continuation is resumed exactly once and then the entry is removed,
    /// guaranteeing exactly-once resume across the ack and timeout paths.
    private final class PendingProbe {
        let target: MemberID
        let isIndirect: Bool
        /// For indirect probes: who requested this probe
        let requester: MemberID?
        /// The waiter to resume; set to nil once resumed (exactly-once guard).
        var continuation: CheckedContinuation<ProbeResult, Never>?
        /// The single timeout task that resumes with `.timeout` if no ack arrives.
        var timeoutTask: Task<Void, Never>?

        init(
            target: MemberID,
            isIndirect: Bool = false,
            requester: MemberID? = nil
        ) {
            self.target = target
            self.isIndirect = isIndirect
            self.requester = requester
            self.continuation = nil
            self.timeoutTask = nil
        }
    }

    // MARK: - Initialization

    /// Creates a new SWIM instance driven by the given clock seam.
    ///
    /// - Parameters:
    ///   - localMember: The local member (this node)
    ///   - config: SWIM configuration
    ///   - transport: Transport for sending/receiving messages
    ///   - clock: The monotonic clock + sleep seam that drives all timers.
    public init(
        localMember: Member,
        config: SWIMConfiguration = .default,
        transport: Transport,
        clock: Clock
    ) {
        self.localMember = localMember
        self.config = config
        self.transport = transport
        self.clock = clock
        self.memberList = MemberList(members: [localMember], clock: clock)
        self.disseminator = Disseminator(
            maxPayloadSize: config.maxPayloadSize,
            disseminationLimit: config.disseminationLimit(memberCount: 1)
        )
        self.suspicionTimer = SuspicionTimer(clock: clock)

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

        // Start receiving messages.
        //
        // Capture: `weak self` on host (so an un-shut-down cluster can still
        // deinit); Embedded has no weak references, so `self` is captured
        // strongly. The retain cycle this creates is broken by `shutdown()`,
        // which cancels both stored tasks — `receiveLoop`'s `for await` returns
        // on cancellation and `protocolLoop` checks `Task.isCancelled` — so the
        // captures release and the actor can deinit.
        #if hasFeature(Embedded)
        receiveTask = Task { await self.receiveLoop() }
        protocolTask = Task { await self.protocolLoop() }
        #else
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        protocolTask = Task { [weak self] in
            guard let self else { return }
            await self.protocolLoop()
        }
        #endif
    }

    /// Shuts down the SWIM protocol.
    ///
    /// This cancels the protocol loop and cleans up resources.
    public func shutdown() async throws {
        isRunning = false
        protocolTask?.cancel()
        receiveTask?.cancel()
        await suspicionTimer.cancelAll()

        // Resume every pending probe waiter so no continuation is leaked. A
        // probe interrupted by shutdown reports `.timeout` (failure), never a
        // silent success.
        let pending = pendingProbes
        pendingProbes.removeAll()
        for (_, probe) in pending {
            probe.timeoutTask?.cancel()
            if let continuation = probe.continuation {
                probe.continuation = nil
                continuation.resume(returning: .timeout)
            }
        }

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
        // Collect formatted failure details (not `any Error`, which is rejected
        // under Embedded). The caught error is the transport's typed/untyped error;
        // it is formatted into the detail string immediately.
        var sendErrorDetails: [String] = []

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
                try await send(ping, to: seed)
                joinedAny = true
            } catch {
                // Aggregate the failure and try the next seed.
                sendErrorDetails.append("\(seed.address): \(error)")
                continue
            }
        }

        // All seeds were ourselves: we contacted nobody. This is not success.
        guard validSeeds > 0 else {
            throw SWIMError.joinFailed(
                reason: "All provided seeds refer to the local member; no peer was contacted"
            )
        }

        // We had peers to contact but could reach none of them. Surface the
        // aggregated underlying errors instead of silently no-op'ing.
        if !joinedAny {
            let detail = sendErrorDetails.joined(separator: "; ")
            throw SWIMError.joinFailed(
                reason: "Could not contact any of \(validSeeds) seed member(s) [\(detail)]"
            )
        }
    }

    /// Leaves the cluster gracefully.
    ///
    /// Broadcasts a dead status for ourselves before stopping.
    public func leave() async throws {
        // Mark ourselves as dead
        localMember.status = .dead

        // Disseminate our departure
        let update = MembershipUpdate(member: localMember)
        disseminator.enqueue(update)

        // Recompute the dissemination fan-out from the current cluster size so a
        // large cluster does not under-disseminate the departure. The fan-out is
        // bounded by the available alive members.
        let memberCount = memberList.count
        let fanOut = config.disseminationLimit(memberCount: memberCount)
        let targets = memberList.randomAliveMembers(count: fanOut, excluding: [localMember.id])
        let payload = GossipPayload(updates: [update])
        let ping = SWIMMessage.ping(sequenceNumber: 0, payload: payload)

        // Collect formatted failure details (not `any Error`; see `join`).
        var sendErrorDetails: [String] = []
        for target in targets {
            do {
                try await send(ping, to: target.id)
            } catch {
                sendErrorDetails.append("\(target.id.address): \(error)")
                continue
            }
        }

        eventContinuation.yield(.memberLeft(localMember.id))

        // Tear down regardless of send outcomes, but surface partial failures so
        // the caller knows the departure may not have fully propagated.
        try await shutdown()

        if !targets.isEmpty && sendErrorDetails.count == targets.count {
            let detail = sendErrorDetails.joined(separator: "; ")
            throw SWIMError.transportError(
                "Failed to propagate leave to any of \(targets.count) member(s) [\(detail)]"
            )
        }
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
        let periodNanos = config.protocolPeriod.swimNanos
        while isRunning && !Task.isCancelled {
            await runProtocolPeriod()

            // Park for one protocol period on the clock seam (not Task.sleep).
            let deadline = clock.monotonicNanos() &+ periodNanos
            do {
                try await clock.sleep(untilNanos: deadline)
            } catch {
                break
            }
        }
    }

    private func runProtocolPeriod() async {
        // Keep the dissemination fan-out in sync with the (possibly grown)
        // cluster size so each update is piggybacked enough times to reach
        // everyone. Recomputed every period because N changes over time.
        disseminator.updateDisseminationLimit(
            config.disseminationLimit(memberCount: memberList.count)
        )

        // Dead member garbage collection
        let removed = memberList.removeDeadMembers(olderThan: config.deadMemberRetention)
        for id in removed {
            eventContinuation.yield(.memberRemoved(id))
        }

        // Select probe target based on configured strategy
        let target: Member?
        switch config.probeSelectionStrategy {
        case .random:
            target = memberList.randomProbableTarget(excluding: [localMember.id])
        case .roundRobin:
            target = memberList.nextRoundRobinTarget(excluding: [localMember.id])
        }

        guard let target else {
            return  // No members to probe
        }

        // Probe the target
        let result = await probe(target)

        switch result {
        case .alive, .aliveIndirect:
            // Member is alive, nothing to do
            break

        case .transportFailure:
            // Local transport failed before the probe left this node.
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

        // Register pending probe before sending so an ack that races back is
        // never lost.
        let pending = PendingProbe(target: target.id)
        pendingProbes[seq] = pending

        // Send direct ping
        do {
            try await send(ping, to: target.id)
        } catch {
            // Local send failed: clean up and report timeout (failure), never a
            // silent success.
            pendingProbes.removeValue(forKey: seq)
            return .timeout
        }

        // Wait for ack (resumed exactly once by handleAck or the timeout task).
        let result = await waitForAck(sequenceNumber: seq, timeout: config.pingTimeout)

        if result == .alive {
            return .alive
        }

        // Direct ping failed, try indirect probes.
        return await indirectProbe(target, originalSeq: seq)
    }

    /// Awaits the result of the pending probe identified by `sequenceNumber`.
    ///
    /// The continuation is registered on the pending probe and resumed exactly
    /// once: either by `handleAck` (`.alive`) or by the dedicated timeout task
    /// (`.timeout`). A missing pending entry is treated as a failure
    /// (`.timeout`) — never a silent success — and shutdown resumes any
    /// outstanding waiter so the continuation cannot leak.
    private func waitForAck(sequenceNumber: UInt64, timeout: Duration) async -> ProbeResult {
        // If the entry is gone (e.g. already resolved/cleaned up), this is a
        // failure, not an implicit ack.
        guard let pending = pendingProbes[sequenceNumber] else {
            return .timeout
        }

        // Capture the deadline on the clock seam before suspending.
        let deadline = clock.monotonicNanos() &+ timeout.swimNanos
        let clock = self.clock

        return await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
            pending.continuation = continuation

            // Single timeout task: resumes with `.timeout` exactly once if no
            // ack arrives first. Cancellation of this task (on ack) is benign.
            // Capture is `weak self` on host; Embedded has no weak references, so
            // `self` is captured strongly — the task is short-lived (one sleep)
            // and is cancelled on ack/shutdown, so no lasting cycle.
            #if hasFeature(Embedded)
            pending.timeoutTask = Task {
                do {
                    try await clock.sleep(untilNanos: deadline)
                } catch {
                    // Cancelled (ack arrived first): the ack path already resumed.
                    return
                }
                await self.resolveProbe(sequenceNumber: sequenceNumber, result: .timeout)
            }
            #else
            pending.timeoutTask = Task { [weak self] in
                do {
                    try await clock.sleep(untilNanos: deadline)
                } catch {
                    // Cancelled (ack arrived first): the ack path already resumed.
                    return
                }
                await self?.resolveProbe(sequenceNumber: sequenceNumber, result: .timeout)
            }
            #endif
        }
    }

    /// Resolves the pending probe for `sequenceNumber` exactly once.
    ///
    /// Removes the entry, cancels its timeout task, and resumes its waiter (if
    /// any). Idempotent: a second call for an already-resolved sequence is a
    /// no-op, guaranteeing exactly-once resume across the ack and timeout paths.
    private func resolveProbe(sequenceNumber: UInt64, result: ProbeResult) {
        guard let pending = pendingProbes[sequenceNumber] else { return }
        pendingProbes.removeValue(forKey: sequenceNumber)
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        if let continuation = pending.continuation {
            pending.continuation = nil
            continuation.resume(returning: result)
        }
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

        // The direct-probe phase already resolved (and removed) the entry for
        // originalSeq. Re-register a fresh pending probe so the indirect ack —
        // which carries originalSeq — has a waiter to resume. Registered before
        // dispatch so a fast ack is never lost.
        let pending = PendingProbe(target: target.id, isIndirect: true)
        pendingProbes[originalSeq] = pending

        var dispatchedProbeCount = 0

        for prober in probers {
            let pingReq = SWIMMessage.pingRequest(
                sequenceNumber: originalSeq,
                target: target.id,
                payload: payload
            )

            do {
                try await send(pingReq, to: prober.id)
                dispatchedProbeCount += 1
            } catch {
                continue
            }
        }

        guard dispatchedProbeCount > 0 else {
            // No request left this node: clean up the waiter and report the
            // local transport failure explicitly.
            pendingProbes.removeValue(forKey: originalSeq)
            return .transportFailure
        }

        // Wait for any indirect ack (resumed exactly once).
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

            // Capture the incarnation observed at suspicion start. The kill path
            // requires this exact incarnation (and still-suspect status), so any
            // refutation in the meantime invalidates the pending kill.
            let suspectedIncarnation = member.incarnation
            let timeout = config.suspicionTimeout(memberCount: memberList.count)
            // The expiry callback hops back onto the actor to run the kill.
            // Capture is `weak self` on host; Embedded has no weak references, so
            // `self` is captured strongly. The callback only fires once (on
            // timeout) or never (on cancel), so it holds no lasting cycle.
            #if hasFeature(Embedded)
            await suspicionTimer.startSuspicion(
                for: member.id,
                incarnation: suspectedIncarnation,
                timeout: timeout
            ) { capturedIncarnation in
                Task {
                    await self.markDead(member.id, suspectedIncarnation: capturedIncarnation)
                }
            }
            #else
            await suspicionTimer.startSuspicion(
                for: member.id,
                incarnation: suspectedIncarnation,
                timeout: timeout
            ) { [weak self] capturedIncarnation in
                Task { [weak self] in
                    await self?.markDead(member.id, suspectedIncarnation: capturedIncarnation)
                }
            }
            #endif
        }
    }

    /// Kills a suspected member whose suspicion timeout expired without
    /// refutation.
    ///
    /// The kill only applies when the member is **still** `.suspect` at the
    /// **exact** `suspectedIncarnation` captured when suspicion started. Any
    /// refutation (status -> alive and/or incarnation bump) changes one of those,
    /// so `MemberList.markDead`'s strict precondition rejects the kill. This
    /// preserves the core safety property: a refuted member is never declared
    /// dead.
    private func markDead(_ memberID: MemberID, suspectedIncarnation: Incarnation) async {
        if let change = memberList.markDead(memberID, incarnation: suspectedIncarnation) {
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

    /// Cancels a member's pending suspicion kill on every transition out of
    /// `.suspect` back to `.alive`.
    ///
    /// This is the single, centralized cancellation path invoked from every
    /// recovery route (direct ack, gossiped recovery, self-refutation) so the
    /// suspicion timer can never outlive a refutation and fire a stale kill.
    private func cancelSuspicion(for memberID: MemberID) async {
        await suspicionTimer.cancelSuspicion(for: memberID)
    }

    // MARK: - Message Handling

    private func receiveLoop() async {
        for await (message, sender) in transport.incomingMessages {
            await handleMessage(message, from: sender)
        }
    }

    private func send(_ message: SWIMMessage, to member: MemberID) async throws {
        try await transport.send(try authenticatedOutboundMessage(message), to: member)
    }

    private func authenticatedOutboundMessage(_ message: SWIMMessage) throws -> SWIMMessage {
        #if !hasFeature(Embedded)
        guard let authenticator = config.authenticator else {
            return message
        }
        let messageBytes = try authenticationBytes(sender: localMember.id, message: message)
        let token = try authenticator.sign(messageBytes: messageBytes)
        return .authenticated(sender: localMember.id, token: token, message: message)
        #else
        return message
        #endif
    }

    private func handleMessage(_ message: SWIMMessage, from sender: MemberID) async {
        guard let message = verifiedInboundMessage(message, from: sender) else { return }

        // Process gossip payload first
        if let payload = message.payload {
            await processPayload(payload)
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

        case .authenticated:
            // verifiedInboundMessage unwraps authenticated envelopes before dispatch.
            break
        }
    }

    private func verifiedInboundMessage(_ message: SWIMMessage, from sender: MemberID) -> SWIMMessage? {
        #if !hasFeature(Embedded)
        guard let authenticator = config.authenticator else {
            if case .authenticated = message {
                eventContinuation.yield(.error(.protocolError(
                    "Rejected authenticated envelope from \(sender) without a configured authenticator"
                )))
                return nil
            }
            return message
        }

        guard case .authenticated(let claimedSender, let token, let inner) = message else {
            eventContinuation.yield(.error(.protocolError(
                "Rejected unauthenticated message from \(sender)"
            )))
            return nil
        }

        guard claimedSender == sender else {
            eventContinuation.yield(.error(.protocolError(
                "Rejected sender-mismatched authenticated message from \(sender)"
            )))
            return nil
        }

        let messageBytes: [UInt8]
        do {
            messageBytes = try authenticationBytes(sender: claimedSender, message: inner)
        } catch {
            eventContinuation.yield(.error(.protocolError(
                "Rejected malformed authenticated message from \(sender): \(error)"
            )))
            return nil
        }

        guard authenticator.verify(messageBytes: messageBytes, token: token) else {
            eventContinuation.yield(.error(.protocolError(
                "Rejected unverifiable message from \(sender)"
            )))
            return nil
        }
        return inner
        #else
        if case .authenticated = message {
            eventContinuation.yield(.error(.protocolError(
                "Rejected authenticated envelope from \(sender) in an unauthenticated Embedded build"
            )))
            return nil
        }
        return message
        #endif
    }

    private func authenticationBytes(sender: MemberID, message: SWIMMessage) throws -> [UInt8] {
        var buffer = WriteBuffer(capacity: 256)
        try sender.encode(to: &buffer)
        buffer.writeBytes(try SWIMMessageCodec.encodeToBytes(message))
        return buffer.toBytes()
    }

    private func handlePing(sequenceNumber: UInt64, from sender: MemberID) async {
        // Admit the ping sender through the SAME trust boundary as gossip
        // (`applyGossip`). The sender is an unauthenticated source — exactly the
        // threat the member-table cap guards against — so it must respect
        // `maxMemberCount` rather than taking the trusting `update` path, which
        // bypasses the cap and would let a spoofed-source ping flood grow the
        // table unbounded. A rejected admission is surfaced (never silently
        // dropped) and does NOT prevent answering the ping below.
        let senderMember = Member(id: sender)
        let change: MembershipChange?
        do {
            change = try memberList.applyGossip(
                senderMember,
                maxIncarnationDelta: config.maxIncarnationDelta,
                maxMemberCount: config.maxMemberCount
            )
        } catch {
            // `applyGossip` is typed-throws `MemberListRejection`, so `error` is
            // exactly that rejection — no dynamic cast (unavailable under Embedded).
            eventContinuation.yield(.error(.protocolError(
                "Rejected ping sender: \(error)"
            )))
            change = nil
        }
        if case .joined(let member)? = change {
            eventContinuation.yield(.memberJoined(member))
        }

        // Send ack
        let payload = disseminator.getPayloadForMessage()
        let ack = SWIMMessage.ack(
            sequenceNumber: sequenceNumber,
            target: localMember.id,
            payload: payload
        )

        do {
            try await send(ack, to: sender)
        } catch {
            return
        }
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
            isIndirect: true,
            requester: sender
        )

        // Ping the target on behalf of the requester
        let payload = disseminator.getPayloadForMessage()
        let ping = SWIMMessage.ping(sequenceNumber: probeSeq, payload: payload)

        do {
            try await send(ping, to: target)
        } catch {
            // Failed to send, send nack immediately
            pendingProbes.removeValue(forKey: probeSeq)
            let nack = SWIMMessage.nack(sequenceNumber: sequenceNumber, target: target)
            do {
                try await send(nack, to: sender)
            } catch {
                return
            }
            return
        }

        // Spawn background task to wait for ack (non-blocking).
        // This allows receiveLoop to continue processing messages. Capture is
        // `weak self` on host; Embedded has no weak references, so `self` is
        // captured strongly — the task awaits one ack/timeout and then returns,
        // so it holds no lasting cycle.
        let pingTimeout = config.pingTimeout
        #if hasFeature(Embedded)
        Task {
            let result = await self.waitForAck(
                sequenceNumber: probeSeq,
                timeout: pingTimeout
            )
            await self.completeIndirectProbe(
                originalSeq: sequenceNumber,
                probeSeq: probeSeq,
                target: target,
                requester: sender,
                result: result
            )
        }
        #else
        Task { [weak self] in
            guard let self else { return }

            // Wait for ack from target
            let result = await self.waitForAck(
                sequenceNumber: probeSeq,
                timeout: pingTimeout
            )

            // Complete the indirect probe
            await self.completeIndirectProbe(
                originalSeq: sequenceNumber,
                probeSeq: probeSeq,
                target: target,
                requester: sender,
                result: result
            )
        }
        #endif
    }

    /// Completes an indirect probe by sending response to requester.
    private func completeIndirectProbe(
        originalSeq: UInt64,
        probeSeq: UInt64,
        target: MemberID,
        requester: MemberID,
        result: ProbeResult
    ) async {
        // The probe entry was already removed when waitForAck resolved it
        // (ack or timeout); nothing to clean up here.

        if result == .alive {
            // Forward ack back to original requester
            let ackPayload = disseminator.getPayloadForMessage()
            let ack = SWIMMessage.ack(
                sequenceNumber: originalSeq,  // Use original seq for requester
                target: target,
                payload: ackPayload
            )
            do {
                try await send(ack, to: requester)
            } catch {
                return
            }
        } else {
            // Target didn't respond, send nack
            let nack = SWIMMessage.nack(sequenceNumber: originalSeq, target: target)
            do {
                try await send(nack, to: requester)
            } catch {
                return
            }
        }
    }

    private func handleAck(
        sequenceNumber: UInt64,
        target: MemberID,
        from sender: MemberID
    ) async {
        // Resume the matching pending probe exactly once. Only an ack from the
        // expected target counts; a mismatched ack is ignored (the probe keeps
        // waiting for the right one or times out).
        if let probe = pendingProbes[sequenceNumber], probe.target == target {
            resolveProbe(sequenceNumber: sequenceNumber, result: .alive)
        }

        // Cancel suspicion for the sender (centralized recovery path).
        await cancelSuspicion(for: sender)

        // Mark sender as alive if it was suspect.
        if let member = memberList.member(for: sender), member.status == .suspect {
            if let change = memberList.markAlive(sender, incarnation: member.incarnation.incremented()) {
                if case .statusChanged(let updated, _) = change {
                    eventContinuation.yield(.memberRecovered(updated))
                    disseminator.enqueue(member: updated)
                }
            }
        }
    }

    private func processPayload(_ payload: GossipPayload) async {
        for update in payload.updates {
            // Check if this is about us
            if update.memberID == localMember.id {
                handleUpdateAboutSelf(update)
                continue
            }

            let member = update.toMember()

            // Apply through the trust boundary: implausible incarnation jumps or
            // table-overflow joins are rejected and surfaced, never silently
            // trusted.
            let change: MembershipChange?
            do {
                change = try memberList.applyGossip(
                    member,
                    maxIncarnationDelta: config.maxIncarnationDelta,
                    maxMemberCount: config.maxMemberCount
                )
            } catch {
                // `applyGossip` is typed-throws `MemberListRejection`, so `error`
                // is exactly that rejection — no dynamic cast (unavailable under
                // Embedded).
                eventContinuation.yield(.error(.protocolError(
                    "Rejected gossip: \(error)"
                )))
                continue
            }

            guard let change else { continue }

            switch change {
            case .joined(let m):
                eventContinuation.yield(.memberJoined(m))
            case .statusChanged(let m, let from):
                switch m.status {
                case .alive:
                    if from == .suspect {
                        // Centralized recovery: a gossiped alive+higher-incarnation
                        // refutes a local suspicion, so cancel any running
                        // suspicion timer before it can fire a stale kill.
                        await cancelSuspicion(for: m.id)
                        eventContinuation.yield(.memberRecovered(m))
                    }
                case .suspect:
                    eventContinuation.yield(.memberSuspected(m))
                case .dead:
                    // A gossiped death also ends any local suspicion tracking.
                    await cancelSuspicion(for: m.id)
                    eventContinuation.yield(.memberFailed(m))
                }
            case .left(let id):
                eventContinuation.yield(.memberLeft(id))
            }

            // Re-disseminate
            disseminator.enqueue(update)
        }
    }

    private func handleUpdateAboutSelf(_ update: MembershipUpdate) {
        // Someone reports us as suspect or dead. Refute by advancing our own
        // incarnation. Treat the local incarnation as our monotonic counter:
        // never decrease it, and out-pace the (possibly forged) accuser by basing
        // the new value on max(local, reported). This prevents an attacker who
        // forged a huge incarnation from permanently out-running our refutation.
        guard update.status != .alive, update.incarnation >= localMember.incarnation else {
            return
        }

        let base = Swift.max(localMember.incarnation, update.incarnation)
        let refuted = base.incremented()

        // If the logical clock is already saturated, the refutation cannot
        // strictly out-rank the accusation. Surface this rather than silently
        // emitting a no-op refutation.
        guard refuted > localMember.incarnation else {
            eventContinuation.yield(.error(.protocolError(
                "Incarnation saturated; cannot refute accusation at \(update.incarnation.value)"
            )))
            return
        }

        localMember.incarnation = refuted
        eventContinuation.yield(.incarnationIncremented(localMember.incarnation))

        // Disseminate our new incarnation and reflect it locally.
        disseminator.enqueue(member: localMember)
        memberList.update(localMember)
    }
}

#if !hasFeature(Embedded)
extension SWIMCluster where Clock == SystemSWIMClock {
    /// Creates a new SWIM instance backed by the host system clock.
    ///
    /// HOST-ONLY: ``SystemSWIMClock`` does not exist under Embedded; an Embedded
    /// caller must use ``init(localMember:config:transport:clock:)`` and inject
    /// its own clock.
    ///
    /// - Parameters:
    ///   - localMember: The local member (this node)
    ///   - config: SWIM configuration
    ///   - transport: Transport for sending/receiving messages
    public init(
        localMember: Member,
        config: SWIMConfiguration = .default,
        transport: Transport
    ) {
        self.init(
            localMember: localMember,
            config: config,
            transport: transport,
            clock: SystemSWIMClock()
        )
    }
}
#endif
