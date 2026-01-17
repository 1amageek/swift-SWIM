# swift-SWIM

A pure Swift implementation of the SWIM (Scalable Weakly-consistent Infection-style Process Group Membership) protocol.

## Overview

This library provides:
- Failure detection using ping/ping-req/ack protocol
- Gossip-based membership dissemination
- Incarnation-based consistency mechanism
- Injectable transport protocol for networking

## Module Structure

```
Sources/SWIM/
├── CONTEXT.md              # This file
├── SWIM.swift              # Module documentation and re-exports
│
├── Core/
│   ├── Member.swift        # MemberID, Member, MembershipChange
│   ├── MemberStatus.swift  # Alive/Suspect/Dead status
│   ├── Incarnation.swift   # Incarnation number
│   └── MemberList.swift    # Thread-safe member list
│
├── Messages/
│   ├── Message.swift       # SWIMMessage enum
│   ├── Payload.swift       # GossipPayload, MembershipUpdate
│   └── MessageCodec.swift  # Binary encoding/decoding
│
├── Detection/
│   ├── ProbeTarget.swift       # ProbeResult, PendingProbe
│   └── SuspicionTimer.swift    # Suspicion timeout management
│
├── Dissemination/
│   ├── Disseminator.swift      # Gossip dissemination
│   └── BroadcastQueue.swift    # Priority queue for updates
│
├── Instance/
│   ├── SWIMInstance.swift      # Main SWIM instance (actor)
│   ├── SWIMConfiguration.swift # Configuration options
│   └── SWIMEvent.swift         # Events for observers
│
└── Transport/
    └── SWIMTransport.swift     # Transport protocol + mock implementations
```

## Key Types

| Type | Description |
|------|-------------|
| `MemberID` | Unique identifier for a member (id + address) |
| `Member` | A member with status and incarnation |
| `MemberStatus` | Alive, Suspect, or Dead |
| `Incarnation` | Version number for consistency |
| `MemberList` | Thread-safe collection of members |
| `SWIMMessage` | Protocol messages (Ping, PingReq, Ack, Nack) |
| `GossipPayload` | Membership updates piggybacked on messages |
| `SWIMInstance` | Main protocol instance (actor) |
| `SWIMTransport` | Protocol for network transport |

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

// Create SWIM instance
let localMember = Member(id: MemberID(id: "node1", address: "192.168.1.1:8000"))
let swim = SWIMInstance(
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
| `SWIMInstance` | `actor` | User-facing API, async operations |
| `MemberList` | `Mutex<T>` | High-frequency internal access |
| `Disseminator` | `Mutex<T>` | High-frequency internal access |
| `SuspicionTimer` | `actor` | Manages async timers |

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
