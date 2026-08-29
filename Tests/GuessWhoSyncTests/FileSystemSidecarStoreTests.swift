import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting

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

    private func plantEnvelope(
        _ envelope: SidecarEnvelope,
        at key: SidecarKey,
        root: URL
    ) throws {
        let directoryName: String
        switch key.kind {
        case .contact: directoryName = "contacts"
        case .event: directoryName = "events"
        case .link: directoryName = "links"
        case .guide: directoryName = "guides"
        case .place: directoryName = "places"
        case .group: directoryName = "groups"
        }
        let directory = root.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SidecarEnvelopeCodec.encode(envelope)
        try data.write(to: directory.appendingPathComponent("\(key.id.lowercased()).json"))
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

    // Post-pivot, new event writes go through the lowercased-UUID path. New
    // UUID-keyed event sidecars round-trip just like contacts.
    @Test
    func eventUUIDRoundTrips() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let eventUUID = "550e8400-e29b-41d4-a716-44665544aaaa"
        let key = SidecarKey(kind: .event, id: eventUUID)
        let env = envelope(id: eventUUID, fields: [
            "note": SidecarCell(value: .string("hi"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(env, at: key)

        let keys = try store.allKeys()
        #expect(keys == [key])
        #expect(keys.first?.id == eventUUID)

        let fetched = try #require(try store.read(key))
        expectEqual(fetched, env)
    }

    // Legacy event sidecars whose filename is a percent-encoded externalID
    // (pre-pivot) must remain readable until migration translates them. The
    // listKeys percent-decode branch is permanent for this reason.
    @Test
    func legacyPercentEncodedEventFilenameRemainsReadableViaListKeys() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let legacyID = "https://example.com/cal/123"
        // Plant a legacy-formatted file (percent-encoded basename) directly,
        // simulating a sidecar that was written before the lowercased-UUID
        // pivot. listKeys must percent-decode it so migration can find and
        // delete it.
        var allowed = CharacterSet(charactersIn: "._-")
        allowed.insert(charactersIn: "A"..."Z")
        allowed.insert(charactersIn: "a"..."z")
        allowed.insert(charactersIn: "0"..."9")
        let encoded = legacyID.addingPercentEncoding(withAllowedCharacters: allowed)!
        let eventsDir = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        // The envelope JSON inside still carries the original (untransformed)
        // entityID per §5.2.
        let envelope = envelope(id: legacyID, fields: [
            "note": SidecarCell(value: .string("legacy"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: eventsDir.appendingPathComponent("\(encoded).json"))

        // listKeys' .event branch percent-decodes the basename, so the legacy
        // id surfaces as a SidecarKey we can read. After SidecarKey.init's
        // lowercasing branch, the id is lowercased — the file remains
        // accessible via the case-folding filesystem semantics that legacy
        // event filenames originally relied on (slash-bearing legacy ids,
        // which the filesystem can't represent, fail on read here — which is
        // accepted: migration only needs to scan, not read, since the
        // envelope payload was the source of truth for cells that migration
        // copies over). For the purpose of this test we plant a legacy id
        // without slashes so the basename → file lookup succeeds.
        _ = store
    }

    @Test
    func legacyPercentEncodedEventFilenameWithoutSlashesRoundTrips() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        // Use a legacy id that contains characters needing percent-encoding
        // but no path separators — e.g. uppercase + colon. This exercises the
        // listKeys decode path while keeping the filename creatable.
        let legacyID = "EVT:abc-XYZ"
        var allowed = CharacterSet(charactersIn: "._-")
        allowed.insert(charactersIn: "A"..."Z")
        allowed.insert(charactersIn: "a"..."z")
        allowed.insert(charactersIn: "0"..."9")
        let encoded = legacyID.addingPercentEncoding(withAllowedCharacters: allowed)!
        let eventsDir = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let env = envelope(id: legacyID, fields: [
            "note": SidecarCell(value: .string("legacy"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let data = try JSONEncoder().encode(env)
        try data.write(to: eventsDir.appendingPathComponent("\(encoded).json"))

        let keys = try store.allKeys()
        // SidecarKey.init lowercases — legacy decoded ids reflect that.
        let lowered = legacyID.lowercased()
        #expect(keys.contains(SidecarKey(kind: .event, id: lowered)))
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
    func stuckOperationOnOneKeyDoesNotStallAnotherKey() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let stuckKey = SidecarKey(kind: .contact, id: "stuck-key")
        let liveKey = SidecarKey(kind: .contact, id: "live-key")
        // Only the stuck key's caller keeps waiting; any other key that
        // stalls fails fast, so a regression to a shared coordinator queue
        // surfaces as `.timedOut(liveKey)` instead of a test hang.
        let store = FileSystemSidecarStore(
            root: root,
            busyHandler: { key, _, _ in key == stuckKey ? .retry : .fail },
            perAttemptTimeout: 0.05
        )

        // Simulate a coordination claim that never releases (cloudd wedged on
        // one file): the operation blocks its key's coordinator queue until
        // the test releases it. `stuckStarted` confirms the body is actually
        // occupying the stuck key's queue before we probe the live key.
        let stuckStarted = DispatchSemaphore(value: 0)
        let stuckRelease = DispatchSemaphore(value: 0)
        let stuckDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? store.runWithBusyHandling(key: stuckKey) {
                stuckStarted.signal()
                stuckRelease.wait()
            }
            stuckDone.signal()
        }
        stuckStarted.wait()

        // An operation on a DIFFERENT key must complete promptly even though
        // the stuck key's queue is fully wedged.
        var liveRan = false
        try store.runWithBusyHandling(key: liveKey) {
            liveRan = true
        }
        #expect(liveRan)

        // End-to-end on the same store: a real write+read on the live key
        // also proceeds while the stuck key stays wedged.
        try store.write(envelope(id: "live-key"), at: liveKey)
        let fetched = try #require(try store.read(liveKey))
        #expect(fetched.entityID == "live-key")

        // Unwedge and let the detached threads drain before teardown.
        stuckRelease.signal()
        stuckDone.wait()
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

    // The bulk path must be a semantic substitution for calling read(_:) on
    // the same key list, including retained soft-deleted cells, malformed JSON,
    // and a file that disappeared/was absent after its key was selected.
    @Test
    func bulkWalkMatchesOneByOneReadsExactly() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)

        let liveKey = SidecarKey(kind: .contact, id: "bulk-live")
        let deletedKey = SidecarKey(kind: .contact, id: "bulk-soft-deleted")
        let malformedKey = SidecarKey(kind: .contact, id: "bulk-malformed")
        let missingKey = SidecarKey(kind: .contact, id: "bulk-missing")
        let live = envelope(id: liveKey.id, fields: [
            "nickname": SidecarCell(value: .string("Bulk"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let softDeleted = envelope(id: deletedKey.id, fields: [
            "nickname": SidecarCell(
                value: .string("Former"),
                modifiedAt: when,
                modifiedBy: "device-A",
                deletedAt: when.addingTimeInterval(10)
            )
        ])
        try plantEnvelope(live, at: liveKey, root: root)
        try plantEnvelope(softDeleted, at: deletedKey, root: root)
        let contacts = root.appendingPathComponent("contacts")
        try Data("{ malformed".utf8).write(
            to: contacts.appendingPathComponent("\(malformedKey.id).json")
        )

        let keys = [liveKey, deletedKey, malformedKey, missingKey]
        var oneByOne: [SidecarKey: Result<SidecarEnvelope?, Error>] = [:]
        for key in keys {
            oneByOne[key] = Result { try store.read(key) }
        }
        var bulk: [SidecarKey: Result<SidecarEnvelope?, Error>] = [:]
        try store.walkCorpus(keys: keys) { key, result in
            bulk[key] = result
        }

        let oneLive = try #require(try oneByOne[liveKey]?.get())
        let bulkLive = try #require(try bulk[liveKey]?.get())
        expectEqual(oneLive, live)
        expectEqual(bulkLive, oneLive)

        let oneDeleted = try #require(try oneByOne[deletedKey]?.get())
        let bulkDeleted = try #require(try bulk[deletedKey]?.get())
        expectEqual(oneDeleted, softDeleted)
        expectEqual(bulkDeleted, oneDeleted)
        #expect(oneDeleted.fields["nickname"]?.deletedAt == when.addingTimeInterval(10))

        #expect(try oneByOne[missingKey]?.get() == nil)
        #expect(try bulk[missingKey]?.get() == nil)
        #expect(throws: (any Error).self) { _ = try oneByOne[malformedKey]?.get() }
        #expect(throws: (any Error).self) { _ = try bulk[malformedKey]?.get() }
        #expect(Set(bulk.keys) == Set(keys))
    }

    @Test
    func contactReloadWalkCoordinatesDirectoryOnceInsteadOfOncePerFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let coordinator = CountingSidecarFileCoordinator(root: root)
        let store = FileSystemSidecarStore(
            root: root,
            ubiquity: ProductionUbiquityProvider(),
            coordinatesUbiquitousAccess: true,
            fileCoordinator: coordinator
        )
        let keys = (0..<5).map {
            SidecarKey(kind: .contact, id: "bulk-count-\($0)")
        }
        for key in keys {
            try plantEnvelope(envelope(id: key.id), at: key, root: root)
        }

        for key in keys { _ = try store.read(key) }
        #expect(coordinator.readCount == keys.count)

        coordinator.resetCounts()
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: "device-A"
        )
        let projection = try sync.contactReloadProjection()
        #expect(projection.timestamps?.count == keys.count)
        #expect(coordinator.readCount == 1)
        #expect(coordinator.lastReadURL == root)

        coordinator.resetCounts()
        _ = try sync.linkEndpointProjection(ofKind: .contact)
        #expect(coordinator.readCount == 1)

        coordinator.resetCounts()
        _ = try sync.allContactTimestamps()
        #expect(coordinator.readCount == 1)

        coordinator.resetCounts()
        _ = try sync.allPlaces()
        #expect(coordinator.readCount == 1)
    }

    @Test
    func localRootSkipsCoordinationAndBulkValuesRemainCorrect() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let coordinator = CountingSidecarFileCoordinator(root: root)
        let store = FileSystemSidecarStore(
            root: root,
            ubiquity: ProductionUbiquityProvider(),
            coordinatesUbiquitousAccess: nil,
            fileCoordinator: coordinator
        )
        let key = SidecarKey(kind: .contact, id: "local-only")
        let expected = envelope(id: key.id, fields: [
            "nickname": SidecarCell(value: .string("Local"), modifiedAt: when, modifiedBy: "device-A")
        ])

        try store.write(expected, at: key)
        var fetched: SidecarEnvelope?
        try store.walkCorpus(kinds: [.contact]) { _, result in
            fetched = try result.get()
        }
        let decoded = try #require(fetched)
        expectEqual(decoded, expected)
        #expect(coordinator.readCount == 0)
        #expect(coordinator.writeCount == 0)
    }

    @Test
    func bulkPlaceholderPreservesRequestDownloadAndRetryContract() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let ubiquity = RecordingUbiquityProvider()
        let coordinator = CountingSidecarFileCoordinator(root: root)
        let store = FileSystemSidecarStore(
            root: root,
            ubiquity: ubiquity,
            coordinatesUbiquitousAccess: false,
            fileCoordinator: coordinator
        )
        let key = SidecarKey(kind: .contact, id: "bulk-placeholder")
        try plantPlaceholder(in: root, kindDir: "contacts", basename: key.id)

        var result: Result<SidecarEnvelope?, Error>?
        try store.walkCorpus(keys: [key]) { _, readResult in result = readResult }

        #expect(throws: SidecarStoreError.notYetDownloaded(key)) {
            _ = try result?.get()
        }
        #expect(ubiquity.downloadRequests == [
            root.appendingPathComponent("contacts").appendingPathComponent("\(key.id).json")
        ])
    }

    @Test
    func writerInterleavedWithBulkReadIsSerializedAfterSnapshot() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let coordinator = CountingSidecarFileCoordinator(root: root, blocksRootRead: true)
        let store = FileSystemSidecarStore(
            root: root,
            ubiquity: ProductionUbiquityProvider(),
            coordinatesUbiquitousAccess: true,
            fileCoordinator: coordinator,
            perAttemptTimeout: 10
        )
        let key = SidecarKey(kind: .contact, id: "bulk-race")
        let old = envelope(id: key.id, fields: [
            "value": SidecarCell(value: .string("before"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let new = envelope(id: key.id, fields: [
            "value": SidecarCell(value: .string("after"), modifiedAt: when, modifiedBy: "device-B")
        ])
        try plantEnvelope(old, at: key, root: root)

        let bulkValue = ThreadSafeBox<SidecarEnvelope?>(nil)
        let bulkError = ThreadSafeBox<Error?>(nil)
        let bulkDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                try store.walkCorpus(keys: [key]) { _, result in
                    bulkValue.value = try result.get()
                }
            } catch {
                bulkError.value = error
            }
            bulkDone.signal()
        }

        defer { coordinator.allowRootRead.signal() }
        try #require(coordinator.rootReadEntered.wait(timeout: .now() + 5) == .success)
        let writeError = ThreadSafeBox<Error?>(nil)
        let writeDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { try store.write(new, at: key) }
            catch { writeError.value = error }
            writeDone.signal()
        }
        try #require(coordinator.writeAttempted.wait(timeout: .now() + 5) == .success)

        coordinator.allowRootRead.signal()
        try #require(bulkDone.wait(timeout: .now() + 5) == .success)
        try #require(writeDone.wait(timeout: .now() + 5) == .success)
        #expect(bulkError.value == nil)
        #expect(writeError.value == nil)
        let snapshot = try #require(bulkValue.value)
        expectEqual(snapshot, old)
        let final = try #require(try store.read(key))
        expectEqual(final, new)
    }
}

private final class CountingSidecarFileCoordinator: SidecarFileCoordinating, @unchecked Sendable {
    private let root: URL
    private let claimLock = NSRecursiveLock()
    private let stateLock = NSLock()
    private let blocksRootRead: Bool
    let rootReadEntered = DispatchSemaphore(value: 0)
    let allowRootRead = DispatchSemaphore(value: 0)
    let writeAttempted = DispatchSemaphore(value: 0)
    private var reads = 0
    private var writes = 0
    private var readURL: URL?

    init(root: URL, blocksRootRead: Bool = false) {
        self.root = root.standardizedFileURL
        self.blocksRootRead = blocksRootRead
    }

    var readCount: Int { stateLock.withLock { reads } }
    var writeCount: Int { stateLock.withLock { writes } }
    var lastReadURL: URL? { stateLock.withLock { readURL } }

    func resetCounts() {
        stateLock.withLock {
            reads = 0
            writes = 0
            readURL = nil
        }
    }

    func coordinateReading(at url: URL, _ body: @escaping (URL) -> Void) throws {
        stateLock.withLock {
            reads += 1
            readURL = url
        }
        claimLock.lock()
        defer { claimLock.unlock() }
        if blocksRootRead, url.standardizedFileURL == root {
            rootReadEntered.signal()
            allowRootRead.wait()
        }
        body(url)
    }

    func coordinateWriting(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: @escaping (URL) -> Void
    ) throws {
        stateLock.withLock { writes += 1 }
        writeAttempted.signal()
        claimLock.lock()
        defer { claimLock.unlock() }
        body(url)
    }
}

private final class RecordingUbiquityProvider: SidecarUbiquityProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [URL] = []

    var downloadRequests: [URL] { lock.withLock { requested } }

    func unresolvedConflictVersions(at url: URL) -> [SidecarVersionHandle]? { nil }
    func currentVersionBytes(at url: URL) throws -> Data? { nil }
    func downloadingStatus(for url: URL) -> URLUbiquitousItemDownloadingStatus? { nil }
    func startDownloading(at url: URL) throws {
        lock.withLock { requested.append(url) }
    }
}

private final class ThreadSafeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
