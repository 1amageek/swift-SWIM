# SWIM — CONTEXT
Scope/role: the `SWIM` Tier-1 facade — the `SWIMCluster` orchestration actor, the
caller-locked state-machine holders, the transport protocol, and the Foundation
bridges — over the Embedded-clean `SWIMWire` codec / value-type state machine.
Depended on by cluster-membership callers (libp2p peer discovery) and by
`SWIMTransportUDP`.
Last reviewed: 2026-06-25

Invariants and design intent that the source does not state structurally. Read this
before changing the failure detector (`Sources/SWIM`) or the codec / state machine
(`Sources/SWIMWire`). This is an Embedded-first package: `SWIMWire` (codec + the
value-type `MembershipState`) must stay Foundation-free and lock-free, while the
host coupling (`Mutex`, `ContinuousClock`, the system RNG, NIO) lives only in the
`SWIM` facade. The README is the structural reference (file tree, type tables, wire
format, usage); this file is the contract.

## Contracts (the load-bearing rules)

- **`MembershipState` is a pure value type, caller-locked, clock-injected.** It is a
  `struct` with `mutating` methods; it holds NO lock, reads NO clock, draws NO
  randomness. The caller is "the thing that locks": `MemberList` wraps it in a
  `Synchronization.Mutex` and supplies the monotonic time as a `nowMillis: UInt64`
  parameter (measured from a fixed epoch); the random probe selectors live in the
  facade and pick from the core's deterministic candidate enumeration. Do not make
  `MembershipState` a reference type and do not give it a lock, a clock, or an RNG.
- **`SWIMWire` is the codec + state machine; `SWIM` is the host facade — keep the
  split.** `import SWIM` re-exports only the curated value/identity types
  (`Member` / `MemberID` / `MemberStatus` / `Incarnation`) via symbol-level
  `@_exported import`; it does NOT re-export the codec (`SWIMMessageCodec`,
  `SWIMMessage`, `GossipPayload`, `WriteBuffer`, ...). A protocol implementer or a
  transport imports `SWIMWire` deliberately. `SWIMTransportUDP` depends on
  `SWIMWire` directly for the codec.
- **`update(_:nowMillis:)` trusts its input; `applyGossip(...)` does not.** Use
  `update` only for locally-originated state. Anything arriving over the wire —
  gossip payloads AND the admission of a ping sender — must go through
  `applyGossip`, the trust boundary. Do not route unauthenticated wire state through
  the trusting `update` path.

## Invariants (must hold; tests guard them)

- **Incarnation precedence: higher incarnation always wins; on a tie, higher
  severity wins (dead > suspect > alive).** This is the single ordering rule
  (`shouldApplyUpdate`); every apply path obeys it. Incarnations saturate at
  `UInt64.max` (never wrap), so the logical clock can never roll back and let stale
  state out-rank newer state.
- **Refutation safety — a refuted or recovered member is never erroneously killed.**
  The suspicion-kill path (`markDead`) applies only when the member is STILL
  `.suspect` at the EXACT incarnation captured when suspicion started; any
  refutation (status → `.alive` or an incarnation bump) fails the strict equality
  check and invalidates the pending kill. `markAlive` requires a strictly higher
  incarnation to refute.
- **Every recovery route cancels the running suspicion timer.** `SuspicionTimer`
  starts a per-member timer (cancelling any prior one for that member) carrying the
  captured incarnation; a direct ack, gossiped recovery, or self-refutation cancels
  it so it can never fire a stale kill. Do not add a recovery path that leaves the
  timer running.
- **The `maxMemberCount` cap is enforced on BOTH admission paths.** A brand-new
  member is rejected once the table holds `maxMemberCount` members — and this is
  checked in `applyGossip` for gossiped updates AND for ping-sender admission
  (`handlePing` admits the unauthenticated sender through `applyGossip`, NOT the
  trusting `update`). GC only reclaims dead members, so without the cap a flood of
  forged `alive` members grows the table unbounded. Do not let the ping path bypass
  the cap.
- **`maxIncarnationDelta` bounds implausible forward jumps.** `applyGossip` rejects
  an update whose incarnation is more than `maxIncarnationDelta` ahead of the
  locally known value (a fresh member is "known" at `.initial`). A forged high
  incarnation would otherwise win every conflict and could mark any member dead.
- **Rejections are surfaced, never silently dropped.** A sanity-bound violation
  throws a typed `MemberListRejection` (`.incarnationJumpTooLarge`,
  `.memberTableFull`); the facade yields it as a `SWIMEvent.error` and continues —
  it does not silently swallow the rejected update.
- **These bounds are heuristic, NOT authentication.** Without a configured
  `SWIMMessageAuthenticator`, SWIM trusts unauthenticated wire data; the caps only
  limit blast radius. When an authenticator is set, an unverifiable message is
  rejected before its gossip is trusted.

## Embedded constraints (do not regress)

- **`SWIMWire` is the Embedded-clean target: no Foundation, no `any`, typed
  throws.** Its codec uses zero-copy non-copyable buffers (`WriteBuffer` /
  `ReadBuffer`). The Embedded build is `P2P_CORE_EMBEDDED=1 swiftly run +6.3.1
  swift build --target SWIMWire`.
- **The `Mutex` / `ContinuousClock`-backed holders stay in the `SWIM` facade.**
  `Synchronization.Mutex` and stdlib `ContinuousClock` are NOT available under
  Embedded Swift 6.3.1, so `MemberList`, `Disseminator`, the `SuspicionTimer` actor,
  and `SWIMCluster` live in `SWIM` (host-only) — never push them down into
  `SWIMWire`. The Foundation `Data` bridges (`MemberID+Data`,
  `SWIMMessageCodec+Data`) are likewise facade-only.

## Dependencies & seams

- `SWIM` depends on `SWIMWire`. `SWIMTransportUDP` depends on `SWIM` + `SWIMWire`
  (codec) + `NIOUDPTransport`. There is no separate `FailureDetector` type — the
  ping / ping-req / ack orchestration lives in `SWIMCluster` over `MembershipState`.
- `SWIMTransport` is the injected transport protocol (`send(_:to:)` +
  `incomingMessages` + `localAddress`); `Mock` / `Loopback` test transports and
  `SWIMUDPTransport` implement it.
- `SWIMMessageAuthenticator` is the optional injected sign / verify hook; when set,
  outgoing canonical authentication bytes (`sender MemberID` + canonical inner
  message) are signed, carried in an authenticated envelope, and incoming sender +
  canonical bytes + token are verified before gossip is trusted. The envelope sender
  must match the transport sender.

## Wire protocol notes

- Message framing: type (1B) + sequence number (8B) + type-specific payload. Type
  codes: `0x01` Ping, `0x02` PingRequest, `0x03` Ack, `0x04` Nack, `0x05`
  authenticated envelope (`token length + token + sender MemberID + inner message`);
  a type code `> 0x05` throws `SWIMCodecError.invalidMessageType`.
- `SWIMMessageCodec` decode enforces a message-size ceiling
  (`SWIMCodecError.messageTooLarge`) and rejects truncated input
  (`SWIMCodecError.truncatedMessage`); encode throws (`.stringTooLong`) rather than
  trapping on an over-long identifier / address. `GossipPayload` is a 2-byte count
  followed by length-prefixed `MemberID` + address, a 1-byte status, and an 8-byte
  incarnation per update.

## Build

- Host: `swift build` (Swift tools 6.2, platform floor macOS 15).
- Embedded codec: `P2P_CORE_EMBEDDED=1 swiftly run +6.3.1 swift build --target SWIMWire`.
