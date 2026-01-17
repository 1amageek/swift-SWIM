/// SWIM Gossip Payload
///
/// Membership updates piggybacked on protocol messages.

/// A single membership update to be disseminated.
public struct MembershipUpdate: Sendable, Hashable {
    /// The member this update is about.
    @usableFromInline
    let memberID: MemberID

    /// The member's address.
    @usableFromInline
    let address: String

    /// The status being reported.
    @usableFromInline
    let status: MemberStatus

    /// The incarnation number of this update.
    @usableFromInline
    let incarnation: Incarnation

    /// Number of times this update has been piggybacked (internal use).
    @usableFromInline
    var disseminationCount: Int

    /// Creates a membership update.
    @inlinable
    public init(
        memberID: MemberID,
        status: MemberStatus,
        incarnation: Incarnation,
        disseminationCount: Int = 0
    ) {
        self.memberID = memberID
        self.address = memberID.address
        self.status = status
        self.incarnation = incarnation
        self.disseminationCount = disseminationCount
    }

    /// Creates a membership update from a member.
    @inlinable
    public init(member: Member, disseminationCount: Int = 0) {
        self.memberID = member.id
        self.address = member.id.address
        self.status = member.status
        self.incarnation = member.incarnation
        self.disseminationCount = disseminationCount
    }

    /// Converts this update to a Member.
    @inlinable
    public func toMember() -> Member {
        Member(id: memberID, status: status, incarnation: incarnation)
    }

    /// Returns a copy with incremented dissemination count.
    @inlinable
    public func incrementingDisseminationCount() -> MembershipUpdate {
        var copy = self
        copy.disseminationCount += 1
        return copy
    }

    /// Encodes the membership update to a write buffer.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) {
        memberID.encode(to: &buffer)
        status.encode(to: &buffer)
        incarnation.encode(to: &buffer)
    }

    /// Decodes a membership update from a read buffer.
    @inlinable
    public static func decode(
        from buffer: borrowing ReadBuffer,
        at offset: inout Int
    ) -> MembershipUpdate? {
        guard let memberID = MemberID.decode(from: buffer, at: &offset) else { return nil }

        guard buffer.hasBytes(1, at: offset) else { return nil }
        let status = MemberStatus.decode(from: buffer, at: offset) ?? .alive
        offset += 1

        guard buffer.hasBytes(8, at: offset) else { return nil }
        let incarnation = Incarnation.decode(from: buffer, at: offset)
        offset += 8

        return MembershipUpdate(
            memberID: memberID,
            status: status,
            incarnation: incarnation
        )
    }
}

extension MembershipUpdate: CustomStringConvertible {
    public var description: String {
        "Update(\(memberID.id): \(status), inc=\(incarnation.value), sent=\(disseminationCount))"
    }
}

// MARK: - Gossip Payload

/// Gossip payload piggybacked on SWIM messages.
///
/// Contains membership updates to disseminate to other members.
public struct GossipPayload: Sendable, Hashable {
    /// Membership updates to disseminate.
    @usableFromInline
    var updates: [MembershipUpdate]

    /// Creates a gossip payload with the given updates.
    @inlinable
    public init(updates: [MembershipUpdate] = []) {
        self.updates = updates
    }

    /// Empty payload with no updates.
    public static let empty = GossipPayload(updates: [])

    /// Whether this payload is empty.
    @inlinable
    public var isEmpty: Bool {
        updates.isEmpty
    }

    /// Number of updates in this payload.
    @inlinable
    public var count: Int {
        updates.count
    }

    /// Encodes the gossip payload to a write buffer.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) {
        buffer.writeUInt16(UInt16(updates.count))
        for update in updates {
            update.encode(to: &buffer)
        }
    }

    /// Decodes a gossip payload from a read buffer.
    @inlinable
    public static func decode(
        from buffer: borrowing ReadBuffer,
        at offset: inout Int
    ) -> GossipPayload? {
        guard buffer.hasBytes(2, at: offset) else { return nil }
        let count = Int(buffer.readUInt16(at: offset))
        offset += 2

        var updates: [MembershipUpdate] = []
        updates.reserveCapacity(count)

        for _ in 0..<count {
            guard let update = MembershipUpdate.decode(from: buffer, at: &offset) else {
                return nil
            }
            updates.append(update)
        }

        return GossipPayload(updates: updates)
    }
}

extension GossipPayload: CustomStringConvertible {
    public var description: String {
        "GossipPayload(\(updates.count) updates)"
    }
}
