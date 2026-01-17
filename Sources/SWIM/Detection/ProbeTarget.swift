/// SWIM Probe Target Selection
///
/// Utilities for selecting random members to probe.

import Foundation

/// Result of a probe operation.
public enum ProbeResult: Sendable {
    /// Target responded, it's alive.
    case alive

    /// Target didn't respond directly but was reached indirectly.
    case aliveIndirect

    /// Target didn't respond, marked as suspect.
    case suspect

    /// Target was already suspect and timer expired, now dead.
    case dead

    /// Probe timed out completely.
    case timeout
}

/// Information about a pending probe.
internal struct PendingProbe: Sendable {
    /// The member being probed.
    let target: Member

    /// When the probe started.
    let startTime: ContinuousClock.Instant

    /// Continuation to resume when ack is received.
    let continuation: CheckedContinuation<ProbeResult, Never>?

    /// Whether indirect probes have been sent.
    var indirectProbesSent: Bool

    /// Members used for indirect probes.
    var indirectProbers: [MemberID]

    init(
        target: Member,
        continuation: CheckedContinuation<ProbeResult, Never>? = nil
    ) {
        self.target = target
        self.startTime = .now
        self.continuation = continuation
        self.indirectProbesSent = false
        self.indirectProbers = []
    }
}
