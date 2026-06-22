// SWIMCore
//
// The Embedded-clean SWIM gossip codec + membership state machine:
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
// This target is Foundation-free and existential-free ('any'-free); it operates
// on [UInt8] / UnsafeRawBufferPointer rather than Foundation Data, and uses typed
// throws (SWIMCodecError / SWIMAuthenticationError / MemberListRejection)
// throughout.
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
// host ContinuousClock; the orchestration actor (SWIMInstance); configuration math
// (SWIMConfiguration); the suspicion timer (Task/Duration-based); the transport
// protocol + mocks; SWIMEvent/SWIMError; and the Foundation Data/Codable bridges.
// Synchronization's `Mutex`, stdlib `ContinuousClock`, structured concurrency
// timers, and Foundation are NOT available / not desired under Embedded Swift, so
// those pieces stay adapter-side.
