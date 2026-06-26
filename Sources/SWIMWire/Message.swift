/// SWIM Protocol Messages
///
/// Defines the messages used in the SWIM failure detection protocol.

/// SWIM protocol messages.
///
/// The SWIM protocol uses four message types:
/// - `ping`: Direct health check
/// - `pingRequest`: Request for indirect health check
/// - `ack`: Positive response to ping
/// - `nack`: Negative response (optional extension)
public enum SWIMMessage: Sendable, Hashable {
    /// Direct health check.
    ///
    /// Sent to a member to verify it's alive. The member should respond
    /// with an `ack` message.
    case ping(sequenceNumber: UInt64, payload: GossipPayload)

    /// Indirect health check request.
    ///
    /// Sent to intermediary members when a direct ping fails. The intermediary
    /// should ping the target on behalf of the requester.
    case pingRequest(sequenceNumber: UInt64, target: MemberID, payload: GossipPayload)

    /// Positive response to a ping or ping-request.
    ///
    /// Indicates the target member is alive.
    case ack(sequenceNumber: UInt64, target: MemberID, payload: GossipPayload)

    /// Negative acknowledgment (optional extension).
    ///
    /// Can be used to explicitly indicate a probe failure.
    case nack(sequenceNumber: UInt64, target: MemberID)

    /// Authenticated envelope binding the token to the transport sender and
    /// canonical inner message.
    indirect case authenticated(sender: MemberID, token: [UInt8], message: SWIMMessage)

    /// The sequence number of this message.
    @inlinable
    public var sequenceNumber: UInt64 {
        switch self {
        case .ping(let seq, _): return seq
        case .pingRequest(let seq, _, _): return seq
        case .ack(let seq, _, _): return seq
        case .nack(let seq, _): return seq
        case .authenticated(_, _, let message): return message.sequenceNumber
        }
    }

    /// The gossip payload of this message, if any.
    @inlinable
    public var payload: GossipPayload? {
        switch self {
        case .ping(_, let payload): return payload
        case .pingRequest(_, _, let payload): return payload
        case .ack(_, _, let payload): return payload
        case .nack: return nil
        case .authenticated(_, _, let message): return message.payload
        }
    }

    /// Message type identifier for encoding.
    @usableFromInline
    var typeCode: UInt8 {
        switch self {
        case .ping: return 0x01
        case .pingRequest: return 0x02
        case .ack: return 0x03
        case .nack: return 0x04
        case .authenticated: return 0x05
        }
    }

    /// Encodes the message to a write buffer.
    ///
    /// - Throws: ``SWIMCodecError/stringTooLong(byteCount:)`` if any contained
    ///   identifier/address exceeds the 16-bit length field.
    @inlinable
    public func encode(to buffer: inout WriteBuffer) throws(SWIMCodecError) {
        // Type
        buffer.writeUInt8(typeCode)

        // Sequence number
        buffer.writeUInt64(sequenceNumber)

        switch self {
        case .ping(_, let payload):
            try payload.encode(to: &buffer)

        case .pingRequest(_, let target, let payload):
            try target.encode(to: &buffer)
            try payload.encode(to: &buffer)

        case .ack(_, let target, let payload):
            try target.encode(to: &buffer)
            try payload.encode(to: &buffer)

        case .nack(_, let target):
            try target.encode(to: &buffer)

        case .authenticated(let sender, let token, let message):
            guard token.count <= Int(UInt16.max) else {
                throw SWIMCodecError.authenticationTokenTooLong(byteCount: token.count)
            }
            buffer.writeUInt16(UInt16(token.count))
            buffer.writeBytes(token)
            try sender.encode(to: &buffer)
            try message.encode(to: &buffer)
        }
    }

    /// Decodes a message from a read buffer.
    @inlinable
    public static func decode(from buffer: borrowing ReadBuffer) -> SWIMMessage? {
        guard buffer.hasBytes(9, at: 0) else { return nil }

        var offset = 0

        // Type
        let typeCode = buffer.readUInt8(at: offset)
        offset += 1

        // Sequence number
        let sequenceNumber = buffer.readUInt64(at: offset)
        offset += 8

        switch typeCode {
        case 0x01: // Ping
            guard let payload = GossipPayload.decode(from: buffer, at: &offset) else {
                return nil
            }
            return .ping(sequenceNumber: sequenceNumber, payload: payload)

        case 0x02: // PingRequest
            guard let target = MemberID.decode(from: buffer, at: &offset) else {
                return nil
            }
            guard let payload = GossipPayload.decode(from: buffer, at: &offset) else {
                return nil
            }
            return .pingRequest(sequenceNumber: sequenceNumber, target: target, payload: payload)

        case 0x03: // Ack
            guard let target = MemberID.decode(from: buffer, at: &offset) else {
                return nil
            }
            guard let payload = GossipPayload.decode(from: buffer, at: &offset) else {
                return nil
            }
            return .ack(sequenceNumber: sequenceNumber, target: target, payload: payload)

        case 0x04: // Nack
            guard let target = MemberID.decode(from: buffer, at: &offset) else {
                return nil
            }
            return .nack(sequenceNumber: sequenceNumber, target: target)

        case 0x05: // Authenticated envelope
            guard buffer.hasBytes(2, at: offset) else { return nil }
            let tokenLength = Int(buffer.readUInt16(at: offset))
            offset += 2
            guard let tokenBytes = buffer.bytes(at: offset, count: tokenLength) else {
                return nil
            }
            let token = Array(tokenBytes)
            offset += tokenLength
            guard let sender = MemberID.decode(from: buffer, at: &offset) else { return nil }
            guard buffer.hasBytes(9, at: offset) else { return nil }
            let inner = ReadBuffer(base: buffer.base + offset, count: buffer.count - offset)
            guard let message = SWIMMessage.decode(from: inner) else { return nil }
            return .authenticated(sender: sender, token: token, message: message)

        default:
            return nil
        }
    }
}

extension SWIMMessage: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ping(let seq, let payload):
            return "Ping(seq=\(seq), \(payload.count) updates)"
        case .pingRequest(let seq, let target, let payload):
            return "PingRequest(seq=\(seq), target=\(target.id), \(payload.count) updates)"
        case .ack(let seq, let target, let payload):
            return "Ack(seq=\(seq), target=\(target.id), \(payload.count) updates)"
        case .nack(let seq, let target):
            return "Nack(seq=\(seq), target=\(target.id))"
        case .authenticated(let sender, let token, let message):
            return "Authenticated(sender=\(sender.id), tokenBytes=\(token.count), message=\(message))"
        }
    }
}
