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
        // Thin Objective-C shim over the Swift-unavailable
        // `enumeratorForChangeHistoryFetchRequest:error:` call. Swift can't
        // invoke it directly (NS_SWIFT_UNAVAILABLE), so the change-history
        // delta read in CNContactStoreAdapter bridges through here.
        .target(name: "GuessWhoSyncObjC"),
        .target(name: "GuessWhoSync", dependencies: ["GuessWhoSyncObjC"]),
        .target(name: "GuessWhoSyncTesting", dependencies: ["GuessWhoSync"]),
        .testTarget(
            name: "GuessWhoSyncTests",
            dependencies: ["GuessWhoSync", "GuessWhoSyncTesting"]
        ),
    ]
)
