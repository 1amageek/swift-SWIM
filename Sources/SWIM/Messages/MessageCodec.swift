/// SWIM Message Codec
///
/// High-performance binary encoding and decoding for SWIM protocol messages.
/// Uses zero-copy parsing and @inlinable annotations for optimal performance.

import Foundation

/// Errors that can occur during message encoding/decoding.
public enum SWIMCodecError: Error, Sendable {
    case invalidMessageType(UInt8)
    case truncatedMessage
    case invalidUTF8
    case messageTooLarge(Int)
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

    /// Encodes a SWIM message to binary format.
    ///
    /// Uses optimized WriteBuffer for zero-copy encoding.
    @inlinable
    public static func encode(_ message: SWIMMessage) -> Data {
        var buffer = WriteBuffer(capacity: 256)
        message.encode(to: &buffer)
        return buffer.toData()
    }

    /// Encodes a SWIM message to bytes.
    ///
    /// Returns raw bytes instead of Data for lower overhead.
    @inlinable
    public static func encodeToBytes(_ message: SWIMMessage) -> [UInt8] {
        var buffer = WriteBuffer(capacity: 256)
        message.encode(to: &buffer)
        return buffer.toBytes()
    }

    // MARK: - Decoding

    /// Decodes a SWIM message from binary format.
    ///
    /// Uses zero-copy ReadBuffer for optimal performance.
    @inlinable
    public static func decode(_ data: Data) throws -> SWIMMessage {
        guard data.count >= 9 else {
            throw SWIMCodecError.truncatedMessage
        }

        guard data.count <= maxMessageSize else {
            throw SWIMCodecError.messageTooLarge(data.count)
        }

        return try data.withUnsafeBytes { bytes in
            let buffer = ReadBuffer(UnsafeRawBufferPointer(bytes))
            guard let message = SWIMMessage.decode(from: buffer) else {
                // Determine specific error
                let typeCode = buffer.readUInt8(at: 0)
                if typeCode > 0x04 {
                    throw SWIMCodecError.invalidMessageType(typeCode)
                }
                throw SWIMCodecError.truncatedMessage
            }
            return message
        }
    }

    /// Decodes a SWIM message from raw bytes.
    ///
    /// Zero-copy decoding directly from byte array.
    @inlinable
    public static func decode(_ bytes: [UInt8]) throws -> SWIMMessage {
        guard bytes.count >= 9 else {
            throw SWIMCodecError.truncatedMessage
        }

        guard bytes.count <= maxMessageSize else {
            throw SWIMCodecError.messageTooLarge(bytes.count)
        }

        return try bytes.withUnsafeBytes { ptr in
            let buffer = ReadBuffer(ptr)
            guard let message = SWIMMessage.decode(from: buffer) else {
                let typeCode = buffer.readUInt8(at: 0)
                if typeCode > 0x04 {
                    throw SWIMCodecError.invalidMessageType(typeCode)
                }
                throw SWIMCodecError.truncatedMessage
            }
            return message
        }
    }

    /// Decodes a SWIM message from an UnsafeRawBufferPointer.
    ///
    /// Most efficient decoding path - no copying at all.
    @inlinable
    public static func decode(_ ptr: UnsafeRawBufferPointer) throws -> SWIMMessage {
        guard ptr.count >= 9 else {
            throw SWIMCodecError.truncatedMessage
        }

        guard ptr.count <= maxMessageSize else {
            throw SWIMCodecError.messageTooLarge(ptr.count)
        }

        let buffer = ReadBuffer(ptr)
        guard let message = SWIMMessage.decode(from: buffer) else {
            let typeCode = buffer.readUInt8(at: 0)
            if typeCode > 0x04 {
                throw SWIMCodecError.invalidMessageType(typeCode)
            }
            throw SWIMCodecError.truncatedMessage
        }
        return message
    }
}

// MARK: - Legacy Data Extensions (Kept for Backward Compatibility)

extension Data {
    @inlinable
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    @inlinable
    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    @inlinable
    func readUInt16(at offset: Int) -> UInt16 {
        let hi = UInt16(self[offset])
        let lo = UInt16(self[offset + 1])
        return (hi << 8) | lo
    }

    @inlinable
    func readUInt64(at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result = (result << 8) | UInt64(self[offset + i])
        }
        return result
    }
}
