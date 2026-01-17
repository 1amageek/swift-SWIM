/// SWIM Incarnation Number
///
/// Incarnation numbers are used to handle consistency in SWIM.
/// When a member receives a suspicion about itself, it can refute
/// by incrementing its incarnation number.

/// Incarnation number for consistency.
///
/// Higher incarnation always wins in status conflicts:
/// - If `incarnation(A) > incarnation(B)`, update A wins
/// - If incarnations are equal, higher severity status wins (dead > suspect > alive)
///
/// This mechanism prevents old information from overriding newer state.
public struct Incarnation: Sendable, Hashable {
    /// The incarnation value.
    @usableFromInline
    let value: UInt64

    /// Creates an incarnation with the given value.
    @inlinable
    public init(value: UInt64) {
        self.value = value
    }

    /// Initial incarnation number (0).
    public static let initial = Incarnation(value: 0)

    /// Returns a new incarnation incremented by 1.
    @inlinable
    public func incremented() -> Incarnation {
        Incarnation(value: value &+ 1)
    }

    /// Encodes the incarnation to a write buffer.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) {
        buffer.writeUInt64(value)
    }

    /// Decodes an incarnation from a read buffer.
    @inlinable
    public static func decode(from buffer: borrowing ReadBuffer, at offset: Int) -> Incarnation {
        Incarnation(value: buffer.readUInt64(at: offset))
    }
}

extension Incarnation: Comparable {
    @inlinable
    public static func < (lhs: Incarnation, rhs: Incarnation) -> Bool {
        lhs.value < rhs.value
    }
}

extension Incarnation: CustomStringConvertible {
    public var description: String {
        "Incarnation(\(value))"
    }
}

extension Incarnation: ExpressibleByIntegerLiteral {
    @inlinable
    public init(integerLiteral value: UInt64) {
        self.value = value
    }
}
