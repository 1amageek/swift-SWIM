// MemberID+Data.swift
//
// Host-only Foundation conveniences for the Embedded-clean `MemberID` value type
// (§2.6.1). Gated by `#if canImport(Foundation)` so the Embedded build never
// compiles them. `MemberID` itself, plus its `[UInt8]` byte currency
// (`encodedBytes()` / `init(bytes:)`), live in SWIMWire (Foundation-free); these
// add `Data` ergonomics for Apple developers as thin one-bulk-copy wrappers.

#if canImport(Foundation)
import Foundation
import SWIMWire

extension MemberID {
    /// Creates a member ID with an auto-generated UUID identifier.
    ///
    /// - Parameter address: Network address in "host:port" format.
    @inlinable
    public init(address: String) {
        self.init(id: UUID().uuidString, address: address)
    }

    /// The canonical owned-bytes identity as Foundation `Data`.
    ///
    /// Thin wrapper over the `[UInt8]` primary API (``encodedBytes()``): one bulk
    /// `Data(_:)` copy at the edge.
    ///
    /// - Throws: ``SWIMCodecError/stringTooLong(byteCount:)`` if `id` or
    ///   `address` exceeds the 16-bit length field.
    @inlinable
    public func encodedData() throws(SWIMCodecError) -> Data {
        Data(try encodedBytes())
    }

    /// Decodes a member identity from its canonical `Data` representation.
    ///
    /// Thin wrapper over ``init(bytes:)``: one bulk `[UInt8](_:)` copy at the edge.
    ///
    /// - Throws: ``SWIMCodecError/truncatedMessage`` if the data does not contain
    ///   a complete, well-formed identity.
    @inlinable
    public init(data: Data) throws(SWIMCodecError) {
        try self.init(bytes: [UInt8](data))
    }
}

// `MemberID` lives in SWIMWire (Foundation-free), so `Codable` cannot be
// synthesized there. The conformance is spelled out here in the Foundation
// adapter (memberwise synthesis only applies in the type's own module).
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
#endif
