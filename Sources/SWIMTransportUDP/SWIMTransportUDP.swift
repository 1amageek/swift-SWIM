/// SWIM UDP Transport
///
/// Adapts NIOUDPTransport to SWIMTransport protocol for real network communication.

import Foundation
import SWIM
import NIOUDPTransport
import NIOCore
import Synchronization

/// UDP transport implementation for SWIM protocol.
///
/// Uses `NIOUDPTransport` from swift-nio-udp for actual network communication.
///
/// ## Lifecycle
/// This transport is **single-use**: once `stop()` is called, the transport cannot be
/// restarted. Create a new instance if you need to restart communication.
///
/// ## Performance Optimizations
/// - Zero-copy message decoding via ByteBuffer
/// - Address caching to avoid repeated string parsing
/// - Bounded AsyncStream buffer to prevent memory growth
/// - Minimized lock contention in receive path
///
/// ## Example
/// ```swift
/// let transport = SWIMUDPTransport(port: 7946)
/// try await transport.start()
///
/// let swim = SWIMInstance(
///     localMember: Member(id: MemberID(id: "node1", address: transport.localAddress)),
///     config: .default,
///     transport: transport
/// )
///
/// swim.start()
/// ```
public final class SWIMUDPTransport: SWIMTransport, Sendable {

    // MARK: - Properties

    private let udp: NIOUDPTransport
    private let state: Mutex<State>
    private let messageContinuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation

    /// Stream of incoming SWIM messages.
    public let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>

    /// Cache for parsed socket addresses to avoid repeated parsing.
    private let addressCache: Mutex<AddressCache>

    private struct State: Sendable {
        var localAddress: String
        var isStarted: Bool = false
        var isStopped: Bool = false  // Once stopped, cannot restart
        var receiveTask: Task<Void, Never>?
    }

    /// LRU cache for socket addresses.
    private struct AddressCache: Sendable {
        private var cache: [String: SocketAddress] = [:]
        private var accessOrder: [String] = []
        private let maxSize: Int

        init(maxSize: Int = 128) {
            self.maxSize = maxSize
        }

        mutating func get(_ address: String) -> SocketAddress? {
            if let cached = cache[address] {
                // Move to end (most recently used)
                if let idx = accessOrder.firstIndex(of: address) {
                    accessOrder.remove(at: idx)
                    accessOrder.append(address)
                }
                return cached
            }
            return nil
        }

        mutating func set(_ address: String, _ socketAddress: SocketAddress) {
            if cache[address] != nil {
                // Already exists, just update access order
                if let idx = accessOrder.firstIndex(of: address) {
                    accessOrder.remove(at: idx)
                    accessOrder.append(address)
                }
                return
            }

            // Evict oldest if at capacity
            if cache.count >= maxSize, let oldest = accessOrder.first {
                accessOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }

            cache[address] = socketAddress
            accessOrder.append(address)
        }
    }

    // MARK: - SWIMTransport

    /// The local address of this transport.
    ///
    /// Format: "host:port" (e.g., "192.168.1.10:7946")
    public var localAddress: String {
        state.withLock { $0.localAddress }
    }

    // MARK: - Initialization

    /// Creates a new SWIM UDP transport.
    ///
    /// - Parameters:
    ///   - host: The host to bind to (default: "0.0.0.0" for all interfaces)
    ///   - port: The port to bind to
    ///   - bufferSize: Maximum number of messages to buffer (default: 256)
    public init(host: String = "0.0.0.0", port: Int, bufferSize: Int = 256) {
        let config = UDPConfiguration(
            bindAddress: .specific(host: host, port: port),
            reuseAddress: true,
            reusePort: false
        )
        self.udp = NIOUDPTransport(configuration: config)
        self.state = Mutex(State(localAddress: "\(host):\(port)"))
        self.addressCache = Mutex(AddressCache())

        // Use bounded buffer to prevent memory growth under load
        var continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
        self.incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    /// Creates a new SWIM UDP transport with custom configuration.
    ///
    /// - Parameters:
    ///   - configuration: UDP configuration
    ///   - bufferSize: Maximum number of messages to buffer (default: 256)
    public init(configuration: UDPConfiguration, bufferSize: Int = 256) {
        self.udp = NIOUDPTransport(configuration: configuration)

        let address: String
        switch configuration.bindAddress {
        case .any(let port):
            address = "0.0.0.0:\(port)"
        case .specific(let host, let port):
            address = "\(host):\(port)"
        case .ipv4Any(let port):
            address = "0.0.0.0:\(port)"
        case .ipv6Any(let port):
            address = "[::]:\(port)"
        }

        self.state = Mutex(State(localAddress: address))
        self.addressCache = Mutex(AddressCache())

        // Use bounded buffer to prevent memory growth under load
        var continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
        self.incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Starts the transport.
    ///
    /// Binds to the configured address and begins receiving messages.
    ///
    /// - Throws: `SWIMError.transportError` if already started or if binding fails
    /// - Important: This method can only be called once. The transport is single-use.
    public func start() async throws {
        // Guard against double-start and restart after stop
        let (alreadyStarted, alreadyStopped) = state.withLock { state in
            if state.isStopped { return (false, true) }
            if state.isStarted { return (true, false) }
            state.isStarted = true
            return (false, false)
        }
        guard !alreadyStopped else {
            throw SWIMError.transportError("Transport already stopped and cannot be restarted")
        }
        guard !alreadyStarted else {
            throw SWIMError.transportError("Transport already started")
        }

        do {
            try await udp.start()
        } catch {
            // Reset state on failure
            state.withLock { $0.isStarted = false }
            throw error
        }

        // Update local address with actual bound address
        if let boundAddr = await udp.localAddress,
           let addrString = boundAddr.hostPortString {
            state.withLock { $0.localAddress = addrString }
        }

        // Start receive loop
        let task = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }

        state.withLock { $0.receiveTask = task }
    }

    /// Stops the transport.
    ///
    /// Closes the socket and stops receiving messages.
    public func stop() async {
        let task = state.withLock { state in
            state.isStarted = false
            state.isStopped = true  // Mark as permanently stopped
            let t = state.receiveTask
            state.receiveTask = nil
            return t
        }

        task?.cancel()
        await udp.stop()
        messageContinuation.finish()
    }

    // MARK: - SWIMTransport

    /// Sends a SWIM message to a member.
    ///
    /// - Parameters:
    ///   - message: The message to send
    ///   - member: The target member
    /// - Throws: `SWIMError.transportError` if sending fails
    public func send(_ message: SWIMMessage, to member: MemberID) async throws {
        // Check transport state
        let (isStarted, isStopped) = state.withLock { ($0.isStarted, $0.isStopped) }
        guard !isStopped else {
            throw SWIMError.transportError("Transport is stopped")
        }
        guard isStarted else {
            throw SWIMError.transportError("Transport not started")
        }

        let data = SWIMMessageCodec.encode(message)

        do {
            // Use cached address or parse and cache
            let address: SocketAddress = try addressCache.withLock { cache in
                if let cached = cache.get(member.address) {
                    return cached
                }
                let parsed = try SocketAddress(hostPort: member.address)
                cache.set(member.address, parsed)
                return parsed
            }
            try await udp.send(data, to: address)
        } catch let error as SWIMError {
            throw error
        } catch {
            throw SWIMError.transportError("Failed to send to \(member.address): \(error)")
        }
    }

    // MARK: - Private

    private func receiveLoop() async {
        for await datagram in udp.incomingDatagrams {
            // Skip datagrams with unknown sender address to preserve SWIM membership semantics
            guard let senderAddress = datagram.remoteAddress.hostPortString else {
                #if DEBUG
                print("SWIMTransportUDP: Skipping datagram with unknown sender address")
                #endif
                continue
            }

            do {
                // Zero-copy decoding: use ByteBuffer directly without copying to Data
                let message = try datagram.buffer.withUnsafeReadableBytes { ptr in
                    try SWIMMessageCodec.decode(ptr)
                }
                let senderID = MemberID(id: senderAddress, address: senderAddress)

                // Yield directly without lock - AsyncStream.Continuation is thread-safe
                _ = messageContinuation.yield((message, senderID))
            } catch {
                // Log decode error but continue receiving
                #if DEBUG
                print("SWIMTransportUDP: Failed to decode message from \(senderAddress): \(error)")
                #endif
            }
        }
    }
}
