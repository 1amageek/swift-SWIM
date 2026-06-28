# swift-SWIM

A pure Swift implementation of the SWIM protocol (Scalable Weakly-consistent
Infection-style Process Group Membership) — membership management and failure
detection for large-scale distributed systems. Embedded-first: the gossip codec and
the value-type membership state machine are Foundation-free, and the byte currency
is `[UInt8]`.

> **Release status.** Current release: `1.2.4`.

## Features

- **Failure detection** — efficient node-failure detection via the ping / ping-req / ack protocol.
- **Gossip dissemination** — infection-style gossip for membership-update propagation.
- **Consistency** — incarnation numbers (saturating) for state-precedence management.
- **Hardened trust boundary** — refutation safety, `maxIncarnationDelta` / `maxMemberCount`
  sanity bounds, and an optional message authenticator; rejections are typed, never silent.
- **Embedded-first** — the `SWIMWire` codec + value-type `MembershipState` have no
  Foundation / `any`; typed throws; zero-copy parsing.

## Requirements

- Swift 6.2+
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+

## Installation

Add swift-SWIM to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-SWIM.git", from: "1.2.4")
]
```

Then add the product(s) you need to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["SWIM"]   // and/or "SWIMWire" (codec) / "SWIMTransportUDP" (UDP)
)
```

## Quick Start

```swift
import SWIM

// 1. Create a transport (implement SWIMTransport, or use SWIMUDPTransport)
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
    case .memberJoined(let member):    print("Joined: \(member)")
    case .memberSuspected(let member): print("Suspected: \(member)")
    case .memberFailed(let member):    print("Failed: \(member)")
    case .memberRecovered(let member): print("Recovered: \(member)")
    case .memberLeft(let id):          print("Left: \(id)")
    default:                           break
    }
}
```

## Products

This package ships three products following the Embedded-first 3-tier API design.

| Product | Tier | Import | Use it for |
|---------|------|--------|-----------|
| `SWIM` | Tier-1 facade | `import SWIM` | Run a cluster: `SWIMCluster`, `SWIMTransport`, events, config. |
| `SWIMWire` | Tier-3 codec | `import SWIMWire` | The Embedded-clean gossip codec + value-type `MembershipState`. Not pulled in by `import SWIM`. |
| `SWIMTransportUDP` | UDP transport | `import SWIMTransportUDP` | `SWIMUDPTransport`, a ready-made transport built on swift-nio-udp. |

## Architecture

Three layers. The Tier-1 `SWIM` facade owns synchronization, the clock, and
randomness; the Tier-3 `SWIMWire` codec + value-type `MembershipState` own no host
coupling and so compile under Embedded Swift.

```
┌─────────────────────────────────────────────────────────────┐
│  Tier-1 facade  (import SWIM)                                │
│  SWIMCluster (actor) — ping / ping-req / ack orchestration  │
│  MemberList (Mutex<MembershipState> + ContinuousClock)      │
│  Disseminator (Mutex<DisseminationState>)                   │
│  SuspicionTimer (actor), SWIMConfiguration, SWIMEvent       │
│  SWIMTransport (protocol), SWIMMessageAuthenticator         │
├─────────────────────────────────────────────────────────────┤
│  SWIMTransportUDP  (import SWIMTransportUDP)                 │
│  SWIMUDPTransport — built on NIOUDPTransport (swift-nio-udp)│
├─────────────────────────────────────────────────────────────┤
│  Tier-3 codec  (import SWIMWire)                            │
│  MembershipState (caller-locked value-type state machine)   │
│  Member / MemberID / MemberStatus / Incarnation             │
│  SWIMMessage / GossipPayload / SWIMMessageCodec             │
│  DisseminationState / BroadcastQueue, WriteBuffer/ReadBuffer │
│  - Embedded-clean: no Foundation, no `any`, typed throws    │
└─────────────────────────────────────────────────────────────┘
```

The failure-detection logic lives in `SWIMCluster` (ping / ping-req / ack
orchestration) over the value-type `MembershipState`; there is no separate
`FailureDetector` type. `import SWIM` re-exports only the curated value/identity
types (`Member` / `MemberID` / `MemberStatus` / `Incarnation`); a protocol
implementer imports `SWIMWire` for the codec. See `Sources/SWIM/CONTEXT.md` for the
load-bearing invariants.

### Protocol flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Protocol Period                          │
├─────────────────────────────────────────────────────────────┤
│  1. Select random member M                                  │
│  2. Send PING to M                                          │
│  3. Receive ACK → M is alive                                │
│  4. No ACK within timeout:                                  │
│     - Select k random members                               │
│     - Send PING-REQ(M) to each                             │
│     - Any ACK received → M is alive                        │
│     - No ACK → mark M as SUSPECT                           │
│  5. Piggyback membership updates on all messages            │
└─────────────────────────────────────────────────────────────┘

     ┌─────────┐
     │  ALIVE  │◄────────────────────────────┐
     └────┬────┘                             │
          │ no ack                     ack or │
          │                           refute  │
          ▼                                  │
     ┌─────────┐                             │
     │ SUSPECT │─────────────────────────────┤
     └────┬────┘                             │
          │ timeout                          │
          ▼                                  │
     ┌─────────┐                             │
     │  DEAD   │─────────────────────────────┘
     └─────────┘         rejoin
```

### Transport

Implement `SWIMTransport` to integrate the network layer, or use the ready-made
`SWIMUDPTransport` (from the `SWIMTransportUDP` product, built on swift-nio-udp):

```swift
public protocol SWIMTransport: Sendable {
    func send(_ message: SWIMMessage, to member: MemberID) async throws
    var incomingMessages: AsyncStream<(SWIMMessage, MemberID)> { get }
    var localAddress: String { get }
}
```

`SWIMMessageCodec.encode` (and `encodeToBytes`) `throw` a typed `SWIMCodecError`
(e.g. `.stringTooLong`) instead of trapping, so an over-long identifier or address
cannot crash the encoder.

### Wire format

```
Message header:  Type (1B) | SeqNum (8B)
Message types:   0x01 Ping (payload) | 0x02 PingRequest (target + payload)
                 0x03 Ack (target + payload) | 0x04 Nack (target)

GossipPayload:   Count (2B) | Updates[]
                 each update: MemberID len (2B) + ID | Address len (2B) + Address
                              | Status (1B) | Incarnation (8B)
```

### Configuration

```swift
var config = SWIMConfiguration()
config.protocolPeriod = .milliseconds(200)     // time between probes
config.pingTimeout = .milliseconds(100)        // ping response timeout
config.indirectProbeCount = 3                   // number of indirect probes
config.suspicionMultiplier = 5.0                // suspicion timeout multiplier
config.maxPayloadSize = 10                      // max updates per message
config.baseDisseminationLimit = 3               // base count (actual = base * log(N))
config.maxIncarnationDelta = 16                 // reject implausible incarnation jumps
config.maxMemberCount = 10_000                  // cap the member table
// config.authenticator = MyAuthenticator()     // optional message authentication
```

## Security

SWIM is, by default, an **unauthenticated** gossip protocol: any peer that can reach
the cluster can forge membership updates (e.g. claim a higher incarnation to mark a
member dead, or to make itself undetectable). swift-SWIM adds these defenses:

- **Refutation safety** — a refuted or recovered member is never erroneously marked
  dead. The suspicion-kill path requires the *exact* incarnation captured when
  suspicion started, and every recovery route (direct ack, gossiped recovery,
  self-refutation) cancels the running suspicion timer so it can never fire a stale kill.
- **Saturating incarnations** — incarnation numbers saturate at `UInt64.max` instead
  of wrapping, so a logical clock can never roll back and let stale state out-rank
  newer state. Saturation is observable via `Incarnation.isSaturated`.
- **Heuristic sanity bounds** — `maxIncarnationDelta` rejects implausibly large
  incarnation jumps and `maxMemberCount` caps the member table. The cap is enforced
  on **both** admission paths: gossiped updates and ping-sender admission (an
  unauthenticated ping sender is admitted through the same `applyGossip` trust
  boundary, not the trusting `update` path). Rejections are surfaced as typed
  `MemberListRejection` errors, never silently dropped.
- **Optional message authentication** — conform to `SWIMMessageAuthenticator` and
  inject it via `SWIMConfiguration.authenticator`. When set, outgoing messages are
  signed and incoming messages verified before their gossip is trusted; unverifiable
  datagrams are rejected.

```swift
struct MyAuthenticator: SWIMMessageAuthenticator {
    func sign(message: SWIMMessage) throws -> [UInt8] { /* compute MAC */ }
    func verify(message: SWIMMessage) -> Bool { /* check MAC */ }
}

var config = SWIMConfiguration()
config.authenticator = MyAuthenticator()
```

> **Residual limitation.** Without an authenticator, SWIM trusts unauthenticated
> wire data. The `maxIncarnationDelta` and `maxMemberCount` bounds are heuristic
> sanity limits, **not** authentication. For real protection against forged gossip,
> configure an `authenticator`.

## Performance

The `SWIMWire` codec is optimized for throughput with minimal allocations: zero-copy
parsing via `UnsafeRawBufferPointer` and a non-copyable `ReadBuffer`, `@inlinable`
encode/decode methods, and `reserveCapacity` to avoid reallocations.

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

Run the benchmarks:

```bash
swift test --filter Benchmark
```

## Testing

The `SWIMTests` and `SWIMTransportUDPTests` targets cover the facade, codec, and UDP
transport. The `Mock` / `Loopback` test transports drive the cluster without a real
network. Run with a timeout to guard against hangs:

```swift
// MockTransport for unit tests
let transport = MockTransport(localAddress: "127.0.0.1:8000")
transport.receive(message, from: sender)        // simulate an inbound message
let sent = transport.getSentMessages()           // inspect outbound messages

// LoopbackTransport for integration tests
let transport1 = LoopbackTransport(localAddress: "127.0.0.1:8000")
let transport2 = LoopbackTransport(localAddress: "127.0.0.1:8001")
transport1.connect(to: transport2)
transport2.connect(to: transport1)
```

```bash
swift test
```

## References

- [SWIM Paper (Cornell)](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
- [Lifeguard (HashiCorp)](https://arxiv.org/abs/1707.00788) — SWIM extensions
- [memberlist (Go)](https://github.com/hashicorp/memberlist)

## License

MIT License
