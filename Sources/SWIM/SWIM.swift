/// swift-SWIM
///
/// A pure Swift implementation of the SWIM protocol for cluster membership
/// and failure detection.
///
/// ## Overview
///
/// SWIM (Scalable Weakly-consistent Infection-style Process Group Membership)
/// is a protocol for maintaining membership information in large-scale
/// distributed systems. It provides:
///
/// - **Failure Detection**: Efficiently detects failed nodes using ping/ping-req
/// - **Dissemination**: Spreads membership updates via gossip
/// - **Consistency**: Uses incarnation numbers to handle consistency
///
/// ## Quick Start
///
/// ```swift
/// import SWIM
///
/// // Create a transport (implement SWIMTransport for your networking layer)
/// let transport = MyTransport(localAddress: "192.168.1.1:8000")
///
/// // Create the SWIM cluster
/// let localMember = Member(id: MemberID(id: "node1", address: "192.168.1.1:8000"))
/// let swim = SWIMCluster(
///     localMember: localMember,
///     config: .default,
///     transport: transport
/// )
///
/// // Start and join the cluster
/// await swim.start()
/// try await swim.join(seeds: [seedMemberID])
///
/// // React to membership changes
/// for await event in swim.events {
///     switch event {
///     case .memberJoined(let member):
///         print("Member joined: \(member)")
///     case .memberFailed(let member):
///         print("Member failed: \(member)")
///     // ... handle other events
///     }
/// }
/// ```
///
/// ## References
///
/// - [SWIM Paper](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
/// - [Lifeguard (SWIM extensions)](https://arxiv.org/abs/1707.00788)

// Curated facade re-export (§3): `import SWIM` re-exports ONLY the value/identity
// types that appear on the facade's public surface (the `SWIMTransport` protocol,
// `SWIMEvent`, `SWIMCluster`), via symbol-level @_exported import. It does NOT
// re-export the Tier-3 SWIMWire codec machinery (`SWIMMessageCodec`,
// `WriteBuffer`, `ReadBuffer`, `SWIMCodecError`, `MembershipState`,
// `DisseminationState`, `BroadcastQueue`) — a protocol implementer asks for those
// deliberately with `import SWIMWire`. No whole-module re-export, no Foundation.
@_exported import struct SWIMWire.Member
@_exported import struct SWIMWire.MemberID
@_exported import enum SWIMWire.MemberStatus
@_exported import struct SWIMWire.Incarnation
@_exported import enum SWIMWire.MembershipChange
@_exported import struct SWIMWire.MembershipUpdate
@_exported import struct SWIMWire.GossipPayload
@_exported import enum SWIMWire.SWIMMessage
@_exported import enum SWIMWire.MemberListRejection
@_exported import enum SWIMWire.ProbeResult
