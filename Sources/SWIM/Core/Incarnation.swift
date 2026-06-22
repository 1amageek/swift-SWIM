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

    /// Maximum representable incarnation value.
    public static let max = Incarnation(value: UInt64.max)

    /// Whether this incarnation has reached the maximum representable value.
    ///
    /// At saturation the logical clock can no longer advance, which means
    /// refutation can no longer outrank a forged maximum incarnation.
    @inlinable
    public var isSaturated: Bool {
        value == UInt64.max
    }

    /// Returns a new incarnation incremented by 1.
    ///
    /// An incarnation is a logical clock and must never decrease. Instead of
    /// silently wrapping around (which would let a stale `0` outrank a
    /// legitimate maximum), the value saturates at `UInt64.max`.
    ///
    /// - Note: Saturation is surfaced via ``isSaturated`` so callers can react
    ///   to the (practically unreachable) exhaustion of the clock.
    @inlinable
    public func incremented() -> Incarnation {
        // Saturate instead of wrapping: a logical clock must be monotonic.
        guard value < UInt64.max else { return Incarnation(value: UInt64.max) }
        return Incarnation(value: value + 1)
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
