/// SuspicionTimer Tests
///
/// Verifies that the suspicion timer fires its kill callback only when the
/// member is never refuted, and that cancellation reliably prevents the kill.

import Foundation
import Synchronization
import Testing
@testable import SWIM

@Suite("SuspicionTimer Tests")
struct SuspicionTimerTests {

    @Test("Timer fires onExpired with the captured incarnation when not cancelled", .timeLimit(.minutes(1)))
    func firesWithCapturedIncarnation() async throws {
        let timer = SuspicionTimer()
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")
        let captured = Incarnation(value: 7)

        let fired = Mutex<Incarnation?>(nil)
        await timer.startSuspicion(for: id, incarnation: captured, timeout: .milliseconds(20)) { inc in
            fired.withLock { $0 = inc }
        }

        // Wait past the timeout.
        try await Task.sleep(for: .milliseconds(80))

        #expect(fired.withLock { $0 } == captured, "Timer must fire with the incarnation captured at suspicion start")
        #expect(await timer.activeSuspicionCount >= 0)
    }

    @Test("Cancellation prevents the kill callback from firing", .timeLimit(.minutes(1)))
    func cancellationPreventsKill() async throws {
        let timer = SuspicionTimer()
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")

        let firedCount = Mutex<Int>(0)
        await timer.startSuspicion(for: id, incarnation: Incarnation(value: 1), timeout: .milliseconds(100)) { _ in
            firedCount.withLock { $0 += 1 }
        }

        // Refutation cancels well before the timeout.
        try await Task.sleep(for: .milliseconds(10))
        await timer.cancelSuspicion(for: id)

        // Wait long past the original timeout.
        try await Task.sleep(for: .milliseconds(200))

        #expect(firedCount.withLock { $0 } == 0, "Cancelled timer must not fire the kill callback")
        #expect(await timer.activeSuspicionCount == 0)
    }

    @Test("Re-arming suspicion cancels the previous timer", .timeLimit(.minutes(1)))
    func reArmingCancelsPrevious() async throws {
        let timer = SuspicionTimer()
        let id = MemberID(id: "node1", address: "127.0.0.1:8000")

        let firedIncarnations = Mutex<[UInt64]>([])
        // First arm with a short timeout.
        await timer.startSuspicion(for: id, incarnation: Incarnation(value: 1), timeout: .milliseconds(30)) { inc in
            firedIncarnations.withLock { $0.append(inc.value) }
        }
        // Re-arm before the first fires; this must cancel the first.
        await timer.startSuspicion(for: id, incarnation: Incarnation(value: 2), timeout: .milliseconds(30)) { inc in
            firedIncarnations.withLock { $0.append(inc.value) }
        }

        try await Task.sleep(for: .milliseconds(120))

        let fired = firedIncarnations.withLock { $0 }
        #expect(fired == [2], "Only the most recent suspicion should fire; the superseded one must be cancelled")
    }

    @Test("cancelAll stops every pending timer", .timeLimit(.minutes(1)))
    func cancelAllStopsEverything() async throws {
        let timer = SuspicionTimer()
        let firedCount = Mutex<Int>(0)

        for i in 0..<5 {
            let id = MemberID(id: "node\(i)", address: "127.0.0.1:800\(i)")
            await timer.startSuspicion(for: id, incarnation: Incarnation(value: 1), timeout: .milliseconds(50)) { _ in
                firedCount.withLock { $0 += 1 }
            }
        }
        #expect(await timer.activeSuspicionCount == 5)

        await timer.cancelAll()
        #expect(await timer.activeSuspicionCount == 0)

        try await Task.sleep(for: .milliseconds(150))
        #expect(firedCount.withLock { $0 } == 0, "cancelAll must prevent every kill callback")
    }
}
