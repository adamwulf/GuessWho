import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync

@Suite("FileSystemSidecarStore")
struct FileSystemSidecarStoreTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func envelope(
        id: String = "550e8400-e29b-41d4-a716-446655440000",
        fields: [String: SidecarCell] = [:]
    ) -> SidecarEnvelope {
        SidecarEnvelope(entityID: id, fields: fields)
    }

    private func expectEqual(_ lhs: SidecarEnvelope, _ rhs: SidecarEnvelope) {
        #expect(lhs.entityID == rhs.entityID)
        #expect(lhs.schemaVersion == rhs.schemaVersion)
        #expect(lhs.fields.keys == rhs.fields.keys)
        for key in lhs.fields.keys {
            guard let lc = lhs.fields[key], let rc = rhs.fields[key] else {
                Issue.record("cells differ in shape at key \(key)")
                continue
            }
            #expect(lc.value == rc.value)
            #expect(lc.modifiedAt == rc.modifiedAt)
            #expect(lc.modifiedBy == rc.modifiedBy)
            #expect(lc.deletedAt == rc.deletedAt)
        }
    }

    @Test
    func writeThenReadReturnsSameEnvelope() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "abc")
        let env = envelope(id: "abc", fields: [
            "nickname": SidecarCell(value: .string("Bear"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(env, at: key)
        let fetched = try #require(try store.read(key))
        expectEqual(fetched, env)
    }

    @Test
    func readOfMissingKeyReturnsNil() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        #expect(try store.read(SidecarKey(kind: .contact, id: "missing")) == nil)
    }

    @Test
    func deleteRemovesFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "abc")
        try store.write(envelope(id: "abc"), at: key)
        try store.delete(key)
        #expect(try store.read(key) == nil)
    }

    @Test
    func deleteOfNonexistentKeyIsNoOp() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        try store.delete(SidecarKey(kind: .contact, id: "never-written"))
    }

    @Test
    func allKeysReturnsEveryWrittenKey() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let a = SidecarKey(kind: .contact, id: "a")
        let b = SidecarKey(kind: .contact, id: "b")
        let c = SidecarKey(kind: .event, id: "evt")
        try store.write(envelope(id: "a"), at: a)
        try store.write(envelope(id: "b"), at: b)
        try store.write(envelope(id: "evt"), at: c)

        let keys = try store.allKeys()
        #expect(Set(keys) == [a, b, c])
        #expect(keys.count == 3)

        let envA = try #require(try store.read(a))
        let envB = try #require(try store.read(b))
        let envC = try #require(try store.read(c))
        #expect(envA.entityID == "a")
        #expect(envB.entityID == "b")
        #expect(envC.entityID == "evt")
    }

    @Test
    func eventExternalIDWithSlashRoundTrips() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let externalID = "https://example.com/cal/123"
        let key = SidecarKey(kind: .event, id: externalID)
        let env = envelope(id: externalID, fields: [
            "note": SidecarCell(value: .string("hi"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(env, at: key)

        let keys = try store.allKeys()
        #expect(keys == [key])
        #expect(keys.first?.id == externalID)

        let fetched = try #require(try store.read(key))
        expectEqual(fetched, env)
    }

    @Test
    func eventExternalIDWithOtherUnsafeCharsRoundTrips() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let externalID = "weird:id?with=stuff/and spaces"
        let key = SidecarKey(kind: .event, id: externalID)
        try store.write(envelope(id: externalID), at: key)

        let keys = try store.allKeys()
        #expect(keys == [key])
        #expect(keys.first?.id == externalID)

        let fetched = try #require(try store.read(key))
        #expect(fetched.entityID == externalID)
    }

    @Test
    func reconcileConflictsWithNoConflictsReturnsEmpty() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        try store.write(envelope(id: "abc"), at: SidecarKey(kind: .contact, id: "abc"))

        let outcomes = try store.reconcileAllConflicts { _, _, _ in
            Issue.record("closure should not be called when no conflicts exist")
            return SidecarEnvelope(entityID: "abc", fields: [:])
        }
        #expect(outcomes.isEmpty)
    }

    // MARK: - iCloud placeholder handling
    //
    // iCloud Drive represents a not-yet-downloaded sidecar `note.json` as a
    // sibling stub `.note.json.icloud`. We can't trigger a real iCloud download
    // in tests, but we can plant the placeholder file with the documented
    // naming and exercise the listKeys + read code paths.

    private func plantPlaceholder(in root: URL, kindDir: String, basename: String) throws {
        let dir = root.appendingPathComponent(kindDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let placeholderName = ".\(basename).json.icloud"
        let url = dir.appendingPathComponent(placeholderName)
        try Data().write(to: url)
    }

    @Test
    func listKeysIncludesContactPlaceholderStubs() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        try plantPlaceholder(in: root, kindDir: "contacts", basename: uuid)

        let keys = try store.allKeys()
        #expect(keys.contains(SidecarKey(kind: .contact, id: uuid)))
    }

    @Test
    func listKeysIncludesEventPlaceholderStubs() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        // Use an externalID with no characters that need percent-encoding
        // (so the basename and id match 1:1) and verify the event surfaces
        // from a placeholder stub.
        let basename = "evt-only"
        try plantPlaceholder(in: root, kindDir: "events", basename: basename)

        let keys = try store.allKeys()
        #expect(keys.contains(SidecarKey(kind: .event, id: "evt-only")))
    }

    @Test
    func listKeysDeduplicatesPlaceholderAndRealFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let key = SidecarKey(kind: .contact, id: "abc")
        try store.write(envelope(id: "abc"), at: key)
        // Plant a leftover placeholder alongside the real file (rare
        // transitional state on iCloud Drive). Only one key should surface.
        try plantPlaceholder(in: root, kindDir: "contacts", basename: "abc")

        let keys = try store.allKeys()
        #expect(keys == [key])
        #expect(keys.count == 1)
    }

    // MARK: - Busy handler

    @Test
    func busyHandlerHappyPathReturnsValueWithoutInvokingHandler() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        var handlerCalled = 0
        let store = FileSystemSidecarStore(
            root: root,
            busyHandler: { _, _, _ in
                handlerCalled += 1
                return .fail
            },
            perAttemptTimeout: 1.0
        )

        let key = SidecarKey(kind: .contact, id: "abc")
        try store.write(envelope(id: "abc"), at: key)
        #expect(handlerCalled == 0)
        let fetched = try #require(try store.read(key))
        #expect(fetched.entityID == "abc")
        #expect(handlerCalled == 0)
    }

    @Test
    func busyHandlerFailingImmediatelyThrowsTimedOut() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        var receivedAttempt: Int = -1
        var receivedElapsed: TimeInterval = -1
        let store = FileSystemSidecarStore(
            root: root,
            busyHandler: { _, attempt, elapsed in
                receivedAttempt = attempt
                receivedElapsed = elapsed
                return .fail
            },
            perAttemptTimeout: 0.05
        )
        let key = SidecarKey(kind: .contact, id: "busy-fail-key")
        #expect(throws: SidecarStoreError.timedOut(key)) {
            try store.runWithBusyHandling(key: key) {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        #expect(receivedAttempt == 0)
        #expect(receivedElapsed >= 0.04)
    }

    @Test
    func busyHandlerRetryDecisionRespectsHandlerSequence() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        var decisions: [SidecarBusyDecision] = [.retry, .retryAfter(0.0), .fail]
        var receivedAttempts: [Int] = []
        let store = FileSystemSidecarStore(
            root: root,
            busyHandler: { _, attempt, _ in
                receivedAttempts.append(attempt)
                return decisions.removeFirst()
            },
            perAttemptTimeout: 0.05
        )
        let key = SidecarKey(kind: .contact, id: "busy-retry-key")
        #expect(throws: SidecarStoreError.timedOut(key)) {
            try store.runWithBusyHandling(key: key) {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        // attempt 0 -> .retry, attempt 1 -> .retryAfter, attempt 2 -> .fail
        #expect(receivedAttempts == [0, 1, 2])
    }

    @Test
    func defaultBusyHandlerRetriesThreeTimesBeforeFailing() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        // Default handler: 3 attempts of .retryAfter, then .fail on attempt 3.
        var seenAttempts: [Int] = []
        let store = FileSystemSidecarStore(
            root: root,
            busyHandler: { key, attempt, elapsed in
                seenAttempts.append(attempt)
                // Delegate to default but with negligible delay to keep
                // the test fast — the test verifies the count, not the
                // absolute timing.
                let decision = defaultSidecarBusyHandler(
                    key: key,
                    attempt: attempt,
                    elapsed: elapsed
                )
                switch decision {
                case .retryAfter:
                    return .retry
                default:
                    return decision
                }
            },
            perAttemptTimeout: 0.02
        )
        let key = SidecarKey(kind: .contact, id: "default-handler")
        #expect(throws: SidecarStoreError.timedOut(key)) {
            try store.runWithBusyHandling(key: key) {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        // attempts 0, 1, 2 → .retry; attempt 3 → .fail (default fails at >= 3).
        #expect(seenAttempts == [0, 1, 2, 3])
    }

    @Test
    func downloadStatusReportsDownloadedForMaterializedFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let key = SidecarKey(kind: .contact, id: "abc")
        try store.write(envelope(id: "abc"), at: key)
        #expect(store.downloadStatus(key) == .downloaded)
    }

    @Test
    func downloadStatusReportsNotFoundForMissingFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        #expect(store.downloadStatus(SidecarKey(kind: .contact, id: "absent")) == .notFound)
    }

    @Test
    func downloadStatusReportsNotStartedForPlaceholder() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        try plantPlaceholder(in: root, kindDir: "contacts", basename: uuid)

        // The planted placeholder is an ordinary empty file (not a real
        // iCloud placeholder), so the OS won't report a downloading status.
        // The implementation falls back to .notStarted in that case.
        #expect(store.downloadStatus(SidecarKey(kind: .contact, id: uuid)) == .notStarted)
    }

    @Test
    func requestDownloadOnNonUbiquityURLThrows() throws {
        // Outside a ubiquity container, startDownloadingUbiquitousItem
        // errors. The store surfaces the error so app devs notice they're
        // pointed at a non-iCloud root.
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "needs-download")
        #expect(throws: (any Error).self) {
            try store.requestDownload(key)
        }
    }

    // Implementation chose approach (a) from the spec: read() of a placeholder
    // requests a download (via startDownloadingUbiquitousItem, best-effort)
    // and throws SidecarStoreError.notYetDownloaded so the orchestrator's
    // reconcile path can re-queue the read on a later pass.
    @Test
    func readOfPlaceholderThrowsNotYetDownloaded() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        try plantPlaceholder(in: root, kindDir: "contacts", basename: uuid)

        let key = SidecarKey(kind: .contact, id: uuid)
        #expect(throws: SidecarStoreError.notYetDownloaded(key)) {
            _ = try store.read(key)
        }
    }

    // Regression: NSFileCoordinator-wrapped read/write of a normal .json
    // round-trips identically to the pre-coordinator behavior.
    @Test
    func coordinatedReadWriteOfRegularFileRoundTrips() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let key = SidecarKey(kind: .contact, id: "round-trip-uuid")
        let env = envelope(id: "round-trip-uuid", fields: [
            "nickname": SidecarCell(value: .string("Coord"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(env, at: key)
        let fetched = try #require(try store.read(key))
        expectEqual(fetched, env)

        try store.delete(key)
        #expect(try store.read(key) == nil)
    }

    // Exercise the .icloud-placeholder branch of downloadStatus(_:) for an
    // event-kind key. The contact-kind variant is covered by
    // downloadStatusReportsNotStartedForPlaceholder above; this drives the
    // events `safeFilename` path through the placeholder-detection code so
    // the per-kind file-naming for downloadStatus doesn't silently break.
    @Test
    func downloadStatusReportsNotStartedForEventPlaceholder() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let basename = "evt-only"
        try plantPlaceholder(in: root, kindDir: "events", basename: basename)

        #expect(store.downloadStatus(SidecarKey(kind: .event, id: basename)) == .notStarted)
    }
}
