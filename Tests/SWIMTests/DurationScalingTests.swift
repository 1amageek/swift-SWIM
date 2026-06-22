/// Duration Scaling Tests
///
/// Tests for the Duration * Double extension: sub-second precision is preserved
/// and extreme/overflowing inputs clamp instead of trapping.

import Foundation
import Testing
@testable import SWIM

@Suite("Duration Scaling Tests")
struct DurationScalingTests {

    private func attoseconds(_ d: Duration) -> Int128 {
        let c = d.components
        return Int128(c.seconds) * 1_000_000_000_000_000_000 + Int128(c.attoseconds)
    }

    @Test("Sub-second precision is preserved")
    func subSecondPrecision() {
        // 200ms * 2.5 = 500ms exactly.
        let result = Duration.milliseconds(200) * 2.5
        #expect(result == .milliseconds(500))
    }

    @Test("Fractional scaling of a fractional duration is exact within attosecond domain")
    func fractionalScaling() {
        // 100ms * 0.5 = 50ms.
        #expect(Duration.milliseconds(100) * 0.5 == .milliseconds(50))
        // 1s * 0.001 = 1ms.
        #expect(Duration.seconds(1) * 0.001 == .milliseconds(1))
        // 30ms * 1.5 = 45ms (no Double round-trip loss).
        #expect(Duration.milliseconds(30) * 1.5 == .milliseconds(45))
    }

    @Test("Suspicion timeout math keeps sub-second precision")
    func suspicionTimeoutPrecision() {
        var config = SWIMConfiguration.default
        config.protocolPeriod = .milliseconds(20)
        config.suspicionMultiplier = 1.5
        // memberCount 1 => logN clamps to 1.0 => 20ms * 1.5 = 30ms exactly.
        let timeout = config.suspicionTimeout(memberCount: 1)
        #expect(timeout == .milliseconds(30))
    }

    @Test("Negative multiplier clamps to zero")
    func negativeMultiplierClampsToZero() {
        let result = Duration.seconds(5) * -2.0
        #expect(result == .zero)
    }

    @Test("Zero multiplier yields zero")
    func zeroMultiplier() {
        #expect(Duration.seconds(5) * 0.0 == .zero)
    }

    @Test("Extreme multiplier clamps instead of trapping")
    func extremeMultiplierClamps() {
        // A multiplier large enough to overflow Int64 nanoseconds must clamp to
        // the maximum representable whole-second duration rather than trap.
        let result = Duration.seconds(1_000_000) * 1e30
        // Result is clamped; it must be enormous and not crash.
        #expect(attoseconds(result) > 0)
        #expect(result > Duration.seconds(1_000_000))
    }

    @Test("Dissemination limit grows with member count")
    func disseminationLimitGrows() {
        let config = SWIMConfiguration.default
        let small = config.disseminationLimit(memberCount: 2)
        let large = config.disseminationLimit(memberCount: 1000)
        #expect(large > small, "Dissemination fan-out must grow with the cluster size")
    }

    @Test("Disseminator dissemination limit is updatable at runtime")
    func disseminatorLimitUpdatable() {
        let disseminator = Disseminator(maxPayloadSize: 10, disseminationLimit: 3)
        #expect(disseminator.disseminationLimit == 3)
        disseminator.updateDisseminationLimit(9)
        #expect(disseminator.disseminationLimit == 9)
        // Floored at 1.
        disseminator.updateDisseminationLimit(0)
        #expect(disseminator.disseminationLimit == 1)
    }
}
