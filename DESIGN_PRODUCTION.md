# swift-SWIM Production Design

## Overview

Production-ready implementation of swift-SWIM with real UDP transport, enhanced reliability, and observability features.

## Current State

```
swift-SWIM/
├── Core/           # Member, MemberStatus, Incarnation, MemberList
├── Messages/       # Message, Payload, MessageCodec, MessageBuffer
├── Detection/      # FailureDetector (deprecated), SuspicionTimer, ProbeTarget
├── Dissemination/  # Disseminator, BroadcastQueue
├── Instance/       # SWIMInstance, SWIMConfiguration, SWIMEvent
└── Transport/      # SWIMTransport (protocol), MockTransport, LoopbackTransport
```

**Status**: Core protocol logic complete, tested, optimized (zero-copy parsing)

## Production Requirements

### 1. Real Network Transport (P0)

UDP transport using Apple's Network framework.

### 2. Enhanced Reliability (P1)

- Connection state management
- Retry logic with backoff
- Graceful degradation

### 3. Discovery Integration (P2)

- Integration with mDNS for local network discovery
- Seed node configuration

### 4. Observability (P1)

- Metrics collection
- Structured logging
- Health checks

---

## Architecture

### Module Structure

```
swift-SWIM/
├── Sources/
│   ├── SWIM/                    # Core library (existing)
│   │   ├── Core/
│   │   ├── Messages/
│   │   ├── Detection/
│   │   ├── Dissemination/
│   │   ├── Instance/
│   │   └── Transport/
│   │       ├── SWIMTransport.swift      # Protocol definition
│   │       ├── MockTransport.swift      # For testing
│   │       └── LoopbackTransport.swift  # For testing
│   │
│   └── SWIMTransportUDP/        # New: UDP transport module
│       ├── UDPTransport.swift
│       ├── UDPSocket.swift
│       └── UDPConfiguration.swift
│
└── Tests/
    ├── SWIMTests/               # Existing
    └── SWIMTransportUDPTests/   # New
```

### Dependency Graph

```
            ┌───────────────────────┐
            │    Application        │
            └───────────┬───────────┘
                        │
            ┌───────────▼───────────┐
            │     SWIMInstance      │
            └───────────┬───────────┘
                        │ uses
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
  ┌──────────┐   ┌──────────┐   ┌──────────┐
  │MemberList│   │Disseminator│   │SuspicionTimer│
  └──────────┘   └──────────┘   └──────────┘
                        │
            ┌───────────▼───────────┐
            │   SWIMTransport       │◄─── Protocol
            └───────────┬───────────┘
                        │ implements
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
  ┌──────────┐   ┌──────────┐   ┌──────────┐
  │UDPTransport│  │MockTransport│  │LoopbackTransport│
  └─────┬─────┘   └──────────┘   └──────────┘
        │ uses
  ┌─────▼─────┐
  │ UDPSocket │
  └───────────┘
        │ uses
  ┌─────▼─────┐
  │  Network  │◄─── Apple Network framework
  └───────────┘
```

---

## Phase 1: UDP Transport

### 1.1 UDPSocket

Low-level UDP socket wrapper using Network framework.

```swift
/// Low-level UDP socket using Network framework.
public final class UDPSocket: Sendable {

    /// Configuration for the UDP socket.
    public struct Configuration: Sendable {
        /// Local port to bind to.
        public var port: UInt16

        /// Network interface to bind to (nil for all interfaces).
        public var interface: NWInterface?

        /// Whether to enable address reuse.
        public var reuseAddress: Bool

        /// Receive buffer size.
        public var receiveBufferSize: Int

        public init(
            port: UInt16,
            interface: NWInterface? = nil,
            reuseAddress: Bool = true,
            receiveBufferSize: Int = 65536
        ) { ... }
    }

    private struct State: Sendable {
        var listener: NWListener?
        var connections: [NWEndpoint: NWConnection]
        var isStarted: Bool
    }

    private let configuration: Configuration
    private let state = Mutex<State>(State(...))
    private let incomingContinuation: Mutex<AsyncStream<(Data, NWEndpoint)>.Continuation?>

    /// Stream of incoming datagrams.
    public let incoming: AsyncStream<(Data, NWEndpoint)>

    /// Starts the socket.
    public func start() async throws

    /// Stops the socket.
    public func stop() async

    /// Sends data to an endpoint.
    public func send(_ data: Data, to endpoint: NWEndpoint) async throws

    /// Sends data to a host:port string.
    public func send(_ data: Data, to address: String) async throws
}
```

### 1.2 UDPTransport

SWIM transport implementation using UDPSocket.

```swift
/// UDP transport for SWIM protocol.
public final class UDPTransport: SWIMTransport, Sendable {

    /// Configuration for UDP transport.
    public struct Configuration: Sendable {
        /// UDP socket configuration.
        public var socket: UDPSocket.Configuration

        /// Whether to log sent/received messages.
        public var enableLogging: Bool

        /// Maximum message size (default: 64KB).
        public var maxMessageSize: Int

        public static func `default`(port: UInt16) -> Configuration
    }

    public let localAddress: String
    public let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>

    private let socket: UDPSocket
    private let configuration: Configuration
    private let messageContinuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation

    public init(configuration: Configuration) throws

    public func start() async throws
    public func stop() async

    public func send(_ message: SWIMMessage, to member: MemberID) async throws
}
```

### 1.3 Wire Protocol

SWIM uses UDP datagrams. Each datagram contains one encoded SWIMMessage.

```
┌─────────────────────────────────────────────┐
│            UDP Datagram (≤64KB)             │
├─────────────────────────────────────────────┤
│  ┌────────────────────────────────────────┐ │
│  │          SWIMMessage (encoded)         │ │
│  │  ┌──────────┬──────────┬─────────────┐ │ │
│  │  │ Type(1B) │SeqNum(8B)│  Payload    │ │ │
│  │  └──────────┴──────────┴─────────────┘ │ │
│  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

### 1.4 Address Parsing

MemberID.address format: `host:port`

```swift
extension MemberID {
    /// Creates an NWEndpoint from the address.
    public func toEndpoint() -> NWEndpoint? {
        let parts = address.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            return nil
        }
        let host = NWEndpoint.Host(String(parts[0]))
        let portNum = NWEndpoint.Port(integerLiteral: port)
        return NWEndpoint.hostPort(host: host, port: portNum)
    }
}

extension NWEndpoint {
    /// Converts to SWIM address string (host:port).
    public func toSWIMAddress() -> String? {
        guard case .hostPort(let host, let port) = self else { return nil }
        return "\(host):\(port)"
    }
}
```

---

## Phase 2: Enhanced Reliability

### 2.1 Transport Errors

```swift
/// Errors that can occur during transport operations.
public enum SWIMTransportError: Error, Sendable {
    case notStarted
    case alreadyStarted
    case addressResolutionFailed(String)
    case sendFailed(underlying: Error)
    case receiveFailed(underlying: Error)
    case socketClosed
    case messageTooLarge(Int)
    case invalidAddress(String)
}
```

### 2.2 Connection Management

For UDP, "connections" are lightweight - just cached NWConnection instances.

```swift
/// Connection cache for efficient UDP sending.
internal final class ConnectionCache: Sendable {
    private struct State: Sendable {
        var connections: [String: NWConnection]
        var lastAccess: [String: Date]
    }

    private let state = Mutex<State>(State(...))
    private let maxConnections: Int
    private let ttl: Duration

    /// Gets or creates a connection for the given address.
    func connection(for address: String) async throws -> NWConnection

    /// Removes stale connections.
    func cleanup()
}
```

### 2.3 Retry with Backoff

```swift
/// Retry configuration for transport operations.
public struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts.
    public var maxAttempts: Int

    /// Initial backoff duration.
    public var initialBackoff: Duration

    /// Backoff multiplier.
    public var backoffMultiplier: Double

    /// Maximum backoff duration.
    public var maxBackoff: Duration

    public static let `default` = RetryConfiguration(
        maxAttempts: 3,
        initialBackoff: .milliseconds(10),
        backoffMultiplier: 2.0,
        maxBackoff: .milliseconds(100)
    )

    public static let none = RetryConfiguration(maxAttempts: 1, ...)
}

extension UDPTransport {
    /// Sends with retry.
    public func sendWithRetry(
        _ message: SWIMMessage,
        to member: MemberID,
        retry: RetryConfiguration = .default
    ) async throws
}
```

---

## Phase 3: Observability

### 3.1 Metrics

```swift
/// SWIM metrics collector.
public protocol SWIMMetrics: Sendable {
    /// Records a sent message.
    func recordMessageSent(type: SWIMMessage.MessageType, to: MemberID)

    /// Records a received message.
    func recordMessageReceived(type: SWIMMessage.MessageType, from: MemberID)

    /// Records a probe result.
    func recordProbeResult(_ result: ProbeResult, target: MemberID)

    /// Records member count.
    func recordMemberCount(alive: Int, suspect: Int, dead: Int)

    /// Records message encoding time.
    func recordEncodeTime(_ duration: Duration)

    /// Records message decoding time.
    func recordDecodeTime(_ duration: Duration)
}

/// Default no-op metrics implementation.
public final class NoOpMetrics: SWIMMetrics, Sendable {
    public static let shared = NoOpMetrics()
    // All methods are no-ops
}

/// In-memory metrics for testing and debugging.
public final class InMemoryMetrics: SWIMMetrics, Sendable {
    public struct Snapshot: Sendable {
        public var messagesSent: Int
        public var messagesReceived: Int
        public var probeResults: [ProbeResult: Int]
        // ...
    }

    public func snapshot() -> Snapshot
}
```

### 3.2 Logging

Use swift-log integration.

```swift
import Logging

extension SWIMInstance {
    /// Logger for this SWIM instance.
    public var logger: Logger { get set }
}

extension UDPTransport {
    /// Logger for this transport.
    public var logger: Logger { get set }
}
```

### 3.3 Health Checks

```swift
/// Health status of a SWIM instance.
public struct SWIMHealth: Sendable {
    /// Whether the instance is running.
    public var isRunning: Bool

    /// Number of alive members.
    public var aliveMembers: Int

    /// Number of suspect members.
    public var suspectMembers: Int

    /// Time since last successful probe.
    public var lastProbeTime: Date?

    /// Transport health.
    public var transportHealthy: Bool
}

extension SWIMInstance {
    /// Returns the current health status.
    public func health() -> SWIMHealth
}
```

---

## Phase 4: Discovery Integration

### 4.1 Discovery Protocol

```swift
/// Protocol for discovering SWIM cluster members.
public protocol SWIMDiscovery: Sendable {
    /// Discovers seed members.
    func discover() async throws -> [MemberID]

    /// Advertises this member.
    func advertise(_ member: Member) async throws

    /// Stops discovery.
    func stop() async
}
```

### 4.2 mDNS Discovery (separate module)

```swift
/// mDNS-based discovery for local networks.
public final class MDNSDiscovery: SWIMDiscovery, Sendable {

    /// Configuration for mDNS discovery.
    public struct Configuration: Sendable {
        /// Service type (e.g., "_swim._udp").
        public var serviceType: String

        /// Service domain (e.g., "local.").
        public var domain: String

        /// Discovery timeout.
        public var timeout: Duration

        public static let `default` = Configuration(
            serviceType: "_swim._udp",
            domain: "local.",
            timeout: .seconds(5)
        )
    }

    public init(configuration: Configuration = .default)

    public func discover() async throws -> [MemberID]
    public func advertise(_ member: Member) async throws
    public func stop() async
}
```

### 4.3 Static Seed Discovery

```swift
/// Static list of seed members.
public final class StaticDiscovery: SWIMDiscovery, Sendable {
    private let seeds: [MemberID]

    public init(seeds: [MemberID]) {
        self.seeds = seeds
    }

    public func discover() async throws -> [MemberID] {
        seeds
    }

    public func advertise(_ member: Member) async throws {
        // No-op for static discovery
    }

    public func stop() async {
        // No-op
    }
}
```

---

## API Usage Examples

### Basic Usage

```swift
import SWIM
import SWIMTransportUDP

// Create transport
let transport = try UDPTransport(
    configuration: .default(port: 7946)
)

// Create SWIM instance
let localMember = Member(
    id: MemberID(id: UUID().uuidString, address: "192.168.1.10:7946")
)

let swim = SWIMInstance(
    localMember: localMember,
    config: .default,
    transport: transport
)

// Start transport and SWIM
try await transport.start()
swim.start()

// Join cluster
try await swim.join(seeds: [
    MemberID(id: "seed1", address: "192.168.1.1:7946")
])

// Subscribe to events
Task {
    for await event in swim.events {
        switch event {
        case .memberJoined(let member):
            print("Member joined: \(member)")
        case .memberFailed(let member):
            print("Member failed: \(member)")
        default:
            break
        }
    }
}
```

### With mDNS Discovery

```swift
import SWIM
import SWIMTransportUDP
import SWIMDiscoveryMDNS

// Setup
let transport = try UDPTransport(configuration: .default(port: 7946))
let discovery = MDNSDiscovery(configuration: .default)

let localMember = Member(
    id: MemberID(id: UUID().uuidString, address: "192.168.1.10:7946")
)

let swim = SWIMInstance(
    localMember: localMember,
    config: .default,
    transport: transport
)

// Start
try await transport.start()
swim.start()

// Advertise ourselves
try await discovery.advertise(localMember)

// Discover and join
let seeds = try await discovery.discover()
if !seeds.isEmpty {
    try await swim.join(seeds: seeds)
}
```

### With Metrics

```swift
import SWIM
import SWIMTransportUDP

let metrics = InMemoryMetrics()
let transport = try UDPTransport(
    configuration: .default(port: 7946),
    metrics: metrics
)

// ... setup swim ...

// Check metrics periodically
Task {
    while true {
        try await Task.sleep(for: .seconds(60))
        let snapshot = metrics.snapshot()
        print("Messages sent: \(snapshot.messagesSent)")
        print("Messages received: \(snapshot.messagesReceived)")
    }
}
```

---

## Implementation Plan

### Phase 1: UDP Transport (Week 1)

| Task | Priority | Files |
|------|----------|-------|
| UDPSocket implementation | P0 | `UDPSocket.swift` |
| UDPConfiguration | P0 | `UDPConfiguration.swift` |
| UDPTransport implementation | P0 | `UDPTransport.swift` |
| Address parsing helpers | P0 | `AddressExtensions.swift` |
| Integration tests | P0 | `UDPTransportTests.swift` |

### Phase 2: Reliability (Week 2)

| Task | Priority | Files |
|------|----------|-------|
| Transport errors | P1 | `SWIMTransportError.swift` |
| Connection cache | P1 | `ConnectionCache.swift` |
| Retry with backoff | P1 | `RetryConfiguration.swift` |
| Tests | P1 | `ReliabilityTests.swift` |

### Phase 3: Observability (Week 2-3)

| Task | Priority | Files |
|------|----------|-------|
| Metrics protocol | P1 | `SWIMMetrics.swift` |
| InMemoryMetrics | P1 | `InMemoryMetrics.swift` |
| Logging integration | P1 | Update existing files |
| Health checks | P1 | `SWIMHealth.swift` |

### Phase 4: Discovery (Week 3-4)

| Task | Priority | Files |
|------|----------|-------|
| Discovery protocol | P2 | `SWIMDiscovery.swift` |
| StaticDiscovery | P2 | `StaticDiscovery.swift` |
| MDNSDiscovery (separate module) | P2 | New module |

---

## Testing Strategy

### Unit Tests

1. **UDPSocketTests** - Socket lifecycle, send/receive
2. **UDPTransportTests** - Message encoding/decoding over UDP
3. **ConnectionCacheTests** - Cache behavior, cleanup
4. **RetryTests** - Backoff calculation, retry logic

### Integration Tests

1. **LocalClusterTests** - Multiple SWIM instances on localhost
2. **FailureDetectionTests** - Detect simulated failures
3. **NetworkPartitionTests** - Handle network splits
4. **RejoinTests** - Member rejoins after failure

### Benchmark Tests

1. **ThroughputTests** - Messages per second
2. **LatencyTests** - Probe round-trip time
3. **ScaleTests** - Performance with 100+ members

---

## Package.swift Changes

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-SWIM",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "SWIM", targets: ["SWIM"]),
        .library(name: "SWIMTransportUDP", targets: ["SWIMTransportUDP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // Core SWIM library (no external dependencies)
        .target(
            name: "SWIM",
            path: "Sources/SWIM",
            exclude: ["CONTEXT.md"]
        ),

        // UDP Transport (depends on Network framework)
        .target(
            name: "SWIMTransportUDP",
            dependencies: [
                "SWIM",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SWIMTransportUDP"
        ),

        // Tests
        .testTarget(
            name: "SWIMTests",
            dependencies: ["SWIM"],
            path: "Tests/SWIMTests"
        ),
        .testTarget(
            name: "SWIMTransportUDPTests",
            dependencies: ["SWIMTransportUDP"],
            path: "Tests/SWIMTransportUDPTests"
        ),
    ]
)
```

---

## Verification Checklist

### Phase 1 Complete When:
- [ ] UDPSocket can bind to port and receive datagrams
- [ ] UDPSocket can send datagrams to arbitrary endpoints
- [ ] UDPTransport encodes/decodes SWIMMessage correctly
- [ ] Two SWIM instances can communicate over UDP
- [ ] Member can join cluster via UDP

### Phase 2 Complete When:
- [ ] Transport recovers from transient errors
- [ ] Retry with backoff works correctly
- [ ] Connection cache manages connections efficiently

### Phase 3 Complete When:
- [ ] Metrics are collected accurately
- [ ] Logs include relevant context
- [ ] Health checks return accurate status

### Phase 4 Complete When:
- [ ] StaticDiscovery returns configured seeds
- [ ] MDNSDiscovery finds peers on local network
- [ ] Discovery integrates smoothly with SWIMInstance
