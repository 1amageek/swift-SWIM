// swift-tools-version: 6.2

import PackageDescription
import Foundation

private let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let localSwiftNIOUDPPackage = packageDirectory
    .appendingPathComponent("../swift-nio-udp")
    .standardizedFileURL

private func packageDependency(
    localPath: URL,
    remoteURL: String,
    from version: Version
) -> Package.Dependency {
    let manifestPath = localPath.appendingPathComponent("Package.swift").path
    if FileManager.default.fileExists(atPath: manifestPath) {
        return .package(path: localPath.path)
    }
    return .package(url: remoteURL, from: version)
}

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
        packageDependency(
            localPath: localSwiftNIOUDPPackage,
            remoteURL: "https://github.com/1amageek/swift-nio-udp.git",
            from: "1.1.0"
        ),
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
