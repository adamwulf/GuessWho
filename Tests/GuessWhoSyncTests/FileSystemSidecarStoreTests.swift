import Foundation
import Testing
@testable import GuessWhoSync

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
            switch (lhs.fields[key], rhs.fields[key]) {
            case let (.value(lv, lt, lb)?, .value(rv, rt, rb)?):
                #expect(lv == rv)
                #expect(lt == rt)
                #expect(lb == rb)
            case let (.tombstone(lt, lb)?, .tombstone(rt, rb)?):
                #expect(lt == rt)
                #expect(lb == rb)
            default:
                Issue.record("cells differ in shape at key \(key)")
            }
        }
    }

    @Test
    func writeThenReadReturnsSameEnvelope() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "abc")
        let env = envelope(id: "abc", fields: [
            "nickname": .value(.string("Bear"), modifiedAt: when, modifiedBy: "device-A")
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
            "note": .value(.string("hi"), modifiedAt: when, modifiedBy: "device-A")
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

        let outcomes = try store.reconcileConflicts { _, _ in
            Issue.record("closure should not be called when no conflicts exist")
            return .leave
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
            "nickname": .value(.string("Coord"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(env, at: key)
        let fetched = try #require(try store.read(key))
        expectEqual(fetched, env)

        try store.delete(key)
        #expect(try store.read(key) == nil)
    }

    // NSFileVersion.addOfItem(at:withContentsOf:options:) is macOS-only. On macOS in a sandbox-free
    // dev shell, adding a version yields an "other version" (isConflict=false) — not an unresolved
    // conflict. Unresolved conflicts in practice come from iCloud Drive sync. The tests below
    // attempt injection and skip the conflict-resolution assertions if the environment couldn't
    // produce one, while still exercising the wiring whenever it can.
    #if os(macOS)
    private func injectConflict(at url: URL, root: URL, envelope: SidecarEnvelope) throws {
        let stagingURL = root.appendingPathComponent("staging-\(UUID().uuidString).json")
        try JSONEncoder().encode(envelope).write(to: stagingURL, options: [.atomic])
        _ = try NSFileVersion.addOfItem(at: url, withContentsOf: stagingURL, options: [])
        try? FileManager.default.removeItem(at: stagingURL)
    }

    @Test
    func realConflictResolutionWritesMergedAndRemovesConflict() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "abc")

        let currentEnv = envelope(id: "abc", fields: [
            "nickname": .value(.string("Original"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(currentEnv, at: key)

        let url = root.appendingPathComponent("contacts").appendingPathComponent("abc.json")
        try injectConflict(at: url, root: root, envelope: envelope(id: "abc", fields: [
            "nickname": .value(.string("FromOther"), modifiedAt: when, modifiedBy: "device-B")
        ]))

        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else {
            // No iCloud — environment can't surface an unresolved conflict; nothing to assert.
            return
        }

        let merged = envelope(id: "abc", fields: [
            "nickname": .value(.string("Merged"), modifiedAt: when, modifiedBy: "device-C")
        ])
        let outcomes = try store.reconcileConflicts { receivedKey, versions in
            #expect(receivedKey == key)
            #expect(versions.count >= 2)
            return .write(merged: merged, skip: [])
        }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.key == key)
        #expect(outcomes.first?.skippedReasons.isEmpty == true)

        let fetched = try #require(try store.read(key))
        expectEqual(fetched, merged)

        let after = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        #expect(after.isEmpty)
    }

    @Test
    func recoverySiblingWriteLeavesOriginalAndConflictIntact() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "abc")

        let currentEnv = envelope(id: "abc", fields: [
            "nickname": .value(.string("Original"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(currentEnv, at: key)
        let url = root.appendingPathComponent("contacts").appendingPathComponent("abc.json")
        let originalBytes = try Data(contentsOf: url)

        try injectConflict(at: url, root: root, envelope: envelope(id: "abc", fields: [
            "nickname": .value(.string("FromOther"), modifiedAt: when, modifiedBy: "device-B")
        ]))

        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return }

        let merged = envelope(id: "abc", fields: [
            "nickname": .value(.string("Recovered"), modifiedAt: when, modifiedBy: "device-C")
        ])
        let suffix = "test"
        let outcomes = try store.reconcileConflicts { _, _ in
            .writeRecoverySibling(merged: merged, suffix: suffix)
        }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.mergedVersionCount == 0)
        #expect(outcomes.first?.skippedReasons.contains { $0.contains(suffix) } == true)

        let siblingURL = root.appendingPathComponent("contacts/abc.recovered.test.json")
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
        let siblingData = try Data(contentsOf: siblingURL)
        let siblingEnv = try JSONDecoder().decode(SidecarEnvelope.self, from: siblingData)
        expectEqual(siblingEnv, merged)

        let originalNow = try Data(contentsOf: url)
        #expect(originalNow == originalBytes)

        let stillConflict = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        #expect(!stillConflict.isEmpty)
    }

    @Test
    func closureThrowingRecordsFailureAndDoesNotRethrow() throws {
        struct ResolveBoom: Error, CustomStringConvertible {
            var description: String { "kaboom" }
        }
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(root: root)
        let key = SidecarKey(kind: .contact, id: "abc")
        try store.write(envelope(id: "abc"), at: key)

        let url = root.appendingPathComponent("contacts").appendingPathComponent("abc.json")
        try injectConflict(at: url, root: root, envelope: envelope(id: "abc"))

        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return }

        let outcomes = try store.reconcileConflicts { _, _ in
            throw ResolveBoom()
        }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.key == key)
        #expect(outcomes.first?.mergedVersionCount == 0)
        #expect(outcomes.first?.skippedReasons.contains { $0.contains("kaboom") } == true)
    }
    #endif
}
