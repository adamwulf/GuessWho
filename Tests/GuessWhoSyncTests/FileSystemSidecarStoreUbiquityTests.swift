import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync

// In-memory fake of the iCloud-facing OS APIs. Lets us drive the
// conflict-reconcile path and downloadStatus branches that depend on
// NSFileVersion + ubiquity download state — neither of which can be
// reproduced against a local-only test filesystem.
final class FakeVersionHandle: SidecarVersionHandle, @unchecked Sendable {
    var contents: Data?
    var readError: Error?
    var isResolved: Bool = false
    var removed: Bool = false
    var removeError: Error?

    init(contents: Data?, readError: Error? = nil, removeError: Error? = nil) {
        self.contents = contents
        self.readError = readError
        self.removeError = removeError
    }

    func bytes() throws -> Data {
        if let readError { throw readError }
        guard let contents else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return contents
    }

    func remove() throws {
        if let removeError { throw removeError }
        removed = true
    }
}

final class FakeUbiquityProvider: SidecarUbiquityProvider, @unchecked Sendable {
    // Conflict versions keyed by sidecar file URL.
    var conflicts: [URL: [FakeVersionHandle]] = [:]

    // Current bytes keyed by sidecar file URL. nil means "no current
    // version exists" (the resolver receives nil); not setting an entry
    // also means nil.
    var currentBytes: [URL: Data] = [:]
    // Set this AND currentBytes[url] together to simulate "current version
    // exists on disk but reading its bytes fails" — the only throw shape the
    // production adapter can produce. Setting currentReadError alone (without
    // currentBytes) models a state NSFileVersion + Data(contentsOf:) cannot
    // reach; don't write tests against that.
    var currentReadError: [URL: Error] = [:]

    // Downloading status keyed by URL. nil → not-a-ubiquity-URL (provider
    // returns nil, store treats as downloaded).
    var downloadingStatus: [URL: URLUbiquitousItemDownloadingStatus] = [:]

    // Whether startDownloading should throw, and a record of URLs it was
    // called with.
    var startDownloadingError: Error?
    var startDownloadingCalls: [URL] = []

    func unresolvedConflictVersions(at url: URL) -> [SidecarVersionHandle]? {
        guard let list = conflicts[url], !list.isEmpty else { return nil }
        return list.map { $0 as SidecarVersionHandle }
    }

    func currentVersionBytes(at url: URL) throws -> Data? {
        if let error = currentReadError[url] { throw error }
        return currentBytes[url]
    }

    func downloadingStatus(for url: URL) -> URLUbiquitousItemDownloadingStatus? {
        downloadingStatus[url]
    }

    func startDownloading(at url: URL) throws {
        startDownloadingCalls.append(url)
        if let error = startDownloadingError { throw error }
    }
}

@Suite("FileSystemSidecarStore + UbiquityProvider seam")
struct FileSystemSidecarStoreUbiquityTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-ubiq-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func envelope(
        id: String,
        fields: [String: SidecarCell] = [:]
    ) -> SidecarEnvelope {
        SidecarEnvelope(entityID: id, fields: fields)
    }

    private func encode(_ env: SidecarEnvelope) -> Data {
        try! JSONEncoder().encode(env)
    }

    private func fileURL(in root: URL, kindDir: String, basename: String) -> URL {
        root.appendingPathComponent(kindDir).appendingPathComponent("\(basename).json")
    }

    // MARK: - reconcileConflict

    @Test
    func reconcileConflictHappyPathWritesMergedAndMarksVersionResolved() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "abc")
        let url = fileURL(in: root, kindDir: "contacts", basename: "abc")

        let currentEnv = envelope(id: "abc", fields: [
            "nickname": SidecarCell(value: .string("Original"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let conflictEnv = envelope(id: "abc", fields: [
            "nickname": SidecarCell(value: .string("FromOther"), modifiedAt: when, modifiedBy: "device-B")
        ])
        let mergedEnv = envelope(id: "abc", fields: [
            "nickname": SidecarCell(value: .string("Merged"), modifiedAt: when, modifiedBy: "device-C")
        ])

        let fake = FakeUbiquityProvider()
        fake.currentBytes[url] = encode(currentEnv)
        let conflictHandle = FakeVersionHandle(contents: encode(conflictEnv))
        fake.conflicts[url] = [conflictHandle]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(currentEnv, at: key)

        var resolverInvocations = 0
        var seenCurrent: Data?
        var seenConflictCount = 0
        let outcome = try store.reconcileConflict(at: key) { current, conflicts in
            resolverInvocations += 1
            seenCurrent = current
            seenConflictCount = conflicts.count
            return mergedEnv
        }

        let report = try #require(outcome)
        #expect(report.key == key)
        #expect(report.versionsConsidered == 2)
        #expect(report.skippedReasons.isEmpty)
        #expect(resolverInvocations == 1)
        // The provider owns these current bytes, so decode rather than
        // assuming the fake used the store's canonical encoder.
        let seenCurrentEnv = try #require(seenCurrent.flatMap {
            try? JSONDecoder().decode(SidecarEnvelope.self, from: $0)
        })
        #expect(seenCurrentEnv.fields["nickname"]?.value == .string("Original"))
        #expect(seenConflictCount == 1)
        #expect(conflictHandle.removed)
        #expect(conflictHandle.isResolved)

        let fetched = try #require(try store.read(key))
        #expect(fetched.entityID == "abc")
        #expect(fetched.fields["nickname"]?.modifiedBy == "device-C")
    }

    @Test
    func reconcileConflictWithMultipleVersionsResolvesAll() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "multi")
        let url = fileURL(in: root, kindDir: "contacts", basename: "multi")

        let currentEnv = envelope(id: "multi")
        let v1 = envelope(id: "multi", fields: [
            "nickname": SidecarCell(value: .string("V1"), modifiedAt: when, modifiedBy: "device-1")
        ])
        let v2 = envelope(id: "multi", fields: [
            "nickname": SidecarCell(value: .string("V2"), modifiedAt: when, modifiedBy: "device-2")
        ])
        let merged = envelope(id: "multi", fields: [
            "nickname": SidecarCell(value: .string("Merged"), modifiedAt: when, modifiedBy: "merger")
        ])

        let fake = FakeUbiquityProvider()
        fake.currentBytes[url] = encode(currentEnv)
        let h1 = FakeVersionHandle(contents: encode(v1))
        let h2 = FakeVersionHandle(contents: encode(v2))
        fake.conflicts[url] = [h1, h2]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(currentEnv, at: key)

        var seenConflictBytes: [Data] = []
        let outcome = try store.reconcileConflict(at: key) { _, conflicts in
            seenConflictBytes = conflicts
            return merged
        }

        let report = try #require(outcome)
        #expect(report.versionsConsidered == 3)
        #expect(report.skippedReasons.isEmpty)
        #expect(seenConflictBytes.count == 2)
        #expect(h1.removed && h1.isResolved)
        #expect(h2.removed && h2.isResolved)

        let fetched = try #require(try store.read(key))
        #expect(fetched.fields["nickname"]?.modifiedBy == "merger")
    }

    @Test
    func reconcileConflictResolverThrowsPreservesCurrentBytesAndConflict() throws {
        struct ResolveBoom: Error, CustomStringConvertible {
            var description: String { "kaboom" }
        }
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "boom")
        let url = fileURL(in: root, kindDir: "contacts", basename: "boom")

        let currentEnv = envelope(id: "boom", fields: [
            "nickname": SidecarCell(value: .string("StaysPut"), modifiedAt: when, modifiedBy: "device-A")
        ])

        let fake = FakeUbiquityProvider()
        fake.currentBytes[url] = encode(currentEnv)
        let conflictHandle = FakeVersionHandle(contents: encode(envelope(id: "boom")))
        fake.conflicts[url] = [conflictHandle]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(currentEnv, at: key)

        let outcome = try store.reconcileConflict(at: key) { _, _ in
            throw ResolveBoom()
        }

        let report = try #require(outcome)
        #expect(report.versionsConsidered == 0)
        #expect(report.skippedReasons.contains { $0.contains("kaboom") })
        // No data loss — conflict surface preserved, current bytes intact.
        #expect(!conflictHandle.removed)
        #expect(!conflictHandle.isResolved)
        let fetched = try #require(try store.read(key))
        #expect(fetched.fields["nickname"]?.value == .string("StaysPut"))
    }

    @Test
    func reconcileConflictConflictReadFailureAbortsPass() throws {
        struct ReadFail: Error, CustomStringConvertible {
            var description: String { "icloud-not-downloaded" }
        }
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "readfail")
        let url = fileURL(in: root, kindDir: "contacts", basename: "readfail")

        let currentEnv = envelope(id: "readfail")
        let fake = FakeUbiquityProvider()
        fake.currentBytes[url] = encode(currentEnv)
        let failingHandle = FakeVersionHandle(contents: nil, readError: ReadFail())
        fake.conflicts[url] = [failingHandle]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(currentEnv, at: key)

        var resolverCalled = false
        let outcome = try store.reconcileConflict(at: key) { _, _ in
            resolverCalled = true
            return envelope(id: "readfail")
        }

        let report = try #require(outcome)
        #expect(report.versionsConsidered == 0)
        #expect(report.skippedReasons.contains { $0.contains("conflict: read failed") })
        #expect(report.skippedReasons.contains { $0.contains("icloud-not-downloaded") })
        #expect(!resolverCalled)
        #expect(!failingHandle.removed)
        #expect(!failingHandle.isResolved)
    }

    @Test
    func reconcileConflictCurrentReadFailureAbortsPass() throws {
        struct CurrentReadFail: Error, CustomStringConvertible {
            var description: String { "current-sandbox-glitch" }
        }
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "currfail")
        let url = fileURL(in: root, kindDir: "contacts", basename: "currfail")

        let fake = FakeUbiquityProvider()
        // Both set together: production reaches the throwing path only
        // when a current version exists on disk but reading it fails.
        fake.currentBytes[url] = encode(envelope(id: "currfail"))
        fake.currentReadError[url] = CurrentReadFail()
        let conflictHandle = FakeVersionHandle(contents: Data())
        fake.conflicts[url] = [conflictHandle]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "currfail"), at: key)

        var resolverCalled = false
        let outcome = try store.reconcileConflict(at: key) { _, _ in
            resolverCalled = true
            return envelope(id: "currfail")
        }

        let report = try #require(outcome)
        #expect(report.versionsConsidered == 0)
        #expect(report.skippedReasons.contains { $0.contains("current: read failed") })
        #expect(report.skippedReasons.contains { $0.contains("current-sandbox-glitch") })
        #expect(!resolverCalled)
        #expect(!conflictHandle.removed)
        #expect(!conflictHandle.isResolved)
    }

    @Test
    func reconcileConflictWithNilCurrentPassesNilToResolver() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "nocurrent")
        let url = fileURL(in: root, kindDir: "contacts", basename: "nocurrent")

        let conflictEnv = envelope(id: "nocurrent", fields: [
            "nickname": SidecarCell(value: .string("OnlyConflict"), modifiedAt: when, modifiedBy: "device-B")
        ])
        let merged = envelope(id: "nocurrent", fields: [
            "nickname": SidecarCell(value: .string("Merged"), modifiedAt: when, modifiedBy: "device-C")
        ])

        let fake = FakeUbiquityProvider()
        // No currentBytes entry → currentVersionBytes returns nil.
        let handle = FakeVersionHandle(contents: encode(conflictEnv))
        fake.conflicts[url] = [handle]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "nocurrent"), at: key)

        var seenCurrent: Data? = Data([0xFF])
        let outcome = try store.reconcileConflict(at: key) { current, _ in
            seenCurrent = current
            return merged
        }

        let report = try #require(outcome)
        #expect(report.versionsConsidered == 1)
        #expect(seenCurrent == nil)
        #expect(report.skippedReasons.isEmpty)
        #expect(handle.removed && handle.isResolved)
    }

    @Test
    func reconcileConflictWithMismatchedEntityIDAbortsPass() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "right-id")
        let url = fileURL(in: root, kindDir: "contacts", basename: "right-id")

        let fake = FakeUbiquityProvider()
        fake.currentBytes[url] = encode(envelope(id: "right-id"))
        let handle = FakeVersionHandle(contents: encode(envelope(id: "right-id")))
        fake.conflicts[url] = [handle]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "right-id"), at: key)

        let outcome = try store.reconcileConflict(at: key) { _, _ in
            // Buggy resolver returns wrong entityID — store must refuse to write.
            return self.envelope(id: "wrong-id")
        }

        let report = try #require(outcome)
        #expect(report.versionsConsidered == 0)
        #expect(report.skippedReasons.contains { $0.contains("mismatched entityID") })
        #expect(!handle.removed)
        #expect(!handle.isResolved)
        // Current bytes on disk untouched.
        let fetched = try #require(try store.read(key))
        #expect(fetched.entityID == "right-id")
    }

    @Test
    func reconcileConflictWithNoUnresolvedConflictsReturnsNil() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "clean")
        let fake = FakeUbiquityProvider()
        // No conflicts entry for this URL.

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "clean"), at: key)

        var resolverCalled = false
        let outcome = try store.reconcileConflict(at: key) { _, _ in
            resolverCalled = true
            return self.envelope(id: "clean")
        }
        #expect(outcome == nil)
        #expect(!resolverCalled)
    }

    @Test
    func keysWithUnresolvedConflictsReportsOnlyKeysWithConflicts() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let withConflict = SidecarKey(kind: .contact, id: "with")
        let withoutConflict = SidecarKey(kind: .contact, id: "without")

        let fake = FakeUbiquityProvider()
        fake.conflicts[fileURL(in: root, kindDir: "contacts", basename: "with")] = [
            FakeVersionHandle(contents: Data())
        ]

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "with"), at: withConflict)
        try store.write(envelope(id: "without"), at: withoutConflict)

        let keys = try store.keysWithUnresolvedConflicts()
        #expect(keys == [withConflict])
    }

    // MARK: - downloadStatus

    @Test
    func downloadStatusMaterializedCurrentReturnsDownloaded() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "current")
        let url = fileURL(in: root, kindDir: "contacts", basename: "current")
        let fake = FakeUbiquityProvider()
        fake.downloadingStatus[url] = .current

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "current"), at: key)

        #expect(store.downloadStatus(key) == .downloaded)
    }

    @Test
    func downloadStatusMaterializedDownloadedReturnsDownloaded() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "dl")
        let url = fileURL(in: root, kindDir: "contacts", basename: "dl")
        let fake = FakeUbiquityProvider()
        fake.downloadingStatus[url] = .downloaded

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "dl"), at: key)

        #expect(store.downloadStatus(key) == .downloaded)
    }

    @Test
    func downloadStatusMaterializedNotDownloadedReturnsNotStarted() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "ndl")
        let url = fileURL(in: root, kindDir: "contacts", basename: "ndl")
        let fake = FakeUbiquityProvider()
        fake.downloadingStatus[url] = .notDownloaded

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "ndl"), at: key)

        #expect(store.downloadStatus(key) == .notStarted)
    }

    @Test
    func downloadStatusMaterializedNoUbiquityStatusReturnsDownloaded() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SidecarKey(kind: .contact, id: "local")
        let fake = FakeUbiquityProvider()
        // No downloadingStatus entry → provider returns nil → store falls
        // back to treating the materialized file as downloaded.

        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        try store.write(envelope(id: "local"), at: key)

        #expect(store.downloadStatus(key) == .downloaded)
    }

    @Test
    func downloadStatusPlaceholderWithDownloadingStatusReturnsDownloading() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        // A placeholder file (.icloud sibling) with downloading-status != .notDownloaded
        // means iCloud is actively pulling the real file in — the store reports
        // .downloading. Any non-.notDownloaded status reaches that branch; .downloaded
        // here is a concrete representative.
        let store = FileSystemSidecarStore(root: root, ubiquity: makeProviderForPlaceholderTest(root: root, basename: "downloading", placeholderStatus: .downloaded))
        let key = SidecarKey(kind: .contact, id: "downloading")

        try plantPlaceholder(in: root, kindDir: "contacts", basename: "downloading")
        #expect(store.downloadStatus(key) == .downloading)
    }

    @Test
    func downloadStatusPlaceholderWithoutDownloadingStatusReturnsNotStarted() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let fake = FakeUbiquityProvider()
        // No downloadingStatus entry for the placeholder URL.
        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        let key = SidecarKey(kind: .contact, id: "notstarted")

        try plantPlaceholder(in: root, kindDir: "contacts", basename: "notstarted")
        #expect(store.downloadStatus(key) == .notStarted)
    }

    @Test
    func downloadStatusMissingFileReturnsNotFound() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let fake = FakeUbiquityProvider()
        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        let key = SidecarKey(kind: .contact, id: "ghost")
        #expect(store.downloadStatus(key) == .notFound)
    }

    // MARK: - requestDownload

    @Test
    func requestDownloadDelegatesToProvider() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let fake = FakeUbiquityProvider()
        let store = FileSystemSidecarStore(root: root, ubiquity: fake)
        let key = SidecarKey(kind: .contact, id: "needs-dl")

        try store.requestDownload(key)
        try #require(fake.startDownloadingCalls.count == 1)
        #expect(fake.startDownloadingCalls.first == fileURL(in: root, kindDir: "contacts", basename: "needs-dl"))
    }

    @Test
    func requestDownloadSurfacesProviderError() throws {
        struct NotUbiquity: Error {}
        let root = makeRoot()
        defer { cleanup(root) }
        let fake = FakeUbiquityProvider()
        fake.startDownloadingError = NotUbiquity()
        let store = FileSystemSidecarStore(root: root, ubiquity: fake)

        #expect(throws: NotUbiquity.self) {
            try store.requestDownload(SidecarKey(kind: .contact, id: "needs-dl"))
        }
    }

    @Test
    func readOfPlaceholderRequestsDownloadAndThrows() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let fake = FakeUbiquityProvider()
        let store = FileSystemSidecarStore(root: root, ubiquity: fake)

        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        try plantPlaceholder(in: root, kindDir: "contacts", basename: uuid)

        let key = SidecarKey(kind: .contact, id: uuid)
        #expect(throws: SidecarStoreError.notYetDownloaded(key)) {
            _ = try store.read(key)
        }
        // The store also nudged the provider to start downloading
        // (best-effort — errors swallowed by the read path).
        #expect(fake.startDownloadingCalls.contains(fileURL(in: root, kindDir: "contacts", basename: uuid)))
    }

    // MARK: - Test helpers

    private func makeProviderForPlaceholderTest(
        root: URL,
        basename: String,
        placeholderStatus: URLUbiquitousItemDownloadingStatus
    ) -> FakeUbiquityProvider {
        let fake = FakeUbiquityProvider()
        let dir = root.appendingPathComponent("contacts")
        let placeholderURL = dir.appendingPathComponent(".\(basename).json.icloud")
        fake.downloadingStatus[placeholderURL] = placeholderStatus
        return fake
    }

    private func plantPlaceholder(in root: URL, kindDir: String, basename: String) throws {
        let dir = root.appendingPathComponent(kindDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let placeholderName = ".\(basename).json.icloud"
        let url = dir.appendingPathComponent(placeholderName)
        try Data().write(to: url)
    }
}
