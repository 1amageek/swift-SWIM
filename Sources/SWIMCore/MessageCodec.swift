/// SWIM Message Codec
///
/// High-performance binary encoding and decoding for SWIM protocol messages.
/// Uses zero-copy parsing and @inlinable annotations for optimal performance.

/// Errors that can occur during message encoding/decoding.
public enum SWIMCodecError: Error, Sendable, Equatable {
    case invalidMessageType(UInt8)
    case truncatedMessage
    case invalidUTF8
    case messageTooLarge(Int)
    /// A length-prefixed string exceeded the 16-bit length field (65535 bytes).
    ///
    /// Surfaced instead of trapping so an over-long identifier/address cannot
    /// crash the encoder.
    case stringTooLong(byteCount: Int)
}

/// High-performance binary codec for SWIM messages.
///
/// ## Wire Format
///
/// ### Message Header
/// ```
/// ┌────────────┬────────────┐
/// │ Type (1B)  │ SeqNum(8B) │
/// └────────────┴────────────┘
/// ```
///
/// ### Message Types
/// - 0x01: Ping (payload)
/// - 0x02: PingRequest (target + payload)
/// - 0x03: Ack (target + payload)
/// - 0x04: Nack (target)
///
/// ### MemberID Format
/// ```
/// ┌────────────┬──────────────┬────────────┬──────────────┐
/// │ IDLen (2B) │ ID (var)     │ AddrLen(2B)│ Address(var) │
/// └────────────┴──────────────┴────────────┴──────────────┘
/// ```
///
/// ### GossipPayload Format
/// ```
/// ┌────────────┬─────────────────────────────────────────┐
/// │ Count (2B) │ Updates[]                                │
/// └────────────┴─────────────────────────────────────────┘
/// ```
public enum SWIMMessageCodec {

    /// Maximum message size (64KB).
    public static let maxMessageSize = 65536

    // MARK: - Encoding

    /// Encodes a SWIM message to bytes.
    ///
    /// Uses optimized WriteBuffer for zero-copy encoding.
    ///
    /// - Throws: ``SWIMCodecError/stringTooLong(byteCount:)`` if any contained
    ///   identifier/address exceeds the 16-bit length field.
    @inlinable
    public static func encodeToBytes(_ message: SWIMMessage) throws(SWIMCodecError) -> [UInt8] {
        var buffer = WriteBuffer(capacity: 256)
        try message.encode(to: &buffer)
        return buffer.toBytes()
    }

    // MARK: - Decoding

    /// Decodes a SWIM message from raw bytes.
    ///
    /// Zero-copy decoding directly from byte array (the array backs a borrowed
    /// ``ReadBuffer`` for the duration of `withUnsafeBytes`).
    @inlinable
    public static func decode(_ bytes: [UInt8]) throws(SWIMCodecError) -> SWIMMessage {
        guard bytes.count >= 9 else {
            throw SWIMCodecError.truncatedMessage
        }

        guard bytes.count <= maxMessageSize else {
            throw SWIMCodecError.messageTooLarge(bytes.count)
        }

        // Decode inside the closure (non-throwing: returns nil on failure), then
        // map nil onto a typed error outside so the typed throw need not
        // propagate through `withUnsafeBytes` (which is untyped `rethrows`).
        let decoded: SWIMMessage? = bytes.withUnsafeBytes { ptr in
            SWIMMessage.decode(from: ReadBuffer(ptr))
        }
        guard let decoded else {
            throw error(forTypeCode: bytes[0])
        }
        return decoded
    }

    /// Decodes a SWIM message from an UnsafeRawBufferPointer.
    ///
    /// Most efficient decoding path - no copying at all.
    @inlinable
    public static func decode(_ ptr: UnsafeRawBufferPointer) throws(SWIMCodecError) -> SWIMMessage {
        guard ptr.count >= 9 else {
            throw SWIMCodecError.truncatedMessage
        }

        guard ptr.count <= maxMessageSize else {
            throw SWIMCodecError.messageTooLarge(ptr.count)
        }

        let buffer = ReadBuffer(ptr)
        guard let message = SWIMMessage.decode(from: buffer) else {
            throw error(forTypeCode: buffer.readUInt8(at: 0))
        }
        return message
    }

    /// Maps a structural-decode failure onto the specific typed error: an
    /// out-of-range message-type byte is reported distinctly from truncation.
    @inlinable
    static func error(forTypeCode typeCode: UInt8) -> SWIMCodecError {
        typeCode > 0x04 ? .invalidMessageType(typeCode) : .truncatedMessage
    }
}
