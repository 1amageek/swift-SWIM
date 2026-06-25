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

## Products

This package ships three products following the Embedded-first 3-tier API design:

| Product | Tier | Import | Use it for |
|---------|------|--------|-----------|
| `SWIM` | Tier-1 facade | `import SWIM` | Run a cluster: `SWIMCluster`, `SWIMTransport`, events, config. |
| `SWIMWire` | Tier-3 codec | `import SWIMWire` | The Embedded-clean gossip codec + value-type `MembershipState`. Not pulled in by `import SWIM`. |
| `SWIMTransportUDP` | UDP transport | `import SWIMTransportUDP` | `SWIMUDPTransport`, a ready-made transport built on swift-nio-udp. |

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-SWIM.git", from: "1.2.0")
]
```

> **Note:** The `SWIMCluster` / `SWIMWire` / `SWIMUDPTransport` API documented here
> lives on the unreleased `embedded` branch. The released `1.2.0` ships the prior
> API (`SWIMInstance`, a 2-product package). Until the embedded API is tagged,
> depend on the branch:
> `.package(url: "https://github.com/1amageek/swift-SWIM.git", branch: "embedded")`.

```swift
.target(
    name: "YourTarget",
    dependencies: ["SWIM"]   // and/or "SWIMWire" (codec) / "SWIMTransportUDP" (UDP)
)
```

## Quick Start

```swift
import SWIM

// 1. Create a transport (implement SWIMTransport protocol)
let transport = MyUDPTransport(localAddress: "192.168.1.1:8000")

// 2. Create the SWIM cluster
let localMember = Member(id: MemberID(id: "node1", address: "192.168.1.1:8000"))
let swim = SWIMCluster(
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
Sources/SWIM/                  # Tier-1 facade (orchestration + state holders + bridges)
├── SWIM.swift                 # Module documentation + curated re-exports
├── MemberID+Data.swift        # Foundation Data bridge for MemberID
├── SWIMMessageCodec+Data.swift # Foundation Data bridge for the codec
│
├── Core/
│   └── MemberList.swift       # Mutex<MembershipState> + ContinuousClock holder
│
├── Detection/
│   └── SuspicionTimer.swift   # Suspicion timeouts (actor)
│
├── Dissemination/
│   └── Disseminator.swift     # Mutex<DisseminationState> holder
│
├── Instance/
│   ├── SWIMCluster.swift      # SWIM orchestration actor
│   ├── SWIMConfiguration.swift # Configuration
│   └── SWIMEvent.swift        # Events (and SWIMError)
│
├── Security/
│   └── SWIMMessageAuthenticator.swift # Optional message-authentication hook
│
└── Transport/
    └── SWIMTransport.swift    # Protocol + Mock/Loopback test transports

Sources/SWIMWire/             # Tier-3 codec core (Embedded-clean: no Foundation/any)
├── SWIMWire.swift            # Module documentation
├── Member.swift              # MemberID, Member, MembershipChange
├── MemberStatus.swift        # Alive/Suspect/Dead
├── Incarnation.swift         # Incarnation numbers (saturating)
├── MembershipState.swift     # Caller-locked value-type state machine
├── MemberListError.swift     # Trust-boundary rejections (MemberListRejection)
├── Message.swift             # SWIMMessage (Ping/PingReq/Ack/Nack)
├── Payload.swift             # GossipPayload, MembershipUpdate
├── MessageCodec.swift        # Binary encode/decode (typed throws)
├── MessageBuffer.swift       # Zero-copy WriteBuffer / ReadBuffer
├── DisseminationState.swift  # Value-type dissemination bookkeeping
├── BroadcastQueue.swift      # Priority queue
├── ProbeTarget.swift         # ProbeResult
├── MemberID+Bytes.swift      # [UInt8] codec helpers
└── UTF8Validation.swift      # Strict UTF-8 decode

Sources/SWIMTransportUDP/     # UDP transport (swift-nio-udp)
└── SWIMTransportUDP.swift    # SWIMUDPTransport
```

> The failure-detection logic lives in `SWIMCluster` (ping / ping-req / ack
> orchestration) over the value-type `MembershipState`; there is no separate
> `FailureDetector` type.

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
                do {
                    let message = try SWIMMessageCodec.decode(data)
                    let sender = MemberID(id: address, address: address)
                    continuation.yield((message, sender))
                } catch {
                    // Drop undecodable datagrams; do not swallow silently in production.
                    continue
                }
            }
        }
    }

    func send(_ message: SWIMMessage, to member: MemberID) async throws {
        let data = try SWIMMessageCodec.encode(message)
        try await socket.send(data, to: member.address)
    }
}
```

> `SWIMMessageCodec.encode` (and `encodeToBytes`) now `throw`. They surface a
> typed `SWIMCodecError` (e.g. `.stringTooLong`) instead of trapping, so an
> over-long identifier or address cannot crash the encoder.

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

// Maximum plausible forward jump in a gossiped incarnation.
// Gossip whose incarnation is more than this many steps ahead of the
// locally known value is rejected (MemberListRejection.incarnationJumpTooLarge)
// rather than silently trusted. Default: 16
config.maxIncarnationDelta = 16

// Maximum number of members the table will hold. Bounds memory growth from a
// flood of (potentially forged) members. Joins beyond this cap are rejected
// (MemberListRejection.memberTableFull). Default: 10000
config.maxMemberCount = 10_000

// Optional message authenticator (see "Security" below). Default: nil
// config.authenticator = MyAuthenticator()
```

## Security

SWIM is, by default, an **unauthenticated** gossip protocol: any peer that can
reach the cluster can forge membership updates (e.g. claim a higher incarnation
to mark a member dead, or to make itself undetectable). swift-SWIM adds the
following defenses:

- **Refutation safety**: A refuted or recovered member is never erroneously
  marked dead. The suspicion-kill path requires the *exact* incarnation captured
  when suspicion started, and every recovery route (direct ack, gossiped
  recovery, self-refutation) cancels the running suspicion timer so it can never
  fire a stale kill.
- **Saturating incarnations**: Incarnation numbers saturate at `UInt64.max`
  instead of wrapping, so a logical clock can never roll back and let stale
  state out-rank newer state. Saturation is observable via `Incarnation.isSaturated`.
- **Heuristic sanity bounds**: `maxIncarnationDelta` rejects implausibly large
  incarnation jumps and `maxMemberCount` caps the member table. Rejections are
  surfaced as typed `MemberListRejection` errors, never silently dropped.
- **Optional message authentication**: Conform to `SWIMMessageAuthenticator`
  and inject it via `SWIMConfiguration.authenticator`. When set, outgoing
  messages are signed (`sign(message:)`) and incoming messages are verified
  (`verify(message:)`) before their gossip is trusted; unverifiable datagrams
  are rejected.

```swift
struct MyAuthenticator: SWIMMessageAuthenticator {
    func sign(message: SWIMMessage) throws -> [UInt8] { /* compute MAC */ }
    func verify(message: SWIMMessage) -> Bool { /* check MAC */ }
}

var config = SWIMConfiguration()
config.authenticator = MyAuthenticator()
```

> **Residual limitation**: Without an authenticator, SWIM trusts unauthenticated
> wire data. The `maxIncarnationDelta` and `maxMemberCount` bounds are heuristic
> sanity limits, **not** authentication. For real protection against forged
> gossip, configure an `authenticator`.

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
| `MembershipState` | Caller-locked value-type membership state machine (`SWIMWire`) |
| `SWIMCluster` | Main protocol orchestration actor |
| `SWIMTransport` | Network transport protocol |
| `SWIMUDPTransport` | UDP transport built on swift-nio-udp (`SWIMTransportUDP`) |
| `SWIMConfiguration` | Protocol parameters and trust bounds |
| `SWIMMessageAuthenticator` | Optional message-authentication hook |
| `MemberListRejection` | Typed reasons a gossiped update is rejected |
| `SWIMCodecError` | Typed encode/decode errors |

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
| `SWIMCluster` | `actor` | User-facing API, async operations, probe coordination |
| `MemberList` | `Mutex<MembershipState>` | High-frequency internal access |
| `Disseminator` | `Mutex<DisseminationState>` | High-frequency internal access |
| `SuspicionTimer` | `actor` | Async timer management |
| `MembershipState` | value type (caller-locked) | Embedded-clean: no Mutex/clock/RNG; caller drives it under a lock |

## References

- [SWIM Paper (Cornell)](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
- [Lifeguard (HashiCorp)](https://arxiv.org/abs/1707.00788) - SWIM extensions
- [memberlist (Go)](https://github.com/hashicorp/memberlist)

## License

MIT License
