/// Incarnation Tests

import Testing
@testable import SWIM

@Suite("Incarnation Tests")
struct IncarnationTests {

    @Test("Initial incarnation is zero")
    func initialValue() {
        let inc = Incarnation.initial
        #expect(inc.value == 0)
    }

    @Test("Incarnation creation")
    func creation() {
        let inc = Incarnation(value: 42)
        #expect(inc.value == 42)
    }

    @Test("Incarnation increment")
    func increment() {
        let inc1 = Incarnation.initial
        let inc2 = inc1.incremented()
        let inc3 = inc2.incremented()

        #expect(inc1.value == 0)
        #expect(inc2.value == 1)
        #expect(inc3.value == 2)
    }

    @Test("Incarnation comparison")
    func comparison() {
        let inc1 = Incarnation(value: 1)
        let inc2 = Incarnation(value: 2)
        let inc3 = Incarnation(value: 2)

        #expect(inc1 < inc2)
        #expect(inc2 > inc1)
        #expect(inc2 == inc3)
        #expect(inc2 <= inc3)
        #expect(inc2 >= inc3)
    }

    @Test("Incarnation equality")
    func equality() {
        let inc1 = Incarnation(value: 5)
        let inc2 = Incarnation(value: 5)
        let inc3 = Incarnation(value: 6)

        #expect(inc1 == inc2)
        #expect(inc1 != inc3)
    }

    @Test("Incarnation hashing")
    func hashing() {
        let inc1 = Incarnation(value: 5)
        let inc2 = Incarnation(value: 5)

        var set = Set<Incarnation>()
        set.insert(inc1)
        set.insert(inc2)

        #expect(set.count == 1)
    }

    @Test("Incarnation overflow wraps around")
    func overflowWraps() {
        let maxInc = Incarnation(value: UInt64.max)
        let wrapped = maxInc.incremented()

        #expect(wrapped.value == 0)
    }

    @Test("Incarnation description")
    func description() {
        let inc = Incarnation(value: 42)
        #expect(inc.description == "Incarnation(42)")
    }
}
