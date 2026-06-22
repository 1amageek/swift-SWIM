// SWIMFoundationBridge.swift
//
// Foundation compatibility layer for the Embedded-clean `SWIMCore` codec.
//
// `SWIMCore` is Foundation-free and operates on `[UInt8]`. This adapter
// re-exposes the historical `Data` API surface and Foundation-backed
// conveniences so existing callers and the test suite compile unchanged:
//
//   - `SWIMMessageCodec.encode(_) -> Data` / `decode(_ data: Data)`
//   - `WriteBuffer.toData()`
//   - `MemberID(address:)` (UUID-backed) and `MemberID: Codable`
//
// All bridges are copy-only and contain no protocol logic; the codec lives in
// `SWIMCore`.

import Foundation
import SWIMCore

// MARK: - SWIMMessageCodec: Data bridges

extension SWIMMessageCodec {
    /// Encodes a SWIM message to Foundation `Data`.
    ///
    /// - Throws: ``SWIMCodecError/stringTooLong(byteCount:)`` if any contained
    ///   identifier/address exceeds the 16-bit length field.
    @inlinable
    public static func encode(_ message: SWIMMessage) throws -> Data {
        Data(try encodeToBytes(message))
    }

    /// Decodes a SWIM message from Foundation `Data`.
    @inlinable
    public static func decode(_ data: Data) throws -> SWIMMessage {
        guard data.count >= 9 else {
            throw SWIMCodecError.truncatedMessage
        }
        guard data.count <= maxMessageSize else {
            throw SWIMCodecError.messageTooLarge(data.count)
        }
        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            try decode(ptr)
        }
    }
}

// MARK: - WriteBuffer: Data finalizer

extension WriteBuffer {
    /// Returns the buffer contents as Foundation `Data`.
    @inlinable
    public consuming func toData() -> Data {
        Data(toBytes())
    }
}

// MARK: - MemberID: Foundation conveniences

extension MemberID {
    /// Creates a member ID with an auto-generated UUID.
    ///
    /// - Parameter address: Network address in "host:port" format.
    @inlinable
    public init(address: String) {
        self.init(id: UUID().uuidString, address: address)
    }
}

// `MemberID` lives in `SWIMCore` (Foundation-free), so `Codable` synthesis must
// be spelled out here in the Foundation adapter (memberwise synthesis only
// applies in the type's own module).
extension MemberID: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case address
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let address = try container.decode(String.self, forKey: .address)
        self.init(id: id, address: address)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(address, forKey: .address)
    }
}
