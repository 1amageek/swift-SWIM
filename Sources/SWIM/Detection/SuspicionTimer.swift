/// SWIM Suspicion Timer
///
/// Manages suspicion timeouts for members in the suspect state.

import Foundation
import SWIMWire

/// Manages suspicion timeouts.
///
/// When a member becomes suspect, a timer is started. If the member
/// doesn't prove itself alive before the timer expires, it's marked dead.
public actor SuspicionTimer {
    /// An active suspicion: the timer task plus the incarnation captured when
    /// suspicion started. The captured incarnation is used by the kill path to
    /// enforce that only a *still-suspect, same-incarnation* member can be marked
    /// dead, so any refutation invalidates the pending kill.
    private struct Suspicion {
        let task: Task<Void, Never>
        let incarnation: Incarnation
    }

    private var suspicions: [MemberID: Suspicion]

    /// Creates a new suspicion timer.
    public init() {
        self.suspicions = [:]
    }

    /// Starts a suspicion timer for a member.
    ///
    /// If a timer already exists for this member, it is cancelled first.
    ///
    /// - Parameters:
    ///   - member: The member to track
    ///   - incarnation: The member's incarnation captured at suspicion start. It
    ///     is passed back to `onExpired` so the kill path can require strict
    ///     equality (any refutation bumps the incarnation and invalidates the kill).
    ///   - timeout: How long to wait before declaring the member dead
    ///   - onExpired: Callback invoked with the captured incarnation when the
    ///     timer expires (i.e. the member was never refuted).
    public func startSuspicion(
        for member: MemberID,
        incarnation: Incarnation,
        timeout: Duration,
        onExpired: @Sendable @escaping (Incarnation) -> Void
    ) {
        // Cancel existing timer if any
        suspicions[member]?.task.cancel()

        // Start new timer
        let task = Task {
            do {
                try await Task.sleep(for: timeout)
                // Timer expired (not refuted): invoke kill with captured incarnation.
                onExpired(incarnation)
            } catch {
                // Task was cancelled (member refuted), do nothing.
            }
        }

        suspicions[member] = Suspicion(task: task, incarnation: incarnation)
    }

    /// Cancels the suspicion timer for a member.
    ///
    /// Call this when a member proves itself alive (e.g., responds to ping
    /// or sends an update with a higher incarnation).
    ///
    /// - Parameter member: The member whose timer to cancel
    public func cancelSuspicion(for member: MemberID) {
        suspicions[member]?.task.cancel()
        suspicions.removeValue(forKey: member)
    }

    /// Checks if a member is currently under suspicion.
    ///
    /// - Parameter member: The member to check
    /// - Returns: True if there's an active suspicion timer for this member
    public func isSuspect(_ member: MemberID) -> Bool {
        if let suspicion = suspicions[member] {
            return !suspicion.task.isCancelled
        }
        return false
    }

    /// Cancels all active suspicion timers.
    public func cancelAll() {
        for (_, suspicion) in suspicions {
            suspicion.task.cancel()
        }
        suspicions.removeAll()
    }

    /// Returns the number of active suspicion timers.
    public var activeSuspicionCount: Int {
        suspicions.count
    }
}
