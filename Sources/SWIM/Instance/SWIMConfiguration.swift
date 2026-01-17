/// SWIM Configuration
///
/// Configuration options for the SWIM protocol instance.

import Foundation

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

    /// Creates a new configuration with the given values.
    public init(
        protocolPeriod: Duration = .milliseconds(200),
        pingTimeout: Duration = .milliseconds(100),
        indirectProbeCount: Int = 3,
        suspicionMultiplier: Double = 5.0,
        maxPayloadSize: Int = 10,
        baseDisseminationLimit: Int = 3
    ) {
        self.protocolPeriod = protocolPeriod
        self.pingTimeout = pingTimeout
        self.indirectProbeCount = indirectProbeCount
        self.suspicionMultiplier = suspicionMultiplier
        self.maxPayloadSize = maxPayloadSize
        self.baseDisseminationLimit = baseDisseminationLimit
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
        baseDisseminationLimit: 3
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
        baseDisseminationLimit: 4
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
        baseDisseminationLimit: 2
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
    /// Multiplies a duration by a double value.
    static func * (lhs: Duration, rhs: Double) -> Duration {
        let components = lhs.components
        let totalNanos = Double(components.seconds) * 1_000_000_000 + Double(components.attoseconds) / 1_000_000_000
        let newNanos = totalNanos * rhs
        return .nanoseconds(Int64(newNanos))
    }
}
