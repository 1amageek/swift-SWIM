/// SWIM Message Buffer
///
/// Zero-copy buffer utilities for efficient message encoding/decoding.

import Foundation

// MARK: - Read Buffer

/// Non-copyable read buffer for zero-copy message parsing.
///
/// Uses `UnsafeRawBufferPointer` for direct memory access without
/// intermediate allocations.
///
/// - Important: The buffer does NOT own the underlying memory. Callers must
///   ensure the backing storage outlives the ReadBuffer. Always use within
///   `withUnsafeBytes` closures.
public struct ReadBuffer: ~Copyable {
    @usableFromInline
    let base: UnsafeRawPointer

    @usableFromInline
    let count: Int

    /// Creates a read buffer from an UnsafeRawBufferPointer.
    ///
    /// - Parameter buffer: The buffer to read from. Must not be empty.
    /// - Precondition: The buffer must have a valid base address (non-empty).
    @inlinable
    public init(_ buffer: UnsafeRawBufferPointer) {
        precondition(buffer.baseAddress != nil, "ReadBuffer requires non-empty buffer")
        self.base = buffer.baseAddress!
        self.count = buffer.count
    }

    /// Creates an empty read buffer (for error cases).
    @inlinable
    public static var empty: ReadBuffer {
        // Use a dummy pointer for empty buffer
        let dummy = UnsafeRawPointer(bitPattern: 1)!
        return ReadBuffer(base: dummy, count: 0)
    }

    @usableFromInline
    init(base: UnsafeRawPointer, count: Int) {
        self.base = base
        self.count = count
    }

    /// Reads a UInt8 at the given offset.
    @inlinable
    public func readUInt8(at offset: Int) -> UInt8 {
        base.load(fromByteOffset: offset, as: UInt8.self)
    }

    /// Reads a UInt16 (big-endian) at the given offset.
    @inlinable
    public func readUInt16(at offset: Int) -> UInt16 {
        let hi = UInt16(base.load(fromByteOffset: offset, as: UInt8.self))
        let lo = UInt16(base.load(fromByteOffset: offset + 1, as: UInt8.self))
        return (hi << 8) | lo
    }

    /// Reads a UInt32 (big-endian) at the given offset.
    @inlinable
    public func readUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(base.load(fromByteOffset: offset, as: UInt8.self))
        let b1 = UInt32(base.load(fromByteOffset: offset + 1, as: UInt8.self))
        let b2 = UInt32(base.load(fromByteOffset: offset + 2, as: UInt8.self))
        let b3 = UInt32(base.load(fromByteOffset: offset + 3, as: UInt8.self))
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    /// Reads a UInt64 (big-endian) at the given offset.
    @inlinable
    public func readUInt64(at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result = (result << 8) | UInt64(base.load(fromByteOffset: offset + i, as: UInt8.self))
        }
        return result
    }

    /// Reads bytes as a raw buffer pointer without copying.
    @inlinable
    public func bytes(at offset: Int, count: Int) -> UnsafeRawBufferPointer? {
        guard offset + count <= self.count else { return nil }
        return UnsafeRawBufferPointer(start: base + offset, count: count)
    }

    /// Reads a UTF-8 string at the given offset.
    @inlinable
    public func readString(at offset: Int, length: Int) -> String? {
        guard offset + length <= count else { return nil }
        let ptr = UnsafeRawBufferPointer(start: base + offset, count: length)
        return String(bytes: ptr, encoding: .utf8)
    }

    /// Checks if the buffer has enough bytes from the given offset.
    @inlinable
    public func hasBytes(_ needed: Int, at offset: Int) -> Bool {
        offset + needed <= count
    }
}

// MARK: - Write Buffer

/// Non-copyable write buffer for efficient message encoding.
///
/// Accumulates bytes without intermediate allocations.
public struct WriteBuffer: ~Copyable {
    @usableFromInline
    var storage: [UInt8]

    /// Creates an empty write buffer with optional initial capacity.
    @inlinable
    public init(capacity: Int = 256) {
        self.storage = []
        self.storage.reserveCapacity(capacity)
    }

    /// Current size of the buffer.
    @inlinable
    public var count: Int {
        storage.count
    }

    /// Appends a UInt8.
    @inlinable
    public mutating func writeUInt8(_ value: UInt8) {
        storage.append(value)
    }

    /// Appends a UInt16 (big-endian).
    @inlinable
    public mutating func writeUInt16(_ value: UInt16) {
        storage.append(UInt8((value >> 8) & 0xFF))
        storage.append(UInt8(value & 0xFF))
    }

    /// Appends a UInt32 (big-endian).
    @inlinable
    public mutating func writeUInt32(_ value: UInt32) {
        storage.append(UInt8((value >> 24) & 0xFF))
        storage.append(UInt8((value >> 16) & 0xFF))
        storage.append(UInt8((value >> 8) & 0xFF))
        storage.append(UInt8(value & 0xFF))
    }

    /// Appends a UInt64 (big-endian).
    @inlinable
    public mutating func writeUInt64(_ value: UInt64) {
        storage.append(UInt8((value >> 56) & 0xFF))
        storage.append(UInt8((value >> 48) & 0xFF))
        storage.append(UInt8((value >> 40) & 0xFF))
        storage.append(UInt8((value >> 32) & 0xFF))
        storage.append(UInt8((value >> 24) & 0xFF))
        storage.append(UInt8((value >> 16) & 0xFF))
        storage.append(UInt8((value >> 8) & 0xFF))
        storage.append(UInt8(value & 0xFF))
    }

    /// Appends raw bytes.
    @inlinable
    public mutating func writeBytes(_ bytes: [UInt8]) {
        storage.append(contentsOf: bytes)
    }

    /// Appends a string as UTF-8 with a 2-byte length prefix.
    @inlinable
    public mutating func writeLengthPrefixedString(_ string: String) {
        let bytes = Array(string.utf8)
        writeUInt16(UInt16(bytes.count))
        storage.append(contentsOf: bytes)
    }

    /// Converts the buffer to Data.
    @inlinable
    public consuming func toData() -> Data {
        Data(storage)
    }

    /// Returns the storage as an array.
    @inlinable
    public consuming func toBytes() -> [UInt8] {
        storage
    }
}

// MARK: - Byte Operations

/// Utility functions for byte operations.
@usableFromInline
enum ByteOps {
    /// Reads a UInt16 (big-endian) from a raw pointer.
    @inlinable
    static func readUInt16(from ptr: UnsafeRawPointer, at offset: Int) -> UInt16 {
        let hi = UInt16(ptr.load(fromByteOffset: offset, as: UInt8.self))
        let lo = UInt16(ptr.load(fromByteOffset: offset + 1, as: UInt8.self))
        return (hi << 8) | lo
    }

    /// Reads a UInt64 (big-endian) from a raw pointer.
    @inlinable
    static func readUInt64(from ptr: UnsafeRawPointer, at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result = (result << 8) | UInt64(ptr.load(fromByteOffset: offset + i, as: UInt8.self))
        }
        return result
    }
}
