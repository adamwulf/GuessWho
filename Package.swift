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
        // logfmt file logging shared by the GuessWho app + its Safari Web
        // Extension. Kept lean (swift-log + Logfmt only) — the extension links
        // it and appex memory budgets are tight.
        .library(name: "GuessWhoLogging", targets: ["GuessWhoLogging"]),
    ],
    dependencies: [
        // swift-log: the `Logger` / `LogHandler` API our custom logfmt handler
        // plugs into. Pinned to the 1.14.x line.
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.14.0")),
        // Logfmt: provides `String.logfmt(_:)` for clean logfmt output. Pinned to
        // a specific commit (its swift-log LogHandler integration is still in
        // progress, so we write our own handler that formats via this).
        .package(url: "https://github.com/adamwulf/Logfmt.git", revision: "a6d6eb29177f65f3e252610a2176d318026d634c"),
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
        // GuessWhoLogging — Logfmt's product name is "Logfmt" and its package
        // name is "Logfmt"; swift-log's product is "Logging".
        .target(
            name: "GuessWhoLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Logfmt", package: "Logfmt"),
            ]
        ),
        .testTarget(
            name: "GuessWhoLoggingTests",
            dependencies: ["GuessWhoLogging"]
        ),
    ]
)
