// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GuessWhoSync",
    platforms: [
        .iOS(.v17),
        // macOS 15: floor inherited from mcp-template (EasyMCP/EasyMacMCP
        // declare .macOS(.v15)). Only pure-macOS consumers feel this — the
        // guesswho-cli helper target (MACOSX_DEPLOYMENT_TARGET = 15.0) and
        // `swift build`/`swift test` on the Mac. The Catalyst app is governed
        // by the iOS/macCatalyst floor, not this one.
        // (String form: the `.v15` constant needs tools-version 6.0; this
        // manifest is 5.9.)
        .macOS("15.0"),
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
        // GuessWhoMCPCore/GuessWhoMCPTransport ride INSIDE this one dynamic
        // product (GuessWhoMCPWire folds in transitively) so the Catalyst app
        // sees exactly ONE copy of GuessWhoSync at runtime. Exporting the MCP
        // dispatch core as its own product would statically fold a second
        // GuessWhoSync into the app (the intra-package target dependency is
        // always folded statically — see the note above) and re-create the
        // cross-image type-metadata failures this product's `.dynamic` exists
        // to prevent. The relay never links this product (INV-1); it uses the
        // standalone GuessWhoMCPWire/GuessWhoMCPTransport products below.
        .library(
            name: "GuessWhoSync",
            type: .dynamic,
            targets: ["GuessWhoSync", "GuessWhoMCPCore", "GuessWhoMCPTransport"]
        ),
        .library(name: "GuessWhoSyncTesting", targets: ["GuessWhoSyncTesting"]),
        // Standalone (static) products for the guesswho-cli relay ONLY. The
        // relay must NOT link GuessWhoSync (plans/cli-mcp.md INV-1): these
        // products reach EasyMacMCP + Foundation and nothing else. The app
        // must never link them (it gets the same modules via the dynamic
        // GuessWhoSync product above — linking these too would duplicate the
        // wire types across images).
        .library(name: "GuessWhoMCPWire", targets: ["GuessWhoMCPWire"]),
        .library(name: "GuessWhoMCPTransport", targets: ["GuessWhoMCPTransport"]),
        // GuessWhoCLICore — the ArgumentParser command tree for the
        // guesswho-cli helper (Phase 1), extracted from the app target so
        // `swift test` exercises the per-command request-building and
        // response-rendering logic. A standalone STATIC product the helper's
        // isolated xcodeproj links, exactly like the two wire/transport
        // products above. MUST NOT link GuessWhoSync (INV-1); the app must
        // never link it (it is the argv adapter only — the app has no argv and
        // no business linking ArgumentParser).
        .library(name: "GuessWhoCLICore", targets: ["GuessWhoCLICore"]),
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
        // mcp-template: the EasyMCP/EasyMacMCP transport the CLI/MCP feature
        // mirrors (plans/cli-mcp.md Phase 1). Pulls modelcontextprotocol/
        // swift-sdk 0.12.1+ and swift-argument-parser. PINNED to the exact
        // commit the plan's file:line anchors were read at (HostRequestPipe,
        // WritePipe, ReadPipe, EasyMCPHost, ResponseManager) — line numbers
        // rot, so the pin is load-bearing documentation, not just build
        // reproducibility. Bump deliberately, re-checking those anchors.
        .package(url: "https://github.com/adamwulf/mcp-template.git", revision: "3cb7bec338efeee0b8d4fce338e9e61b755f1066"),
        // swift-argument-parser: the command tree in GuessWhoCLICore. A
        // DIRECT dependency now that the CLI command logic lives in a package
        // target (Phase 1). It is already in the resolved graph transitively
        // via mcp-template, so `.upToNextMajor(from: "1.5.0")` resolves to the
        // same 1.8.2 with no conflict; the guesswho-cli xcodeproj also pins
        // >= 1.5.0. ArgumentParser is added ONLY to GuessWhoCLICore — NEVER to
        // GuessWhoMCPWire or any target the app links directly.
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMajor(from: "1.5.0")),
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
        // ── CLI/MCP feature targets (plans/cli-mcp.md) ──────────────────────
        // GuessWhoMCPWire — the shared wire module compiled into BOTH the app
        // and the guesswho-cli relay: request/response enums, allowlist-only
        // DTOs, control messages, the typed error enum, and pipe-path
        // derivation. MUST NOT link GuessWhoSync (INV-1/INV-3b: the wire can
        // only carry what these DTOs name). EasyMacMCP supplies the
        // MCPRequestProtocol/MCPResponseProtocol conformances + ToolMetadata.
        .target(
            name: "GuessWhoMCPWire",
            dependencies: [
                .product(name: "EasyMacMCP", package: "mcp-template"),
            ]
        ),
        // GuessWhoMCPCore — the dispatch core: per-tool handlers, the
        // Contact/Event → allowlisted-DTO mappers, and the sealed-handle
        // registry. Links GuessWhoSync, but reaches the app's live
        // ContactsRepository/SyncService only BEHIND the protocols it
        // declares, so the INV-3/allowlist/banned-vocabulary tests run under
        // plain `swift test` with fakes. Ships to the app inside the dynamic
        // GuessWhoSync product; the relay never links it.
        .target(
            name: "GuessWhoMCPCore",
            dependencies: ["GuessWhoSync", "GuessWhoMCPWire"]
        ),
        // GuessWhoMCPTransport — the pipe topology this plan changes vs. the
        // inherited template: per-helper REQUEST pipes + a tiny central
        // announce channel (PIPE_BUF on Darwin is 512 bytes — one writer per
        // data pipe dissolves the interleaving ceiling), the ready-ack
        // handshake, dead-helper liveness reaping, and helper reconnect after
        // a host restart. Used by the app host (Catalyst) and the relay; no
        // GuessWhoSync dependency.
        .target(
            name: "GuessWhoMCPTransport",
            dependencies: [
                "GuessWhoMCPWire",
                .product(name: "EasyMacMCP", package: "mcp-template"),
                .product(name: "EasyMCP", package: "mcp-template"),
            ]
        ),
        .testTarget(
            name: "GuessWhoMCPWireTests",
            dependencies: ["GuessWhoMCPWire"]
        ),
        .testTarget(
            name: "GuessWhoMCPCoreTests",
            // GuessWhoSyncTesting supplies the in-memory contact/event store
            // conformers the link tests use to run a REAL GuessWhoSync over a
            // REAL temp-directory FileSystemSidecarStore (no TCC needed).
            dependencies: ["GuessWhoMCPCore", "GuessWhoMCPWire", "GuessWhoSync", "GuessWhoSyncTesting"]
        ),
        .testTarget(
            name: "GuessWhoMCPTransportTests",
            dependencies: ["GuessWhoMCPTransport", "GuessWhoMCPWire"]
        ),
        // GuessWhoCLICore — the CLI argv adapter (plans/cli-command-parity.md
        // Phase 1): the root command + every subcommand, plus the three seams
        // (CLIRuntime / CLITransport / CLIOutput) and the shared run() funnel
        // that routes each command through WireRequest.create → transport →
        // WireResponse.asCallToolResult, the SAME production path the MCP relay
        // uses. Depends ONLY on the wire + transport products and
        // ArgumentParser — MUST NOT depend on GuessWhoSync (INV-1: the app
        // never links this product, and the wire can only carry what its DTOs
        // name, so the Apple-note exclusion holds for free).
        .target(
            name: "GuessWhoCLICore",
            dependencies: [
                "GuessWhoMCPWire",
                "GuessWhoMCPTransport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GuessWhoCLICoreTests",
            dependencies: ["GuessWhoCLICore"]
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
