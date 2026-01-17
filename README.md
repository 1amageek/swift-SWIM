# swift-SWIM

A pure Swift implementation of the SWIM protocol (Scalable Weakly-consistent Infection-style Process Group Membership).

## Overview

SWIM is a protocol for membership management and failure detection in large-scale distributed systems.

### Features

- **Failure Detection**: Efficient node failure detection via ping/ping-req/ack protocol
- **Gossip Dissemination**: Infection-style gossip for membership update propagation
- **Consistency Guarantees**: Incarnation numbers for state consistency management
- **High Performance**: Zero-copy parsing, @inlinable optimizations
- **Pure Swift**: No external dependencies, Swift 6.2+ compatible

## Requirements

- Swift 6.2+
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-SWIM.git", from: "1.0.0")
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: ["SWIM"]
)
```

## Quick Start

```swift
import SWIM

// 1. Create a transport (implement SWIMTransport protocol)
let transport = MyUDPTransport(localAddress: "192.168.1.1:8000")

// 2. Create a SWIM instance
let localMember = Member(id: MemberID(id: "node1", address: "192.168.1.1:8000"))
let swim = SWIMInstance(
    localMember: localMember,
    config: .default,
    transport: transport
)

// 3. Start and join the cluster
await swim.start()
try await swim.join(seeds: [seedMemberID])

// 4. Monitor membership changes
for await event in swim.events {
    switch event {
    case .memberJoined(let member):
        print("Joined: \(member)")
    case .memberSuspected(let member):
        print("Suspected: \(member)")
    case .memberFailed(let member):
        print("Failed: \(member)")
    case .memberRecovered(let member):
        print("Recovered: \(member)")
    case .memberLeft(let id):
        print("Left: \(id)")
    default:
        break
    }
}
```

## Architecture

```
Sources/SWIM/
├── Core/                      # Core types
│   ├── Member.swift           # MemberID, Member
│   ├── MemberStatus.swift     # Alive/Suspect/Dead
│   ├── Incarnation.swift      # Incarnation numbers
│   └── MemberList.swift       # Thread-safe member list
│
├── Messages/                  # Protocol messages
│   ├── Message.swift          # SWIMMessage (Ping/PingReq/Ack/Nack)
│   ├── Payload.swift          # GossipPayload
│   ├── MessageBuffer.swift    # Zero-copy buffers
│   └── MessageCodec.swift     # Binary encode/decode
│
├── Detection/                 # Failure detection
│   ├── FailureDetector.swift  # Ping/PingReq/Ack logic
│   ├── ProbeTarget.swift      # Probe results
│   └── SuspicionTimer.swift   # Suspicion timeouts
│
├── Dissemination/             # Gossip dissemination
│   ├── Disseminator.swift     # Dissemination management
│   └── BroadcastQueue.swift   # Priority queue
│
├── Instance/                  # Main instance
│   ├── SWIMInstance.swift     # SWIM actor
│   ├── SWIMConfiguration.swift # Configuration
│   └── SWIMEvent.swift        # Events
│
└── Transport/                 # Transport
    └── SWIMTransport.swift    # Protocol + mock implementation
```

## Protocol Flow

### Failure Detection Cycle

```
┌─────────────────────────────────────────────────────────────┐
│                    Protocol Period                          │
├─────────────────────────────────────────────────────────────┤
│  1. Select random member M                                  │
│  2. Send PING to M                                          │
│  3. Receive ACK → M is alive                                │
│  4. No ACK within timeout:                                  │
│     - Select k random members                               │
│     - Send PING-REQ(M) to each                              │
│     - Any ACK received → M is alive                         │
│     - No ACK → Mark M as SUSPECT                            │
│  5. Piggyback membership updates on all messages            │
└─────────────────────────────────────────────────────────────┘
```

### Member State Transitions

```
     ┌─────────┐
     │  ALIVE  │◄────────────────────────────┐
     └────┬────┘                             │
          │ No ACK                     ACK or │
          │                           refute  │
          ▼                                  │
     ┌─────────┐                             │
     │ SUSPECT │─────────────────────────────┤
     └────┬────┘                             │
          │ Timeout                          │
          ▼                                  │
     ┌─────────┐                             │
     │  DEAD   │─────────────────────────────┘
     └─────────┘         Rejoin
```

## Transport Implementation

Implement the `SWIMTransport` protocol to integrate the network layer:

```swift
public protocol SWIMTransport: Sendable {
    /// Send a message
    func send(_ message: SWIMMessage, to member: MemberID) async throws

    /// Stream of incoming messages
    var incomingMessages: AsyncStream<(SWIMMessage, MemberID)> { get }

    /// Local address
    var localAddress: String { get }
}
```

### UDP Implementation Example

```swift
final class UDPTransport: SWIMTransport, Sendable {
    let localAddress: String
    let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>
    private let continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation
    private let socket: UDPSocket

    init(localAddress: String) async throws {
        self.localAddress = localAddress

        var cont: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
        self.incomingMessages = AsyncStream { cont = $0 }
        self.continuation = cont

        self.socket = try await UDPSocket(address: localAddress)

        // Start receiving
        Task {
            for await (data, address) in socket.incoming {
                if let message = try? SWIMMessageCodec.decode(data) {
                    let sender = MemberID(id: address, address: address)
                    continuation.yield((message, sender))
                }
            }
        }
    }

    func send(_ message: SWIMMessage, to member: MemberID) async throws {
        let data = SWIMMessageCodec.encode(message)
        try await socket.send(data, to: member.address)
    }
}
```

## Configuration

```swift
var config = SWIMConfiguration()

// Protocol period (time between probes)
config.protocolPeriod = .milliseconds(200)

// Ping response timeout
config.pingTimeout = .milliseconds(100)

// Number of indirect probes
config.indirectProbeCount = 3

// Suspicion timeout multiplier
config.suspicionMultiplier = 5.0

// Maximum updates per message
config.maxPayloadSize = 10

// Base dissemination count (actual = base * log(N))
config.baseDisseminationLimit = 3
```

## Core Types

| Type | Description |
|------|-------------|
| `MemberID` | Unique member identifier (ID + address) |
| `Member` | Member with status and incarnation |
| `MemberStatus` | Alive, Suspect, Dead |
| `Incarnation` | Version number for consistency |
| `MemberList` | Thread-safe member collection |
| `SWIMMessage` | Protocol messages (Ping, PingReq, Ack, Nack) |
| `GossipPayload` | Updates piggybacked on messages |
| `SWIMInstance` | Main protocol instance (actor) |
| `SWIMTransport` | Network transport protocol |

## Testing

Test with mock transports:

```swift
// MockTransport for unit tests
let transport = MockTransport(localAddress: "127.0.0.1:8000")

// Simulate receiving a message
transport.receive(message, from: sender)

// Check sent messages
let sent = transport.getSentMessages()

// LoopbackTransport for integration tests
let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")
transport1.connect(to: transport2)
transport2.connect(to: transport1)
```

## Performance

### Optimization Techniques

- **Zero-copy parsing**: Direct memory access via `UnsafeRawBufferPointer` and non-copyable `ReadBuffer`
- **@inlinable annotations**: Applied to all encode/decode methods for compiler optimization
- **Pre-allocation**: `reserveCapacity()` to avoid collection reallocations

### Benchmark Results

Measured on Apple Silicon (M-series):

| Operation | Throughput | Latency |
|-----------|------------|---------|
| Ping decode (empty) | 8.73M ops/sec | 115 ns |
| Ping encode (empty) | 1.68M ops/sec | 595 ns |
| Decode from bytes | 8.6M ops/sec | 116 ns |
| Encode to bytes | 6.3M ops/sec | 160 ns |
| Ping decode (5 updates) | 658K ops/sec | 1.5 μs |
| Ping encode (5 updates) | 309K ops/sec | 3.2 μs |
| Round-trip (3 updates) | 301K ops/sec | 3.3 μs |
| MemberList update | 1.40M ops/sec | 716 ns |
| Random member selection (3/100) | 324K ops/sec | 3.1 μs |
| Disseminator enqueue+get | 84K ops/sec | 11.9 μs |

Run benchmarks:
```bash
swift test --filter Benchmark
```

## Wire Format

### Message Header
```
┌────────────┬────────────┐
│ Type (1B)  │ SeqNum(8B) │
└────────────┴────────────┘
```

### Message Types
- 0x01: Ping (payload)
- 0x02: PingRequest (target + payload)
- 0x03: Ack (target + payload)
- 0x04: Nack (target)

### GossipPayload Format
```
┌────────────┬─────────────────────────────────────────┐
│ Count (2B) │ Updates[]                               │
├────────────┼─────────────────────────────────────────┤
│            │ Each update:                            │
│            │ ├─ MemberID length (2B) + ID (variable) │
│            │ ├─ Address length (2B) + Address (var)  │
│            │ ├─ Status (1B)                          │
│            │ └─ Incarnation (8B)                     │
└────────────┴─────────────────────────────────────────┘
```

## Concurrency Model

| Component | Model | Reason |
|-----------|-------|--------|
| `SWIMInstance` | `actor` | User-facing API, async operations |
| `MemberList` | `Mutex<T>` | High-frequency internal access |
| `Disseminator` | `Mutex<T>` | High-frequency internal access |
| `SuspicionTimer` | `actor` | Async timer management |
| `FailureDetector` | `actor` | Probe state coordination |

## References

- [SWIM Paper (Cornell)](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
- [Lifeguard (HashiCorp)](https://arxiv.org/abs/1707.00788) - SWIM extensions
- [memberlist (Go)](https://github.com/hashicorp/memberlist)

## License

MIT License
