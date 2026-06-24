// SWIMWire
//
// Tier-3 codec core (renamed from SWIMCore). The Embedded-clean SWIM gossip
// codec + membership state machine:
//   - Wire codec: SWIMMessageCodec, SWIMMessage, GossipPayload, MembershipUpdate,
//     Member/MemberID, Incarnation, MemberStatus.
//   - Membership state machine (value types, caller-locked + clock-seam):
//     MembershipState (member table, incarnation/precedence rules, refutation
//     safety, suspicion->dead promotion, member-table cap, gossip trust boundary,
//     deterministic probe-target enumeration), DisseminationState, BroadcastQueue.
//   - Gossip-safety rejection types (MemberListRejection: incarnation/table-cap).
//   - The probe-result enum and the optional message-authenticator protocol
//     (typed throws, MAC seam).
//
// This is a SEPARATE import from the Tier-1 `SWIM` facade: `import SWIM` does NOT
// pull SWIMWire in. A protocol implementer asks for the codec deliberately with
// `import SWIMWire`. The facade re-publishes only the value/identity types
// (Member/MemberID/MemberStatus/Incarnation) via symbol-level @_exported import.
//
// This target is Foundation-free and existential-free ('any'-free); it operates
// on [UInt8] / UnsafeRawBufferPointer rather than Foundation Data, and uses typed
// throws (SWIMCodecError / MemberListRejection) throughout.
//
// Caller-locked + clock-seam pattern: the state machine is a pure value type with
// `mutating` methods. It contains NO Synchronization.Mutex, NO actor, NO
// ContinuousClock/Date, and NO system RNG. Time is INJECTED as a monotonic
// `nowMillis: UInt64` parameter; random probe selection is split into
// deterministic candidate enumeration here plus caller-side randomness. The
// caller owns synchronization and the clock.
//
// NOT in this target (host-only, see the SWIM adapter): the caller-locked holders
// (MemberList, Disseminator) that wrap these value types in a `Mutex` and read the
// host ContinuousClock; the orchestration actor (SWIMCluster); configuration math
// (SWIMConfiguration); the suspicion timer (Task/Duration-based); the transport
// protocol + mocks; SWIMEvent/SWIMError; and the Foundation Data/Codable bridges.
// Synchronization's `Mutex`, stdlib `ContinuousClock`, structured concurrency
// timers, and Foundation are NOT available / not desired under Embedded Swift, so
// those pieces stay adapter-side.
