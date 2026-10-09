// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "jttylib",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "JTTYLib", targets: ["JTTYLib"]),
    ],
    targets: [
        // The modem: source codec, FEC, GFSK synthesis and the receiver.
        .target(
            name: "CJTTY",
            path: "Sources/CJTTY",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O3"])],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // Swift API: encoding messages, streaming audio through the
        // receiver, and assembling frames into messages.
        .target(
            name: "JTTYLib",
            dependencies: ["CJTTY"],
            path: "Sources/JTTYLib"
        ),
        .testTarget(
            name: "JTTYLibTests",
            dependencies: ["JTTYLib"],
            path: "Tests/JTTYLibTests",
            resources: [.copy("Resources")]
        ),
    ]
)
