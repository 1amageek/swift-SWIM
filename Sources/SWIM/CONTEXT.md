# swift-SWIM

A pure Swift implementation of the SWIM (Scalable Weakly-consistent Infection-style Process Group Membership) protocol.

## Overview

This package ships three products following the Embedded-first 3-tier API design:

- **`SWIM`** (Tier-1 facade) — the orchestration actor `SWIMCluster`, the caller-locked
  state-machine holders, the transport protocol, and the Foundation bridges.
- **`SWIMWire`** (Tier-3 codec core) — the Embedded-clean gossip codec plus the
  caller-locked value-type membership state machine. A SEPARATE import: `import SWIM`
  re-exports only the value/identity types (Member/MemberID/MemberStatus/Incarnation,
  ...) via symbol-level `@_exported import`; it does NOT pull in the codec.
- **`SWIMTransportUDP`** (UDP transport) — `SWIMUDPTransport`, built on swift-nio-udp.

This module (`SWIM`, the Tier-1 facade) provides:
- Failure detection using ping/ping-req/ack protocol (`SWIMCluster`)
- Gossip-based membership dissemination
- Incarnation-based consistency mechanism
- Injectable transport protocol for networking

## Module Structure

```
Sources/SWIM/                     # Tier-1 facade (orchestration + state holders + bridges)
├── CONTEXT.md                    # This file
├── SWIM.swift                    # Module documentation + curated re-exports
├── MemberID+Data.swift           # Foundation Data bridge for MemberID
├── SWIMMessageCodec+Data.swift   # Foundation Data bridge for the codec
│
├── Core/
│   └── MemberList.swift          # Mutex+ContinuousClock holder around MembershipState
│
├── Detection/
│   └── SuspicionTimer.swift      # Suspicion timeout management (actor)
│
├── Dissemination/
│   └── Disseminator.swift        # Mutex holder around DisseminationState
│
├── Instance/
│   ├── SWIMCluster.swift         # Main orchestration actor
│   ├── SWIMConfiguration.swift   # Configuration options
│   └── SWIMEvent.swift           # Events for observers (and SWIMError)
│
├── Security/
│   └── SWIMMessageAuthenticator.swift # Optional message-authentication hook
│
└── Transport/
    └── SWIMTransport.swift        # Transport protocol + Mock/Loopback test transports

Sources/SWIMWire/                 # Tier-3 codec core (Embedded-clean: no Foundation/any)
├── SWIMWire.swift                # Module documentation
├── Member.swift                  # MemberID, Member, MembershipChange
├── MemberStatus.swift            # Alive/Suspect/Dead status
├── Incarnation.swift             # Incarnation number (saturating)
├── MembershipState.swift         # Caller-locked value-type state machine
├── MemberListError.swift         # Trust-boundary rejections (MemberListRejection)
├── Message.swift                 # SWIMMessage enum
├── Payload.swift                 # GossipPayload, MembershipUpdate
├── MessageCodec.swift            # Binary encoding/decoding (typed throws)
├── MessageBuffer.swift           # Zero-copy WriteBuffer / ReadBuffer
├── DisseminationState.swift      # Value-type dissemination bookkeeping
├── BroadcastQueue.swift          # Priority queue for updates
├── ProbeTarget.swift             # ProbeResult
├── MemberID+Bytes.swift          # [UInt8] codec helpers for MemberID
└── UTF8Validation.swift          # Strict UTF-8 decode

Sources/SWIMTransportUDP/         # UDP transport (swift-nio-udp)
└── SWIMTransportUDP.swift        # SWIMUDPTransport
```

## Key Types

### Tier-3 codec core (`import SWIMWire`)

| Type | Description |
|------|-------------|
| `MemberID` | Unique identifier for a member (id + address) |
| `Member` | A member with status and incarnation |
| `MemberStatus` | Alive, Suspect, or Dead |
| `Incarnation` | Saturating version number for consistency |
| `MembershipState` | Caller-locked value-type membership state machine (member table, incarnation/precedence, refutation safety, suspicion->dead, table cap, gossip trust boundary, deterministic probe enumeration) |
| `MemberListRejection` | Typed reasons a gossiped update is rejected |
| `SWIMMessage` | Protocol messages (Ping, PingReq, Ack, Nack) |
| `GossipPayload` | Membership updates piggybacked on messages |
| `SWIMMessageCodec` | Binary encode/decode (typed `SWIMCodecError`) |
| `DisseminationState` / `BroadcastQueue` | Value-type dissemination bookkeeping |
| `ProbeResult` | Outcome of a probe |

### Tier-1 facade (`import SWIM`)

| Type | Description |
|------|-------------|
| `SWIMCluster` | Main orchestration actor |
| `SWIMTransport` | Protocol for network transport |
| `MemberList` | `Mutex<MembershipState>` + `ContinuousClock` holder (host-only) |
| `Disseminator` | `Mutex<DisseminationState>` holder (host-only) |
| `SuspicionTimer` | Suspicion timeout management (actor) |
| `SWIMConfiguration` | Protocol parameters and trust bounds |
| `SWIMEvent` / `SWIMError` | Membership events / facade errors |
| `SWIMMessageAuthenticator` | Optional message-authentication hook |

## Protocol Flow

### Failure Detection Period

```
┌─────────────────────────────────────────────────────────────┐
│                    Protocol Period                           │
├─────────────────────────────────────────────────────────────┤
│  1. Select random member M                                   │
│  2. Send PING to M                                          │
│  3. If ACK received → M is alive                            │
│  4. If no ACK within timeout:                               │
│     - Select k random members                               │
│     - Send PING-REQ(M) to each                              │
│     - If any ACK received → M is alive                      │
│     - If no ACK → Mark M as SUSPECT                         │
│  5. Piggyback membership updates on all messages            │
└─────────────────────────────────────────────────────────────┘
```

### Member State Transitions

```
     ┌─────────┐
     │  ALIVE  │◄────────────────────────────┐
     └────┬────┘                             │
          │ no ack                    ack or │
          │                          refute  │
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

## Usage Example

```swift
import SWIM

// Create transport
let transport = MyTransport(localAddress: "192.168.1.1:8000")

// Create the SWIM cluster
let localMember = Member(id: MemberID(id: "node1", address: "192.168.1.1:8000"))
let swim = SWIMCluster(
    localMember: localMember,
    config: .default,
    transport: transport
)

// Start and join cluster
await swim.start()
try await swim.join(seeds: [seedMemberID])

// Handle events
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
    default:
        break
    }
}
```

## Concurrency Model

| Component | Model | Reason |
|-----------|-------|--------|
| `SWIMCluster` | `actor` | User-facing API, async operations |
| `MemberList` | `Mutex<MembershipState>` | High-frequency internal access |
| `Disseminator` | `Mutex<DisseminationState>` | High-frequency internal access |
| `SuspicionTimer` | `actor` | Manages async timers |
| `MembershipState` | value type (caller-locked) | Embedded-clean: no Mutex/clock/RNG; the caller drives it under a lock and injects `nowMillis` |

## Wire Format

### Message Format
```
┌────────────┬────────────┬─────────────────────────────────┐
│ Type (1B)  │ SeqNum(8B) │ Type-specific payload           │
├────────────┼────────────┼─────────────────────────────────┤
│ 0x01       │ ...        │ Ping: GossipPayload             │
│ 0x02       │ ...        │ PingReq: Target + GossipPayload │
│ 0x03       │ ...        │ Ack: Target + GossipPayload     │
│ 0x04       │ ...        │ Nack: Target                    │
└────────────┴────────────┴─────────────────────────────────┘
```

## Performance Optimizations

### Zero-Copy Parsing

The codec uses `ReadBuffer` (non-copyable) with `UnsafeRawBufferPointer` for direct memory access:

```swift
public struct ReadBuffer: ~Copyable {
    @usableFromInline let base: UnsafeRawPointer
    @usableFromInline let count: Int

    @inlinable
    public func readUInt64(at offset: Int) -> UInt64 {
        // Direct pointer reads without copying
    }
}
```

### Inlinable Annotations

All encoding/decoding methods are marked `@inlinable` for compiler optimization:

```swift
@inlinable
public func encode(to buffer: inout WriteBuffer) {
    buffer.writeUInt8(typeCode)
    buffer.writeUInt64(sequenceNumber)
    // ...
}
```

### Pre-allocated Collections

Arrays use `reserveCapacity` to avoid reallocations:

```swift
var updates: [MembershipUpdate] = []
updates.reserveCapacity(count)
```

### Benchmark Results

| Operation | Throughput |
|-----------|------------|
| Decode ping | 6.8M ops/sec |
| Encode ping | 1.6M ops/sec |
| Round-trip (3 updates) | 280K ops/sec |
| MemberList update | 1.5M ops/sec |

## References

- [SWIM Paper (Cornell)](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
- [Lifeguard (HashiCorp)](https://arxiv.org/abs/1707.00788)
- [memberlist (Go)](https://github.com/hashicorp/memberlist)
