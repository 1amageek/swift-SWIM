// swift-tools-version: 6.2

import PackageDescription

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
            name: "SWIMTransportUDP",
            targets: ["SWIMTransportUDP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-nio-udp.git", from: "1.0.0"),
    ],
    targets: [
        // Core SWIM library (no external dependencies)
        .target(
            name: "SWIM",
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
