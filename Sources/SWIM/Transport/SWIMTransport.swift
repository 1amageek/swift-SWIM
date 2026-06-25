/// SWIM Transport Protocol
///
/// Defines the transport interface for sending and receiving SWIM messages.

import _Concurrency
import SWIMWire

/// Transport protocol for SWIM messages.
///
/// Implement this protocol to integrate SWIM with your networking layer.
/// The transport is responsible for:
/// - Sending encoded messages to other members
/// - Receiving and decoding incoming messages
/// - Managing network connections
///
/// ## Example Implementation
/// ```swift
/// final class UDPTransport: SWIMTransport {
///     let localAddress: String
///     let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>
///     private let continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation
///
///     init(localAddress: String) {
///         self.localAddress = localAddress
///         var cont: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
///         self.incomingMessages = AsyncStream { cont = $0 }
///         self.continuation = cont
///     }
///
///     func send(_ message: SWIMMessage, to member: MemberID) async throws {
///         let data = SWIMMessageCodec.encode(message)
///         try await socket.send(data, to: member.address)
///     }
/// }
/// ```
#if hasFeature(Embedded)
/// The typed error a ``SWIMTransport`` reports from ``SWIMTransport/send(_:to:)``
/// under Embedded Swift, where untyped `throws` (which erases to `any Error`) is
/// rejected.
///
/// HOST builds keep `send`'s untyped `throws` so existing conformers (e.g.
/// swift-libp2p's `SWIMTransportAdapter`, which propagates NIO/codec errors) stay
/// source-compatible.
public enum SWIMTransportError: Error, Sendable {
    /// The transport could not deliver the message; `reason` describes why.
    case sendFailed(reason: String)
}

extension SWIMTransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sendFailed(let reason):
            return "SendFailed(\(reason))"
        }
    }
}
#endif

public protocol SWIMTransport: Sendable {
    /// Sends a message to a member.
    ///
    /// - Parameters:
    ///   - message: The message to send
    ///   - member: The target member's ID
    /// - Throws: Transport errors if the send fails. Untyped on host (so a
    ///   conformer may surface any backend error); typed ``SWIMTransportError``
    ///   under Embedded, where untyped `throws` is unavailable.
    #if !hasFeature(Embedded)
    func send(_ message: SWIMMessage, to member: MemberID) async throws
    #else
    func send(_ message: SWIMMessage, to member: MemberID) async throws(SWIMTransportError)
    #endif

    /// Stream of incoming messages.
    ///
    /// Returns an async stream of received messages along with the sender's ID.
    /// The transport should decode incoming data using `SWIMMessageCodec.decode`.
    var incomingMessages: AsyncStream<(SWIMMessage, MemberID)> { get }

    /// The local address of this transport.
    ///
    /// Used to identify ourselves in the cluster.
    var localAddress: String { get }
}

// MARK: - Mock Transport for Testing

/// A mock transport for testing SWIM protocol logic.
///
/// Records sent messages and allows injecting received messages.
public final class MockTransport: SWIMTransport, Sendable {
    public let localAddress: String
    public let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>

    private let continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation
    private let state: FacadeLock<MockState>

    private struct MockState: Sendable {
        var sentMessages: [(SWIMMessage, MemberID)] = []
    }

    /// Creates a mock transport.
    ///
    /// - Parameter localAddress: The simulated local address
    public init(localAddress: String = "127.0.0.1:8000") {
        self.localAddress = localAddress
        self.state = FacadeLock(MockState())

        var cont: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    #if !hasFeature(Embedded)
    public func send(_ message: SWIMMessage, to member: MemberID) async throws {
        state.withLock { state in
            state.sentMessages.append((message, member))
        }
    }
    #else
    public func send(_ message: SWIMMessage, to member: MemberID) async throws(SWIMTransportError) {
        state.withLock { state in
            state.sentMessages.append((message, member))
        }
    }
    #endif

    /// Returns all messages that have been sent.
    public func getSentMessages() -> [(SWIMMessage, MemberID)] {
        state.withLock { $0.sentMessages }
    }

    /// Clears the sent message history.
    public func clearSentMessages() {
        state.withLock { state in
            state.sentMessages.removeAll()
        }
    }

    /// Simulates receiving a message.
    ///
    /// - Parameters:
    ///   - message: The message to receive
    ///   - sender: The sender's ID
    public func receive(_ message: SWIMMessage, from sender: MemberID) {
        continuation.yield((message, sender))
    }

    /// Finishes the incoming message stream.
    public func finish() {
        continuation.finish()
    }
}

// MARK: - Loopback Transport

/// A loopback transport that connects multiple SWIM instances in memory.
///
/// Useful for integration testing without network I/O.
public final class LoopbackTransport: SWIMTransport, Sendable {
    public let localAddress: String
    public let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>

    private let continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation
    private let state: FacadeLock<LoopbackState>

    private struct LoopbackState: Sendable {
        var peers: [String: LoopbackTransport] = [:]
        var localMemberID: MemberID?
    }

    /// Creates a loopback transport.
    ///
    /// - Parameter localAddress: The address of this node
    public init(localAddress: String) {
        self.localAddress = localAddress
        self.state = FacadeLock(LoopbackState())

        var cont: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Sets the local member ID for this transport.
    ///
    /// When set, this ID will be used as the sender identity
    /// instead of generating one from the local address.
    ///
    /// - Parameter memberID: The member ID to use as sender
    public func setLocalMemberID(_ memberID: MemberID) {
        state.withLock { $0.localMemberID = memberID }
    }

    #if !hasFeature(Embedded)
    public func send(_ message: SWIMMessage, to member: MemberID) async throws {
        let (peer, senderID) = state.withLock { state -> (LoopbackTransport?, MemberID) in
            let peer = state.peers[member.address]
            // Use configured MemberID if set, otherwise generate from address
            let id = state.localMemberID ?? MemberID(id: localAddress, address: localAddress)
            return (peer, id)
        }

        guard let peer else {
            throw SWIMError.transportError("No peer at \(member.address)")
        }

        peer.receive(message, from: senderID)
    }
    #else
    public func send(_ message: SWIMMessage, to member: MemberID) async throws(SWIMTransportError) {
        let (peer, senderID) = state.withLock { state -> (LoopbackTransport?, MemberID) in
            let peer = state.peers[member.address]
            // Use configured MemberID if set, otherwise generate from address
            let id = state.localMemberID ?? MemberID(id: localAddress, address: localAddress)
            return (peer, id)
        }

        guard let peer else {
            throw SWIMTransportError.sendFailed(reason: "No peer at \(member.address)")
        }

        peer.receive(message, from: senderID)
    }
    #endif

    /// Connects this transport to another loopback transport.
    ///
    /// - Parameter peer: The peer transport to connect to
    public func connect(to peer: LoopbackTransport) {
        state.withLock { state in
            state.peers[peer.localAddress] = peer
        }
    }

    /// Receives a message from another transport.
    internal func receive(_ message: SWIMMessage, from sender: MemberID) {
        continuation.yield((message, sender))
    }

    /// Disconnects from a peer.
    public func disconnect(from address: String) {
        state.withLock { state in
            _ = state.peers.removeValue(forKey: address)
        }
    }

    /// Finishes the incoming message stream.
    public func finish() {
        continuation.finish()
    }
}
