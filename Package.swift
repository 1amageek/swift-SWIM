// swift-tools-version: 6.2

import PackageDescription

// Embedded toggle: `SWIMWire` dual-builds (host + Embedded). The Embedded build
// is `P2P_CORE_EMBEDDED=1 swiftly run +6.3.1 swift build --target SWIMWire`.
// `Lifetimes` is enabled in both modes for parity with the shared p2p-core
// recipe (SWIMWire itself has no Span-returning members today).
let embeddedEnabled = Context.environment["P2P_CORE_EMBEDDED"] == "1"

let coreSettings: [SwiftSetting] = {
    var s: [SwiftSetting] = [.enableExperimentalFeature("Lifetimes")]
    if embeddedEnabled {
        s += [.enableExperimentalFeature("Embedded"), .unsafeFlags(["-wmo"])]
    }
    return s
}()

let package = Package(
    name: "swift-SWIM",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "SWIM",
            targets: ["SWIM"]
        ),
        .library(
            name: "SWIMWire",
            targets: ["SWIMWire"]
        ),
        .library(
            name: "SWIMTransportUDP",
            targets: ["SWIMTransportUDP"]
        ),
    ],
    dependencies: [
        // embedded-branch only; restore URL before release.
        // Local path so the whole embedded composition (swift-libp2p pulls quic +
        // SWIM + mDNS + nio-udp together) resolves nio-udp against ONE working tree.
        // A URL pin here collides with swift-libp2p's local-path nio-udp and trips
        // SwiftPM's "Conflicting identity for swift-nio-udp" diagnostic (escalating
        // to an error in future SwiftPM). Original: .package(url: "https://github.com/1amageek/swift-nio-udp.git", from: "1.1.2")
        .package(path: "../swift-nio-udp"),
    ],
    targets: [
        // Tier-3 codec core (renamed from SWIMCore). Embedded-clean SWIM gossip
        // codec + membership value/safety types.
        //
        // No Foundation, no 'any', typed throws. NOTE: the Mutex/ContinuousClock
        // -backed membership state machine (MemberList/Disseminator/BroadcastQueue)
        // and the orchestration actor (SWIMCluster) stay in the SWIM target —
        // Synchronization's Mutex and stdlib ContinuousClock are NOT available
        // under Embedded Swift 6.3.1. `import SWIM` does NOT pull this in; a
        // protocol implementer imports SWIMWire deliberately.
        .target(
            name: "SWIMWire",
            path: "Sources/SWIMWire",
            swiftSettings: coreSettings
        ),

        // Tier-1 facade (orchestration + state machine + Foundation bridges).
        // Re-exports only the curated facade value types from SWIMWire
        // (Member/MemberID/MemberStatus/Incarnation) via symbol-level
        // @_exported import; it does NOT re-export the codec (SWIMMessageCodec,
        // WriteBuffer, SWIMMessage, GossipPayload, ...) — those need an explicit
        // `import SWIMWire`.
        .target(
            name: "SWIM",
            dependencies: ["SWIMWire"],
            path: "Sources/SWIM",
            exclude: ["CONTEXT.md"]
        ),

        // UDP Transport using swift-nio-udp. Depends on SWIMWire directly for the
        // codec (SWIMMessageCodec) — `import SWIM` no longer re-exports it.
        .target(
            name: "SWIMTransportUDP",
            dependencies: [
                "SWIM",
                "SWIMWire",
                .product(name: "NIOUDPTransport", package: "swift-nio-udp"),
            ],
            path: "Sources/SWIMTransportUDP"
        ),

        // Tests
        .testTarget(
            name: "SWIMTests",
            dependencies: ["SWIM", "SWIMWire"],
            path: "Tests/SWIMTests"
        ),
        .testTarget(
            name: "SWIMTransportUDPTests",
            dependencies: ["SWIMTransportUDP"],
            path: "Tests/SWIMTransportUDPTests"
        ),
    ]
)
