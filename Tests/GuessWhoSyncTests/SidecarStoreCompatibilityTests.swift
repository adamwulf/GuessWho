import CryptoKit
import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting

// Compatibility hardening for the on-disk sidecar layout
// (`plans/group-folders.md`, "Hardening the compatibility tests").
//
// Peers on different app versions share one synced sidecar root. A build that
// adds a new kind writes a directory older builds have never heard of, so two
// properties have to hold on EVERY build:
//
//   1. A directory a build has no kind for is never listed, read, written, or
//      removed by it — the old build leaves the new build's data alone.
//   2. Every kind a build DOES know is handled by every per-kind site, so
//      adding a kind cannot silently leave it out of a scan.
//
// The tests cannot run an old binary. They prove (1) on the current build with
// a directory name NO build knows (`future-kind`), which is the same code path
// an old build takes for a directory a newer build introduced — and keeps
// protecting the next new kind after this one ships.

// MARK: - Whole-root digest

/// Every regular file under `root`, keyed by its path relative to `root`.
/// Hidden files included: iCloud placeholders are dotfiles.
private func rootDigest(_ root: URL) throws -> [String: Data] {
    let base = root.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return [:] }
    var digest: [String: Data] = [:]
    for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            continue
        }
        let path = url.resolvingSymlinksInPath().path
        try #require(path.hasPrefix(base + "/"))
        digest[String(path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
    }
    return digest
}

/// The paths whose presence or bytes differ between two digests.
private func changedPaths(_ before: [String: Data], _ after: [String: Data]) -> Set<String> {
    Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
}

private let unknownDirectory = "future-kind"

private func makeRoot(_ label: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/TestTemp", isDirectory: true)
        .appendingPathComponent("guesswho-compat-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func uuidString(_ n: Int) -> String {
    String(format: "550e8400-e29b-41d4-a716-%012d", n)
}

private func envelope(id: String, note: String) -> SidecarEnvelope {
    SidecarEnvelope(entityID: id, fields: [
        "cell": SidecarCell(
            value: .string(note),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedBy: "compat-test")
    ])
}

/// What another app version would leave under the root: envelopes, a blob
/// payload, an iCloud placeholder, and a nested file, all inside a directory
/// this build has no kind for — plus a stray file at the root itself.
private func seedUnknownContent(in root: URL) throws {
    let fm = FileManager.default
    let dir = root.appendingPathComponent(unknownDirectory)
    try fm.createDirectory(at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let id = uuidString(900)
    try SidecarEnvelopeCodec.encode(envelope(id: id, note: "from a newer build"))
        .write(to: dir.appendingPathComponent("\(id).json"))
    try Data([0x00, 0xff, 0x10, 0x20]).write(to: dir.appendingPathComponent("\(id).blob-1.dat"))
    try Data("placeholder".utf8).write(to: dir.appendingPathComponent(".\(uuidString(901)).json.icloud"))
    try Data("placeholder".utf8).write(to: dir.appendingPathComponent(".\(id).blob-2.dat.icloud"))
    try Data("not json at all".utf8).write(to: dir.appendingPathComponent("nested/anything.bin"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("future-root-file.json"))
}

@Suite("Sidecar store compatibility — unknown directories")
struct SidecarUnknownDirectoryTests {
    private func makeStore(root: URL, ubiquity: FakeUbiquityProvider = FakeUbiquityProvider()) -> FileSystemSidecarStore {
        FileSystemSidecarStore(
            root: root,
            ubiquity: ubiquity,
            blobCrypto: InMemoryBlobCrypto(key: SymmetricKey(size: .bits256)),
            coordinatesUbiquitousAccess: false)
    }

    /// One envelope per known kind, so every kind directory exists.
    private func seedKnownContent(through store: FileSystemSidecarStore) throws -> [SidecarKey] {
        var keys: [SidecarKey] = []
        for (index, kind) in SidecarKind.allCases.enumerated() {
            let key = SidecarKey(kind: kind, id: uuidString(index))
            try store.write(envelope(id: key.id, note: "known \(kind.rawValue)"), at: key)
            keys.append(key)
        }
        return keys
    }

    @Test
    func readOnlyOperationsNeverListOrTouchAnUnknownDirectory() throws {
        let root = try makeRoot("reads")
        defer { try? FileManager.default.removeItem(at: root) }
        let ubiquity = FakeUbiquityProvider()
        let store = makeStore(root: root, ubiquity: ubiquity)
        let known = try seedKnownContent(through: store)
        try seedUnknownContent(in: root)
        let before = try rootDigest(root)
        // Guard against a vacuous digest: it must really hold the unknown
        // directory's five files (two of them hidden placeholders), the stray
        // root file, and one envelope per known kind.
        #expect(before.keys.filter { $0.hasPrefix("\(unknownDirectory)/") }.count == 5)
        #expect(before.keys.contains { $0.hasPrefix("\(unknownDirectory)/.") })
        #expect(before["future-root-file.json"] != nil)
        #expect(before.count == 6 + SidecarKind.allCases.count)

        // Enumeration sees exactly the known keys — nothing from the unknown
        // directory, in any form, and nothing for the stray root file.
        #expect(Set(try store.allKeys()) == Set(known))

        var walked: [SidecarKey] = []
        try store.walkCorpus(kinds: Set(SidecarKind.allCases)) { key, result in
            _ = try result.get()
            walked.append(key)
        }
        #expect(Set(walked) == Set(known))

        #expect(try store.keysWithUnresolvedConflicts().isEmpty)
        for key in known {
            #expect(try store.read(key) != nil)
            #expect(store.downloadStatus(key) == .downloaded)
            #expect(try store.blobIds(for: key).isEmpty)
        }

        // Prefetch asks iCloud for placeholders it finds. The unknown directory
        // holds two; neither may be requested.
        store.prefetchAllDownloads()
        let unknownPath = root.appendingPathComponent(unknownDirectory).path
        #expect(ubiquity.startDownloadingCalls.allSatisfy { !$0.path.hasPrefix(unknownPath) })

        #expect(changedPaths(before, try rootDigest(root)).isEmpty)
    }

    /// Each mutation may change exactly the one file it names. Everything else
    /// under the root — above all the unknown directory — stays byte-identical.
    @Test
    func everyMutationChangesOnlyTheFileItNames() throws {
        let root = try makeRoot("writes")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let known = try seedKnownContent(through: store)
        try seedUnknownContent(in: root)

        for (index, kind) in SidecarKind.allCases.enumerated() {
            let existing = known[index]
            let fresh = SidecarKey(kind: kind, id: uuidString(100 + index))
            let dir = kind.directoryName

            var before = try rootDigest(root)
            try store.write(envelope(id: fresh.id, note: "created"), at: fresh)
            var after = try rootDigest(root)
            #expect(changedPaths(before, after) == ["\(dir)/\(fresh.id).json"], "create \(kind)")

            before = after
            try store.write(envelope(id: existing.id, note: "overwritten"), at: existing)
            after = try rootDigest(root)
            #expect(changedPaths(before, after) == ["\(dir)/\(existing.id).json"], "overwrite \(kind)")

            before = after
            try store.writeBlob(Data([1, 2, 3]), blobId: "blob-a", for: existing)
            after = try rootDigest(root)
            #expect(changedPaths(before, after) == ["\(dir)/\(existing.id).blob-a.dat"], "blob write \(kind)")

            before = after
            try store.deleteBlob(blobId: "blob-a", for: existing)
            after = try rootDigest(root)
            #expect(changedPaths(before, after) == ["\(dir)/\(existing.id).blob-a.dat"], "blob delete \(kind)")

            before = after
            try store.delete(fresh)
            after = try rootDigest(root)
            #expect(changedPaths(before, after) == ["\(dir)/\(fresh.id).json"], "delete \(kind)")
        }
    }

    /// The maintenance pass the file watcher runs on every delivery: a full
    /// conflict reconcile, then the post. With a real conflict present it must
    /// rewrite that one file and nothing else.
    @Test @MainActor
    func conflictReconcileRewritesOnlyTheConflictedFile() async throws {
        let root = try makeRoot("reconcile")
        defer { try? FileManager.default.removeItem(at: root) }
        let ubiquity = FakeUbiquityProvider()
        let store = makeStore(root: root, ubiquity: ubiquity)
        let known = try seedKnownContent(through: store)
        try seedUnknownContent(in: root)

        let conflicted = try #require(known.first { $0.kind == .contact })
        let url = root.appendingPathComponent(conflicted.kind.directoryName)
            .appendingPathComponent("\(conflicted.id).json")
        ubiquity.currentBytes[url] = try Data(contentsOf: url)
        ubiquity.conflicts[url] = [FakeVersionHandle(contents: try SidecarEnvelopeCodec.encode(
            SidecarEnvelope(entityID: conflicted.id, fields: [
                "other": SidecarCell(
                    value: .string("from the conflicting version"),
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    modifiedBy: "other-device")
            ])))]
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: "compat-test-device")
        let watcher = SidecarFileWatcher(root: root, sync: sync, notificationCenter: NotificationCenter())
        let before = try rootDigest(root)

        await watcher.processSidecarChanges(added: 0, changed: 1, removed: 0)

        #expect(changedPaths(before, try rootDigest(root))
            == ["\(conflicted.kind.directoryName)/\(conflicted.id).json"])
        #expect(try store.read(conflicted)?.fields["other"] != nil)
    }

    /// An unknown directory's paths map to no key and no kind, so the watcher
    /// reports the batch as globally unknown rather than mis-scoping it.
    @Test @MainActor
    func watcherMapsUnknownDirectoryPathsToNothing() throws {
        let root = try makeRoot("watcher")
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "compat-test-device")
        let watcher = SidecarFileWatcher(root: root, sync: sync)
        let dir = root.appendingPathComponent(unknownDirectory)

        #expect(watcher.sidecarKey(forMetadataPath: dir.appendingPathComponent("\(uuidString(1)).json").path) == nil)
        #expect(watcher.sidecarKey(forMetadataPath: dir.appendingPathComponent(".\(uuidString(1)).json.icloud").path) == nil)
        #expect(watcher.sidecarKind(forMetadataDirectoryPath: dir.path) == nil)
        // Directory names are exact: a known name in another case is unknown.
        #expect(watcher.sidecarKind(forMetadataDirectoryPath: root.appendingPathComponent("Contacts").path) == nil)
    }
}

// MARK: - Kind coverage tripwire

/// Every per-kind site, exercised for EVERY `SidecarKind`. Adding a case and
/// forgetting one of these sites fails here instead of silently dropping the
/// new kind from a scan, a prefetch, or the watcher's change scoping.
@Suite("Sidecar store compatibility — every kind is covered")
struct SidecarKindCoverageTests {
    /// The shipped on-disk directory names. They are the synced layout peers on
    /// other app versions read and write, so an entry here must NEVER change,
    /// and a new kind must add its own line (a missing line fails the test).
    private static let shippedDirectoryNames: [SidecarKind: String] = [
        .contact: "contacts",
        .event: "events",
        .link: "links",
        .guide: "guides",
        .place: "places",
        .group: "groups",
    ]

    @Test
    func directoryNamesAreFrozenUniqueAndReversible() throws {
        for kind in SidecarKind.allCases {
            let shipped = try #require(
                Self.shippedDirectoryNames[kind],
                "add \(kind) to shippedDirectoryNames — its directory name is a synced on-disk contract")
            #expect(kind.directoryName == shipped)
            #expect(SidecarKind(directoryName: kind.directoryName) == kind)
        }
        #expect(Set(SidecarKind.allCases.map(\.directoryName)).count == SidecarKind.allCases.count)
        #expect(SidecarKind(directoryName: unknownDirectory) == nil)
        #expect(SidecarKind(directoryName: "") == nil)
    }

    @Test(arguments: SidecarKind.allCases)
    func fileStoreWritesListsAndWalksEveryKind(_ kind: SidecarKind) throws {
        let root = try makeRoot("kind-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemSidecarStore(root: root, coordinatesUbiquitousAccess: false)
        let key = SidecarKey(kind: kind, id: uuidString(7))

        try store.write(envelope(id: key.id, note: "x"), at: key)

        // It lands in the kind's own directory …
        let file = root.appendingPathComponent(kind.directoryName).appendingPathComponent("\(key.id).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        // … the full enumeration returns it …
        #expect(try store.allKeys() == [key])
        // … and so does a walk scoped to just this kind.
        var walked: [SidecarKey] = []
        try store.walkCorpus(kinds: [kind]) { walkedKey, result in
            let walkedEnvelope = try result.get()
            #expect(walkedEnvelope?.entityID == key.id)
            walked.append(walkedKey)
        }
        #expect(walked == [key])
        #expect(try store.read(key)?.entityID == key.id)
    }

    @Test(arguments: SidecarKind.allCases)
    func prefetchVisitsEveryKind(_ kind: SidecarKind) throws {
        let root = try makeRoot("prefetch-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ubiquity = FakeUbiquityProvider()
        let store = FileSystemSidecarStore(root: root, ubiquity: ubiquity, coordinatesUbiquitousAccess: false)
        let dir = root.appendingPathComponent(kind.directoryName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = uuidString(8)
        try Data("placeholder".utf8).write(to: dir.appendingPathComponent(".\(id).json.icloud"))

        store.prefetchAllDownloads()

        #expect(ubiquity.startDownloadingCalls.map(\.lastPathComponent) == ["\(id).json"])
    }

    @Test(arguments: SidecarKind.allCases)
    @MainActor
    func watcherMapsEveryKindBackToItsKey(_ kind: SidecarKind) throws {
        let root = try makeRoot("watch-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "compat-test-device")
        let watcher = SidecarFileWatcher(root: root, sync: sync)
        let key = SidecarKey(kind: kind, id: uuidString(9))
        let dir = root.appendingPathComponent(kind.directoryName)

        #expect(watcher.sidecarKey(forMetadataPath: dir.appendingPathComponent("\(key.id).json").path) == key)
        #expect(watcher.sidecarKey(forMetadataPath: dir.appendingPathComponent(".\(key.id).json.icloud").path) == key)
        #expect(watcher.sidecarKey(forMetadataPath: dir.appendingPathComponent("\(key.id).blob-1.dat").path) == key)
        #expect(watcher.sidecarKind(forMetadataDirectoryPath: dir.path) == kind)
    }

    @Test(arguments: SidecarKind.allCases)
    func inMemoryStoreRoundTripsEveryKind(_ kind: SidecarKind) throws {
        let store = InMemorySidecarStore()
        let key = SidecarKey(kind: kind, id: uuidString(10))

        try store.write(envelope(id: key.id, note: "x"), at: key)

        #expect(try store.allKeys() == [key])
        #expect(try store.read(key)?.entityID == key.id)
    }
}

// MARK: - An unknown-scope delivery refreshes once

/// What a build does with a delivery it cannot scope — the shape an old build
/// sees for every write a newer build makes under a directory it does not know.
/// It must cost ONE read-only refresh: no sidecar write, so nothing echoes back
/// through the watcher and loops.
@Suite("Sidecar store compatibility — unknown scope refreshes once", .serialized)
@MainActor
struct SidecarUnknownScopeRefreshTests {
    @Test
    func unknownScopeDelivery_reloadsOnceAndWritesNothing() async throws {
        let contacts = InMemoryContactStore(contacts: [
            Contact(
                localID: "amy",
                givenName: "Amy",
                urlAddresses: [LabeledValue(
                    label: "g",
                    value: "\(SidecarKey.guessWhoContactURLPrefix)\(uuidString(20))")])
        ])
        let sidecars = WriteCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "compat-test-device")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: center)

        // A settled device: contacts and groups loaded, and one group identity
        // that already resolves through this device's pin.
        let group = try await contacts.createGroup(name: "Work")
        await repository.reload()
        await repository.loadGroups()
        let identity = try sync.mintGroupIdentity(
            name: group.name,
            memberCount: 0,
            memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
            hashedMemberCount: 0,
            localID: group.localID)
        await repository.loadGroups()
        let writesBefore = sidecars.totalWriteCount

        nonisolated(unsafe) var reloads = 0
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repository, queue: nil
        ) { _ in reloads += 1 }
        defer { center.removeObserver(token) }

        for delivery in 1...2 {
            center.post(
                name: .guessWhoSidecarsDidChange,
                object: nil,
                userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet.fullRefresh])
            // Well past the repository's 300 ms debounce, so a second refresh
            // provoked by the first would have landed by now.
            try await Task.sleep(for: .milliseconds(900))
            #expect(reloads == delivery)
        }

        #expect(sidecars.totalWriteCount == writesBefore)
        #expect(repository.group(forFavoriteID: identity.id) == group)
    }
}
