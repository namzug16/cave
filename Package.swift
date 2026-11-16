// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cave",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cave", targets: ["cave"]),
    ],
    targets: [
        .target(name: "CaveCore"),
        .executableTarget(name: "cave", dependencies: ["CaveCore"]),
        .testTarget(name: "CaveCoreTests", dependencies: ["CaveCore"]),
    ]
)
