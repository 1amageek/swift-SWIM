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
/// // Create the SWIM instance
/// let localMember = Member(id: MemberID(id: "node1", address: "192.168.1.1:8000"))
/// let swim = SWIMInstance(
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

// Module exports are automatic - all public types are accessible via `import SWIM`
