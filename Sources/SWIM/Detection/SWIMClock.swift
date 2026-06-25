/// SWIM Clock + Timer Seam
///
/// The single time + sleep seam the SWIM orchestrator injects so it can drive the
/// protocol period, suspicion, and probe timers WITHOUT `ContinuousClock` or
/// `Task.sleep(for:)` — both are `@available(*, unavailable)` under Embedded Swift
/// 6.3.1.
///
/// This mirrors `swift-p2p-core`'s `MonotonicClock` / `AsyncTimer` seam, but is
/// declared locally in the `SWIM` target on purpose: depending on
/// `swift-p2p-core` would force its `.macOS(.v26)` platform floor onto SWIM (and
/// transitively onto swift-libp2p), whereas SWIM's floor is `.v15`. The seam is
/// tiny, so duplicating the two protocols here keeps SWIM's floor and its
/// dependency surface unchanged while staying byte-for-byte compatible with the
/// proven p2p-core contract.
///
/// Embedded-clean by construction:
///   * no `any` (the orchestrator injects a concrete `Clock: SWIMClock`)
///   * no Foundation, no `ContinuousClock`, no `Date`
///   * `sleep` is typed-throws `CancellationError` ONLY — an untyped `throws`
///     would erase to `any Error` across the async boundary, which is rejected
///     under Embedded Swift.

import _Concurrency

/// A monotonic clock that can also suspend the current task until a deadline.
///
/// The SWIM orchestrator reads "now" from ``monotonicNanos()`` and parks on
/// ``sleep(untilNanos:)`` to drive the protocol period, the ping timeout, and the
/// suspicion timeout — never `Task.sleep`, never `ContinuousClock`.
///
/// ## The timer is the embedder's runtime on Embedded
///
/// Embedded Swift ships no default global executor and no time source by design
/// (the concurrency runtime is the embedder's responsibility). The host
/// implementation (``SystemSWIMClock``) backs ``sleep(untilNanos:)`` with
/// `ContinuousClock` + `Task.sleep`; an Embedded embedder injects its own
/// ``SWIMClock`` whose ``sleep(untilNanos:)`` parks the task on the platform's
/// real timer/executor.
public protocol SWIMClock: Sendable {
    /// Monotonic nanoseconds since an arbitrary fixed epoch.
    func monotonicNanos() -> UInt64

    /// Suspends the current task until the monotonic clock reaches `deadlineNanos`.
    ///
    /// The deadline is an absolute value on the SAME monotonic timeline as
    /// ``monotonicNanos()``. If the deadline is already in the past, the call
    /// returns promptly (no spurious wait).
    ///
    /// - Parameter deadlineNanos: The absolute monotonic-nanoseconds instant to
    ///   wake at, as produced by ``monotonicNanos()``.
    /// - Throws: ``CancellationError`` — and ONLY ``CancellationError`` — if the
    ///   task is cancelled while suspended. The typed throw is deliberate: an
    ///   untyped `throws` would erase to `any Error` across the async boundary,
    ///   which is rejected under Embedded Swift.
    func sleep(untilNanos deadlineNanos: UInt64) async throws(CancellationError)
}

#if !hasFeature(Embedded)
/// The host `SWIMClock`, backed by the standard-library `ContinuousClock`.
///
/// HOST-ONLY: `ContinuousClock` and `Task.sleep(until:clock:)` are
/// `@available(*, unavailable)` under Embedded Swift, so the whole type is gated
/// `#if !hasFeature(Embedded)`. Under Embedded the embedder injects its own
/// ``SWIMClock``.
///
/// `monotonicNanos()` reports nanoseconds since construction; `sleep(untilNanos:)`
/// suspends via `Task.sleep(until:clock:)`, which is fully cancellation-aware.
public struct SystemSWIMClock: SWIMClock {
    private let origin: ContinuousClock.Instant
    private let clock = ContinuousClock()

    public init() {
        self.origin = ContinuousClock.now
    }

    /// Monotonic nanoseconds since this clock was created.
    public func monotonicNanos() -> UInt64 {
        let elapsed = ContinuousClock.now - origin
        let (seconds, attoseconds) = elapsed.components
        return UInt64(max(0, seconds)) &* 1_000_000_000
            &+ UInt64(max(0, attoseconds) / 1_000_000_000)
    }

    /// Suspends until `monotonicNanos()` reaches `deadlineNanos` (absolute, on the
    /// same monotonic timeline). Returns promptly if already past.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while suspended.
    public func sleep(untilNanos deadlineNanos: UInt64) async throws(CancellationError) {
        let now = monotonicNanos()
        if deadlineNanos <= now { return }
        let waitNanos = deadlineNanos - now
        let instant = ContinuousClock.now.advanced(by: .nanoseconds(waitNanos))
        do {
            try await Task.sleep(until: instant, clock: clock)
        } catch {
            // `Task.sleep` throws only `CancellationError`; re-surface it as the
            // protocol's typed error. No other error type can reach here.
            throw CancellationError()
        }
    }
}
#endif

// MARK: - Duration → nanoseconds

extension Duration {
    /// This duration in nanoseconds (saturating, non-negative).
    ///
    /// SWIM timeouts are always non-negative; a negative duration is clamped to
    /// zero. Overflow saturates to `UInt64.max` rather than trapping so an
    /// adversarial or extreme timeout cannot crash the timer arithmetic.
    var swimNanos: UInt64 {
        let components = self.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = UInt64(max(0, components.seconds))
        let (secNanos, secOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if secOverflow { return UInt64.max }
        let attoNanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let (total, addOverflow) = secNanos.addingReportingOverflow(attoNanos)
        return addOverflow ? UInt64.max : total
    }
}
