/// SWIM Member Status
///
/// Represents the status of a member in the SWIM cluster.

/// Status of a member in the cluster.
///
/// Members transition between states based on the failure detection protocol:
/// - `alive`: Member is responsive and healthy
/// - `suspect`: Member failed to respond, but not yet confirmed dead
/// - `dead`: Member is confirmed unreachable
public enum MemberStatus: UInt8, Sendable, Hashable {
    case alive = 0
    case suspect = 1
    case dead = 2

    /// Encodes the status to a write buffer.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) {
        buffer.writeUInt8(rawValue)
    }

    /// Decodes a status from a read buffer.
    @inlinable
    public static func decode(from buffer: borrowing ReadBuffer, at offset: Int) -> MemberStatus? {
        MemberStatus(rawValue: buffer.readUInt8(at: offset))
    }
}

extension MemberStatus: Comparable {
    /// Compare statuses by severity (dead > suspect > alive).
    @inlinable
    public static func < (lhs: MemberStatus, rhs: MemberStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension MemberStatus {
    /// Priority for dissemination.
    ///
    /// Higher priority updates are disseminated more aggressively.
    /// Dead status has highest priority to ensure quick propagation.
    @inlinable
    public var disseminationPriority: Int {
        switch self {
        case .alive: return 0
        case .suspect: return 1
        case .dead: return 2
        }
    }
}

extension MemberStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alive: return "alive"
        case .suspect: return "suspect"
        case .dead: return "dead"
        }
    }
}
