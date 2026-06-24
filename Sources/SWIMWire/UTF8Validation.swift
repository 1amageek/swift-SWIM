// UTF8Validation.swift
// Foundation-free, validating UTF-8 decode for SWIM identifier/address strings.

/// Decodes a byte sequence as UTF-8, returning `nil` if the bytes are not valid
/// UTF-8.
///
/// Embedded-clean replacement for Foundation's `String(bytes:encoding:.utf8)`
/// used by the SWIM codec; rejects malformed UTF-8 instead of substituting
/// replacement characters.
@inlinable
func validatedUTF8String(_ bytes: some Sequence<UInt8>) -> String? {
    var scalars = String.UnicodeScalarView()
    var decoder = UTF8()
    var iterator = bytes.makeIterator()
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar):
            scalars.append(scalar)
        case .emptyInput:
            return String(scalars)
        case .error:
            return nil
        }
    }
}
