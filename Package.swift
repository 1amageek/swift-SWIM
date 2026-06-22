// swift-tools-version: 6.2

import PackageDescription

// Embedded toggle: `SWIMCore` dual-builds (host + Embedded). The Embedded build
// is `P2P_CORE_EMBEDDED=1 swiftly run +6.3.1 swift build --target SWIMCore`.
// `Lifetimes` is enabled in both modes for parity with the shared p2p-core
// recipe (SWIMCore itself has no Span-returning members today).
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
            name: "SWIMCore",
            targets: ["SWIMCore"]
        ),
        .library(
            name: "SWIMTransportUDP",
            targets: ["SWIMTransportUDP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-nio-udp.git", from: "1.1.2"),
    ],
    targets: [
        // Embedded-clean SWIM gossip codec + membership value/safety types.
        //
        // No Foundation, no 'any', typed throws. NOTE: the Mutex/ContinuousClock
        // -backed membership state machine (MemberList/Disseminator/BroadcastQueue)
        // and the orchestration actor (SWIMInstance) stay in the SWIM target —
        // Synchronization's Mutex and stdlib ContinuousClock are NOT available
        // under Embedded Swift 6.3.1.
        .target(
            name: "SWIMCore",
            path: "Sources/SWIMCore",
            swiftSettings: coreSettings
        ),

        // Host-facing SWIM library (orchestration + state machine + Foundation
        // bridges). '@_exported import SWIMCore' so existing `import SWIM`
        // call sites resolve the cored types unchanged.
        .target(
            name: "SWIM",
            dependencies: ["SWIMCore"],
            path: "Sources/SWIM",
            exclude: ["CONTEXT.md"]
        ),

        // UDP Transport using swift-nio-udp
        .target(
            name: "SWIMTransportUDP",
            dependencies: [
                "SWIM",
                .product(name: "NIOUDPTransport", package: "swift-nio-udp"),
            ],
            path: "Sources/SWIMTransportUDP"
        ),

        // Tests
        .testTarget(
            name: "SWIMTests",
            dependencies: ["SWIM"],
            path: "Tests/SWIMTests"
        ),
        .testTarget(
            name: "SWIMTransportUDPTests",
            dependencies: ["SWIMTransportUDP"],
            path: "Tests/SWIMTransportUDPTests"
        ),
    ]
)
