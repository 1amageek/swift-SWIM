/// SWIM Configuration
///
/// Configuration options for the SWIM protocol instance.

import Foundation

/// Strategy for selecting probe targets.
public enum ProbeSelectionStrategy: Sendable {
    /// Random selection - simple but may miss some members.
    case random

    /// Round-robin selection - guarantees all members are probed eventually.
    case roundRobin
}

/// SWIM instance configuration.
///
/// These parameters control the behavior of the failure detection
/// and gossip dissemination protocols.
public struct SWIMConfiguration: Sendable {

    /// Protocol period (time between probe rounds).
    ///
    /// During each protocol period, one member is selected and probed.
    /// Shorter periods mean faster failure detection but more network traffic.
    ///
    /// Default: 200ms
    public var protocolPeriod: Duration

    /// Timeout for ping response.
    ///
    /// If no ack is received within this time, indirect probes are sent.
    ///
    /// Default: 100ms
    public var pingTimeout: Duration

    /// Number of members for indirect ping.
    ///
    /// When a direct ping fails, this many random members are asked
    /// to ping the target on our behalf.
    ///
    /// Default: 3
    public var indirectProbeCount: Int

    /// Suspicion timeout multiplier.
    ///
    /// The suspicion timeout is calculated as:
    /// `log(N) * suspicionMultiplier * protocolPeriod`
    ///
    /// where N is the number of members. Larger multipliers mean
    /// longer wait before declaring a suspect member dead.
    ///
    /// Default: 5.0
    public var suspicionMultiplier: Double

    /// Maximum number of updates to piggyback per message.
    ///
    /// More updates mean better dissemination but larger messages.
    ///
    /// Default: 10
    public var maxPayloadSize: Int

    /// Base dissemination limit.
    ///
    /// Each update is piggybacked this many times, multiplied by
    /// `log(N)` where N is the number of members.
    ///
    /// Default: 3
    public var baseDisseminationLimit: Int

    /// Dead member retention period before removal from member list.
    ///
    /// Dead members are kept for this duration to allow gossip propagation.
    /// After this period, they are removed from memory.
    ///
    /// Default: 30 seconds
    public var deadMemberRetention: Duration

    /// Strategy for selecting probe targets.
    ///
    /// - `random`: Simple random selection (may miss some members)
    /// - `roundRobin`: Guarantees all members are probed eventually
    ///
    /// Default: `.roundRobin`
    public var probeSelectionStrategy: ProbeSelectionStrategy

    /// Maximum plausible forward jump in a gossiped incarnation.
    ///
    /// SWIM is unauthenticated by default: a peer can forge a higher incarnation
    /// to win every status conflict (marking a member dead or making itself
    /// undetectable). Gossip whose incarnation is more than this many steps ahead
    /// of the locally known value is rejected (surfaced as
    /// ``MemberListRejection/incarnationJumpTooLarge(memberID:known:proposed:maxDelta:)``)
    /// rather than silently trusted.
    ///
    /// This is a heuristic sanity bound, not authentication. For real
    /// authentication, configure ``authenticator``.
    ///
    /// Default: 16
    public var maxIncarnationDelta: UInt64

    /// Maximum number of members the table will hold.
    ///
    /// Bounds memory growth from a flood of gossiped (potentially forged)
    /// members. Joins beyond this cap are rejected (surfaced as
    /// ``MemberListRejection/memberTableFull(memberID:limit:)``) rather than
    /// silently accepted.
    ///
    /// Default: 10000
    public var maxMemberCount: Int

    /// Optional message authenticator.
    ///
    /// When set, outgoing messages are signed and incoming messages are verified
    /// before their gossip is trusted; unverifiable datagrams are rejected. When
    /// `nil` (the default), the instance runs in traditional unauthenticated mode
    /// and only the heuristic sanity bounds (``maxIncarnationDelta`` and
    /// ``maxMemberCount``) protect the trust boundary.
    ///
    /// Default: `nil`
    public var authenticator: (any SWIMMessageAuthenticator)?

    /// Creates a new configuration with the given values.
    public init(
        protocolPeriod: Duration = .milliseconds(200),
        pingTimeout: Duration = .milliseconds(100),
        indirectProbeCount: Int = 3,
        suspicionMultiplier: Double = 5.0,
        maxPayloadSize: Int = 10,
        baseDisseminationLimit: Int = 3,
        deadMemberRetention: Duration = .seconds(30),
        probeSelectionStrategy: ProbeSelectionStrategy = .roundRobin,
        maxIncarnationDelta: UInt64 = 16,
        maxMemberCount: Int = 10_000,
        authenticator: (any SWIMMessageAuthenticator)? = nil
    ) {
        self.protocolPeriod = protocolPeriod
        self.pingTimeout = pingTimeout
        self.indirectProbeCount = indirectProbeCount
        self.suspicionMultiplier = suspicionMultiplier
        self.maxPayloadSize = maxPayloadSize
        self.baseDisseminationLimit = baseDisseminationLimit
        self.deadMemberRetention = deadMemberRetention
        self.probeSelectionStrategy = probeSelectionStrategy
        self.maxIncarnationDelta = maxIncarnationDelta
        self.maxMemberCount = maxMemberCount
        self.authenticator = authenticator
    }

    /// Default configuration suitable for most use cases.
    public static let `default` = SWIMConfiguration()

    /// Fast configuration for low-latency environments.
    ///
    /// Uses shorter timeouts and periods for faster failure detection.
    public static let fast = SWIMConfiguration(
        protocolPeriod: .milliseconds(100),
        pingTimeout: .milliseconds(50),
        indirectProbeCount: 3,
        suspicionMultiplier: 3.0,
        maxPayloadSize: 10,
        baseDisseminationLimit: 3,
        deadMemberRetention: .seconds(15),
        probeSelectionStrategy: .roundRobin
    )

    /// Slow configuration for high-latency or unreliable networks.
    ///
    /// Uses longer timeouts to reduce false positives.
    public static let slow = SWIMConfiguration(
        protocolPeriod: .milliseconds(500),
        pingTimeout: .milliseconds(250),
        indirectProbeCount: 5,
        suspicionMultiplier: 8.0,
        maxPayloadSize: 15,
        baseDisseminationLimit: 4,
        deadMemberRetention: .seconds(60),
        probeSelectionStrategy: .roundRobin
    )

    /// Development configuration for local testing.
    ///
    /// Very fast detection for quick iteration during development.
    public static let development = SWIMConfiguration(
        protocolPeriod: .milliseconds(50),
        pingTimeout: .milliseconds(25),
        indirectProbeCount: 2,
        suspicionMultiplier: 2.0,
        maxPayloadSize: 5,
        baseDisseminationLimit: 2,
        deadMemberRetention: .seconds(5),
        probeSelectionStrategy: .roundRobin
    )

    // MARK: - Computed Properties

    /// Calculates the suspicion timeout based on member count.
    ///
    /// - Parameter memberCount: Current number of members in the cluster
    /// - Returns: The suspicion timeout duration
    public func suspicionTimeout(memberCount: Int) -> Duration {
        let logN = max(1.0, log(Double(max(1, memberCount))))
        let multiplied = logN * suspicionMultiplier
        return protocolPeriod * multiplied
    }

    /// Calculates the dissemination limit based on member count.
    ///
    /// - Parameter memberCount: Current number of members in the cluster
    /// - Returns: Number of times to send each update
    public func disseminationLimit(memberCount: Int) -> Int {
        let logN = max(1.0, log(Double(max(1, memberCount))))
        return Int(ceil(Double(baseDisseminationLimit) * logN))
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Multiplies a duration by a non-negative scalar without losing sub-second
    /// precision and without trapping on overflow.
    ///
    /// The computation is performed in the integer attosecond domain using
    /// `Int128` so that fractional-second durations (e.g. the per-protocol-period
    /// suspicion math) keep their precision instead of round-tripping through
    /// `Double`. The fractional part of `rhs` is applied to the attosecond
    /// component directly. The result is clamped to the representable
    /// `Duration` range rather than trapping, so adversarial or extreme inputs
    /// cannot crash the suspicion-timeout calculation.
    ///
    /// - Parameters:
    ///   - lhs: The duration to scale.
    ///   - rhs: A non-negative multiplier. Negative values are clamped to zero
    ///     because a negative timeout is meaningless for SWIM.
    /// - Returns: The scaled, clamped duration.
    static func * (lhs: Duration, rhs: Double) -> Duration {
        // A negative scaled duration is meaningless for timeouts; clamp to zero.
        guard rhs > 0 else { return .zero }

        let components = lhs.components
        let attosPerSecond: Int128 = 1_000_000_000_000_000_000

        // Total magnitude in attoseconds as an exact integer.
        let totalAttos =
            Int128(components.seconds) * attosPerSecond + Int128(components.attoseconds)

        // Split the multiplier into integer and fractional parts so the integer
        // part stays exact and only the (bounded) fractional part uses Double.
        let intPart = rhs.rounded(.towardZero)
        let fracPart = rhs - intPart

        // Integer-part contribution with overflow-safe multiplication.
        let scaledInt: Int128
        if let exact = Int128(exactly: intPart) {
            let (product, overflow) = totalAttos.multipliedReportingOverflow(by: exact)
            scaledInt = overflow ? Int128.max : product
        } else {
            scaledInt = Int128.max
        }

        // Fractional-part contribution. fracPart is in [0, 1), so this cannot
        // overflow a Double that already fit a Duration's attosecond magnitude.
        let scaledFrac = Int128(Double(totalAttos) * fracPart)

        // Sum with saturation.
        let (sum, sumOverflow) = scaledInt.addingReportingOverflow(scaledFrac)
        let totalScaled = sumOverflow ? Int128.max : sum

        // Convert back to (seconds, attoseconds), clamping to Int64 range.
        let secondsRaw = totalScaled / attosPerSecond
        let attosRaw = totalScaled % attosPerSecond

        let seconds: Int64
        if let exact = Int64(exactly: secondsRaw) {
            seconds = exact
        } else {
            // Clamp to the maximum representable whole-second duration.
            return Duration(secondsComponent: Int64.max, attosecondsComponent: 0)
        }

        return Duration(
            secondsComponent: seconds,
            attosecondsComponent: Int64(attosRaw)
        )
    }
}
