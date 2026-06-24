// SWIMMessageCodec+Data.swift
//
// Host-only Foundation `Data` conveniences over the Embedded-clean SWIMWire codec
// (§2.6.1). Gated by `#if canImport(Foundation)` so the Embedded build never
// compiles them. Each is a THIN wrapper over the `[UInt8]` primary API with
// exactly one bulk conversion at the call boundary (`Data(bytes)` /
// `data.withUnsafeBytes`), never an element-wise append loop.
//
// The primary, Embedded-clean byte API (`[UInt8]` / `UnsafeRawBufferPointer`)
// lives in SWIMWire; these overloads add `Data` ergonomics for Apple developers.

#if canImport(Foundation)
import Foundation
import SWIMWire

// MARK: - SWIMMessageCodec: Data conveniences

extension SWIMMessageCodec {
    /// Encodes a SWIM message to Foundation `Data`.
    ///
    /// Thin wrapper: one bulk `Data(_:)` copy over the `[UInt8]` primary API.
    ///
    /// - Throws: ``SWIMCodecError/stringTooLong(byteCount:)`` if any contained
    ///   identifier/address exceeds the 16-bit length field.
    @inlinable
    public static func encode(_ message: SWIMMessage) throws(SWIMCodecError) -> Data {
        Data(try encodeToBytes(message))
    }

    /// Decodes a SWIM message from Foundation `Data`.
    ///
    /// Thin wrapper: one bulk `[UInt8](_:)` copy at the edge, then delegates to
    /// the `[UInt8]` primary API (which preserves the typed `SWIMCodecError`).
    @inlinable
    public static func decode(_ data: Data) throws(SWIMCodecError) -> SWIMMessage {
        try decode([UInt8](data))
    }
}

// MARK: - WriteBuffer: Data finalizer

extension WriteBuffer {
    /// Returns the buffer contents as Foundation `Data` (one bulk copy).
    @inlinable
    public consuming func toData() -> Data {
        Data(toBytes())
    }
}
#endif
