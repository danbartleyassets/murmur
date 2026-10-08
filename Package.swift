// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // Pinned by Package.resolved (0.18.0, the version the original app shipped on).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        // Pure logic with no dependencies: the tap-gesture state machine and text
        // helpers. Kept separate so `swift run murmur-check` can verify it.
        .target(
            name: "MurmurCore",
            path: "Sources/MurmurCore"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "murmur-check",
            dependencies: ["MurmurCore"],
            path: "Sources/murmur-check"
        )
    ]
)
