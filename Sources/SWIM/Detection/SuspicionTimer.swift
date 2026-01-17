/// SWIM Suspicion Timer
///
/// Manages suspicion timeouts for members in the suspect state.

import Foundation

/// Manages suspicion timeouts.
///
/// When a member becomes suspect, a timer is started. If the member
/// doesn't prove itself alive before the timer expires, it's marked dead.
public actor SuspicionTimer {
    private var suspicionTasks: [MemberID: Task<Void, Never>]

    /// Creates a new suspicion timer.
    public init() {
        self.suspicionTasks = [:]
    }

    /// Starts a suspicion timer for a member.
    ///
    /// If a timer already exists for this member, it is cancelled first.
    ///
    /// - Parameters:
    ///   - member: The member to track
    ///   - timeout: How long to wait before declaring the member dead
    ///   - onExpired: Callback invoked when the timer expires
    public func startSuspicion(
        for member: MemberID,
        timeout: Duration,
        onExpired: @Sendable @escaping () -> Void
    ) {
        // Cancel existing timer if any
        suspicionTasks[member]?.cancel()

        // Start new timer
        let task = Task {
            do {
                try await Task.sleep(for: timeout)
                // Timer expired, call callback
                onExpired()
            } catch {
                // Task was cancelled, do nothing
            }
        }

        suspicionTasks[member] = task
    }

    /// Cancels the suspicion timer for a member.
    ///
    /// Call this when a member proves itself alive (e.g., responds to ping
    /// or sends an update with a higher incarnation).
    ///
    /// - Parameter member: The member whose timer to cancel
    public func cancelSuspicion(for member: MemberID) {
        suspicionTasks[member]?.cancel()
        suspicionTasks.removeValue(forKey: member)
    }

    /// Checks if a member is currently under suspicion.
    ///
    /// - Parameter member: The member to check
    /// - Returns: True if there's an active suspicion timer for this member
    public func isSuspect(_ member: MemberID) -> Bool {
        if let task = suspicionTasks[member] {
            return !task.isCancelled
        }
        return false
    }

    /// Cancels all active suspicion timers.
    public func cancelAll() {
        for (_, task) in suspicionTasks {
            task.cancel()
        }
        suspicionTasks.removeAll()
    }

    /// Returns the number of active suspicion timers.
    public var activeSuspicionCount: Int {
        suspicionTasks.count
    }
}
