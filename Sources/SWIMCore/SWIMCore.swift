// SWIMCore
//
// The Embedded-clean SWIM gossip codec + membership value/safety types:
// the wire codec (SWIMMessageCodec, SWIMMessage, GossipPayload, MembershipUpdate,
// Member/MemberID, Incarnation, MemberStatus), the gossip-safety rejection types
// (MemberListRejection with the incarnation/table-cap reasons), the probe-result
// enum, and the optional message-authenticator protocol (typed throws, MAC seam).
//
// This target is Foundation-free and existential-free ('any'-free); it operates
// on [UInt8] / UnsafeRawBufferPointer rather than Foundation Data, and uses
// typed throws (SWIMCodecError / SWIMAuthenticationError) throughout.
//
// NOT in this target (host-only, see the SWIM adapter): the Mutex/ContinuousClock
// -backed membership state machine (MemberList, Disseminator, BroadcastQueue),
// the orchestration actor (SWIMInstance), configuration math (SWIMConfiguration),
// the suspicion timer, the transport protocol + mocks, and SWIMEvent/SWIMError.
// Synchronization's `Mutex` and stdlib `ContinuousClock` are NOT available under
// Embedded Swift 6.3.1, so those stateful pieces cannot be Embedded today.
