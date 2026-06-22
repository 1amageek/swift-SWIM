/// SWIM Probe Result
///
/// Result types for probe operations.

/// Result of a probe operation.
public enum ProbeResult: Sendable {
    /// Target responded, it's alive.
    case alive

    /// Target didn't respond directly but was reached indirectly.
    case aliveIndirect

    /// Local transport failed before any probe could be dispatched.
    case transportFailure

    /// Target didn't respond, marked as suspect.
    case suspect

    /// Target was already suspect and timer expired, now dead.
    case dead

    /// Probe timed out completely.
    case timeout
}
