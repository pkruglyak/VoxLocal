// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoxLocal",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "VoxLocalCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/VoxLocalCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "VoxLocal",
            dependencies: ["VoxLocalCore"],
            path: "Sources/VoxLocal"
        ),
        .testTarget(
            name: "VoxLocalTests",
            dependencies: ["VoxLocalCore"],
            path: "Tests/VoxLocalTests"
        ),
    ]
)
