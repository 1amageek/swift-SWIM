/// SWIM Member Types
///
/// Defines the identity and state of members in a SWIM cluster.

import Foundation

/// Unique identifier for a SWIM member.
///
/// Each member has a unique ID and a network address.
/// The ID should be stable across restarts (e.g., a UUID or hostname).
public struct MemberID: Sendable, Hashable {
    /// Unique identifier string.
    public let id: String

    /// Network address (host:port format).
    public let address: String

    /// Creates a member ID.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for this member
    ///   - address: Network address in "host:port" format
    @inlinable
    public init(id: String, address: String) {
        self.id = id
        self.address = address
    }

    /// Creates a member ID with auto-generated UUID.
    ///
    /// - Parameter address: Network address in "host:port" format
    @inlinable
    public init(address: String) {
        self.id = UUID().uuidString
        self.address = address
    }

    /// Encodes the member ID to a write buffer.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) {
        buffer.writeLengthPrefixedString(id)
        buffer.writeLengthPrefixedString(address)
    }

    /// Decodes a member ID from a read buffer.
    ///
    /// - Parameters:
    ///   - buffer: The read buffer
    ///   - offset: Current offset (updated after reading)
    /// - Returns: The decoded MemberID, or nil if decoding fails
    @inlinable
    public static func decode(
        from buffer: borrowing ReadBuffer,
        at offset: inout Int
    ) -> MemberID? {
        // Read id length
        guard buffer.hasBytes(2, at: offset) else { return nil }
        let idLen = Int(buffer.readUInt16(at: offset))
        offset += 2

        // Read id
        guard let id = buffer.readString(at: offset, length: idLen) else { return nil }
        offset += idLen

        // Read address length
        guard buffer.hasBytes(2, at: offset) else { return nil }
        let addrLen = Int(buffer.readUInt16(at: offset))
        offset += 2

        // Read address
        guard let address = buffer.readString(at: offset, length: addrLen) else { return nil }
        offset += addrLen

        return MemberID(id: id, address: address)
    }
}

extension MemberID: CustomStringConvertible {
    public var description: String {
        "\(id)@\(address)"
    }
}

extension MemberID: Codable {}

// MARK: - Member

/// A member in the SWIM cluster.
///
/// Represents the known state of a cluster member, including their
/// current status and incarnation number.
public struct Member: Sendable, Hashable {
    /// The member's unique identifier.
    public let id: MemberID

    /// Current status of this member.
    public var status: MemberStatus

    /// Incarnation number for consistency.
    public var incarnation: Incarnation

    /// Creates a new member.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for this member
    ///   - status: Initial status (default: `.alive`)
    ///   - incarnation: Initial incarnation (default: `.initial`)
    @inlinable
    public init(
        id: MemberID,
        status: MemberStatus = .alive,
        incarnation: Incarnation = .initial
    ) {
        self.id = id
        self.status = status
        self.incarnation = incarnation
    }

    /// Whether this member is considered alive.
    @inlinable
    public var isAlive: Bool {
        status == .alive
    }

    /// Whether this member is suspected of being failed.
    @inlinable
    public var isSuspect: Bool {
        status == .suspect
    }

    /// Whether this member is confirmed dead.
    @inlinable
    public var isDead: Bool {
        status == .dead
    }

    /// Encodes the member to a write buffer.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) {
        id.encode(to: &buffer)
        status.encode(to: &buffer)
        incarnation.encode(to: &buffer)
    }

    /// Decodes a member from a read buffer.
    @inlinable
    public static func decode(
        from buffer: borrowing ReadBuffer,
        at offset: inout Int
    ) -> Member? {
        guard let id = MemberID.decode(from: buffer, at: &offset) else { return nil }

        guard buffer.hasBytes(1, at: offset) else { return nil }
        guard let status = MemberStatus.decode(from: buffer, at: offset) else { return nil }
        offset += 1

        guard buffer.hasBytes(8, at: offset) else { return nil }
        let incarnation = Incarnation.decode(from: buffer, at: offset)
        offset += 8

        return Member(id: id, status: status, incarnation: incarnation)
    }
}

extension Member: CustomStringConvertible {
    public var description: String {
        "Member(\(id), \(status), \(incarnation))"
    }
}

// MARK: - Membership Change

/// Represents a change in cluster membership.
public enum MembershipChange: Sendable {
    /// A new member joined the cluster.
    case joined(Member)

    /// A member's status changed.
    case statusChanged(Member, from: MemberStatus)

    /// A member left the cluster (removed from member list).
    case left(MemberID)
}

extension MembershipChange: CustomStringConvertible {
    public var description: String {
        switch self {
        case .joined(let member):
            return "Joined: \(member)"
        case .statusChanged(let member, let from):
            return "StatusChanged: \(member.id) \(from) -> \(member.status)"
        case .left(let id):
            return "Left: \(id)"
        }
    }
}
