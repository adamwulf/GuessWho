// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GuessWhoSync",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "GuessWhoSync", targets: ["GuessWhoSync"]),
        .library(name: "GuessWhoSyncTesting", targets: ["GuessWhoSyncTesting"]),
    ],
    targets: [
        .target(name: "GuessWhoSync"),
        .target(name: "GuessWhoSyncTesting", dependencies: ["GuessWhoSync"]),
        .testTarget(
            name: "GuessWhoSyncTests",
            dependencies: ["GuessWhoSync", "GuessWhoSyncTesting"]
        ),
    ]
)
