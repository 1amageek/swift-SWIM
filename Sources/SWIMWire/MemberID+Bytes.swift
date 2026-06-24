/// MemberID byte currency
///
/// The canonical `[UInt8]` owned-bytes accessor for `MemberID`, per the
/// Embedded-first currency rule (§2.6): the public surface leads with `[UInt8]`.
///
/// The byte form is the wire encoding of the identity — the same length-prefixed
/// `id` + `address` layout the codec uses — so it round-trips losslessly and the
/// wire stays `[UInt8]`-native. Foundation-free; typed throws (never traps).

extension MemberID {
    /// The canonical owned-bytes representation of this member identity.
    ///
    /// Layout matches the wire `MemberID` encoding:
    /// `idLen(2) | id(var) | addrLen(2) | address(var)`, big-endian lengths.
    ///
    /// - Returns: The encoded identity bytes.
    /// - Throws: ``SWIMCodecError/stringTooLong(byteCount:)`` if `id` or
    ///   `address` exceeds the 16-bit length field.
    @inlinable
    public func encodedBytes() throws(SWIMCodecError) -> [UInt8] {
        var buffer = WriteBuffer(capacity: id.utf8.count + address.utf8.count + 4)
        try encode(to: &buffer)
        return buffer.toBytes()
    }

    /// Decodes a member identity from its canonical owned-bytes representation.
    ///
    /// - Parameter bytes: The encoded identity bytes (as produced by
    ///   ``encodedBytes()``).
    /// - Throws: ``SWIMCodecError/truncatedMessage`` if the bytes do not contain
    ///   a complete, well-formed identity.
    @inlinable
    public init(bytes: [UInt8]) throws(SWIMCodecError) {
        // Decode inside the closure (non-throwing: returns nil on failure), then
        // map nil onto a typed error outside so the typed throw need not
        // propagate through `withUnsafeBytes` (untyped `rethrows`).
        let decoded: MemberID? = bytes.withUnsafeBytes { ptr in
            guard ptr.baseAddress != nil, ptr.count > 0 else { return nil }
            let buffer = ReadBuffer(ptr)
            var offset = 0
            return MemberID.decode(from: buffer, at: &offset)
        }
        guard let decoded else {
            throw SWIMCodecError.truncatedMessage
        }
        self = decoded
    }
}
