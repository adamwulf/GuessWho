// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GuessWhoSync",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // `.dynamic` so the app and its hosted test bundle (GuessWhoTests)
        // share ONE GuessWhoSync image at runtime. With the default automatic
        // (static) type the test bundle linked its own copy, and the two
        // images' separate type metadata made cross-image dynamic casts fail —
        // e.g. `#expect(throws: SidecarUnavailableError.self)` on an error
        // thrown by host-app code.
        //
        // GuessWhoSyncTesting stays `automatic` — and, load-bearing, the app
        // test bundle must NOT link it: its dependency on the GuessWhoSync
        // TARGET is intra-package (always folded in statically), which both
        // re-embeds a second GuessWhoSync copy AND trips Xcode's "linked as a
        // static library … cannot be built dynamically because there is a
        // package product with the same name" error. App-hosted tests carry
        // their own minimal protocol stubs instead (see GuessWhoTests);
        // package tests keep using these fakes via the target dependency.
        .library(name: "GuessWhoSync", type: .dynamic, targets: ["GuessWhoSync"]),
        .library(name: "GuessWhoSyncTesting", targets: ["GuessWhoSyncTesting"]),
        // logfmt file logging shared by the GuessWho app + its Safari Web
        // Extension. A thin facade (GuessWhoLog) over FellerBuncher's swift-log
        // bootstrap — the extension links it and appex memory budgets are tight,
        // so FellerBuncher's lean footprint matters here.
        .library(name: "GuessWhoLogging", targets: ["GuessWhoLogging"]),
    ],
    dependencies: [
        // swift-log: the `Logger` API every call site uses; FellerBuncher
        // installs the backend it routes to. GuessWhoSync depends on this
        // directly (not GuessWhoLogging) so a plain `Logger` there still reaches
        // the file. Pinned to the 1.14.x line.
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.14.0")),
        // FellerBuncher: owns the swift-log bootstrap + destination fan-out
        // (rotating, self-pruning logfmt file + console echo + in-memory ring
        // buffer). It consumes the stock `Logger(label:)`, so `GuessWhoLog` is a
        // thin facade over its bootstrap and every `Logger` in the app/packages
        // routes to the same file. Replaces the in-house LogFileWriter /
        // LogfmtLogHandler this package used to ship.
        .package(url: "https://github.com/adamwulf/FellerBuncher.git", branch: "main"),
        // PhoneNumberKit: libphonenumber-backed parsing/formatting. Used to
        // render stored phone strings the way the OS does (dashes, parens,
        // international grouping) rather than showing the raw typed value.
        // Pinned to the 5.x line (the maintained PhoneNumberKit-org fork).
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", .upToNextMajor(from: "5.0.4")),
    ],
    targets: [
        // Thin Objective-C shim over the Swift-unavailable
        // `enumeratorForChangeHistoryFetchRequest:error:` call. Swift can't
        // invoke it directly (NS_SWIFT_UNAVAILABLE), so the change-history
        // delta read in CNContactStoreAdapter bridges through here.
        .target(name: "GuessWhoSyncObjC"),
        // GuessWhoSync depends on swift-log directly (NOT GuessWhoLogging — that
        // would drag the file writer / App Group / exporter machinery into the
        // package). A plain `Logger` here routes to the file via whatever backend
        // the app bootstraps; with no bootstrap (e.g. `swift test`) it falls back
        // to swift-log's default stderr handler.
        .target(
            name: "GuessWhoSync",
            dependencies: [
                "GuessWhoSyncObjC",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ]
        ),
        .target(name: "GuessWhoSyncTesting", dependencies: ["GuessWhoSync"]),
        .testTarget(
            name: "GuessWhoSyncTests",
            dependencies: ["GuessWhoSync", "GuessWhoSyncTesting"]
        ),
        // GuessWhoLogging — swift-log's product is "Logging"; FellerBuncher's
        // product and module are both "FellerBuncher". FellerBuncher owns the
        // file writer + logfmt formatting now, so this target no longer needs a
        // direct Logfmt dependency.
        .target(
            name: "GuessWhoLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "FellerBuncher", package: "FellerBuncher"),
            ]
        ),
        .testTarget(
            name: "GuessWhoLoggingTests",
            dependencies: ["GuessWhoLogging"]
        ),
    ]
)
