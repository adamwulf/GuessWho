import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
@_spi(ConflictReconcile) import GuessWhoSyncTesting

@Suite("InMemorySidecarStore")
struct InMemorySidecarStoreTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func envelope(
        id: String = "550e8400-e29b-41d4-a716-446655440000",
        fields: [String: SidecarCell] = [:]
    ) -> SidecarEnvelope {
        SidecarEnvelope(entityID: id, fields: fields)
    }

    private func contactKey(_ id: String = "550e8400-e29b-41d4-a716-446655440000") -> SidecarKey {
        SidecarKey(kind: .contact, id: id)
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
        let store = InMemorySidecarStore()
        let key = contactKey()
        let env = envelope(fields: [
            "nickname": SidecarCell(value: .string("Bear"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(env, at: key)
        let fetched = try #require(try store.read(key))
        expectEqual(fetched, env)
    }

    @Test
    func readOfMissingKeyReturnsNil() throws {
        let store = InMemorySidecarStore()
        #expect(try store.read(contactKey()) == nil)
    }

    @Test
    func deleteRemovesKey() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        try store.write(envelope(), at: key)
        try store.delete(key)
        #expect(try store.read(key) == nil)
        #expect(try store.allKeys().isEmpty)
    }

    @Test
    func allKeysReturnsEveryWrittenKey() throws {
        let store = InMemorySidecarStore()
        let a = SidecarKey(kind: .contact, id: "a")
        let b = SidecarKey(kind: .contact, id: "b")
        let c = SidecarKey(kind: .event, id: "evt")
        try store.write(envelope(id: "a"), at: a)
        try store.write(envelope(id: "b"), at: b)
        try store.write(envelope(id: "evt"), at: c)

        let keys = try store.allKeys()
        #expect(Set(keys) == [a, b, c])
        #expect(keys.count == 3)
    }

    @Test
    func writeOfOneEntityDoesNotAffectAnother() throws {
        let store = InMemorySidecarStore()
        let a = SidecarKey(kind: .contact, id: "a")
        let b = SidecarKey(kind: .contact, id: "b")
        let envA = envelope(id: "a", fields: [
            "x": SidecarCell(value: .string("A"), modifiedAt: when, modifiedBy: "device")
        ])
        let envB = envelope(id: "b", fields: [
            "y": SidecarCell(value: .string("B"), modifiedAt: when, modifiedBy: "device")
        ])
        try store.write(envA, at: a)
        try store.write(envB, at: b)

        let fetchedA = try #require(try store.read(a))
        let fetchedB = try #require(try store.read(b))
        expectEqual(fetchedA, envA)
        expectEqual(fetchedB, envB)
    }

    @Test
    func scriptedConflictResolveUpdatesEnvelopeAndClearsConflict() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        let v1 = Data([0x01])
        let v2 = Data([0x02])
        store.scriptConflict(at: key, versions: [v1, v2])

        let merged = envelope(fields: [
            "nickname": SidecarCell(value: .string("Bear"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let outcomes = try store.reconcileAllConflicts { receivedKey, current, conflicts in
            #expect(receivedKey == key)
            // No current envelope was written for this key, so the store
            // passes nil as the current bytes. The two scripted versions
            // are the conflicts.
            #expect(current == nil)
            #expect(conflicts == [v1, v2])
            return merged
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].key == key)
        // Both scripted conflict versions participated; no current.
        #expect(outcomes[0].versionsConsidered == 2)
        #expect(outcomes[0].skippedReasons.isEmpty)

        let fetched = try #require(try store.read(key))
        expectEqual(fetched, merged)

        let secondPass = try store.reconcileAllConflicts { _, _, _ in
            Issue.record("conflict should have been cleared")
            return SidecarEnvelope(entityID: key.id, fields: [:])
        }
        #expect(secondPass.isEmpty)
    }

    @Test
    func scriptedConflictResolverReturningCurrentClearsConflictWithoutSemanticChange() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        let existing = envelope(fields: [
            "nickname": SidecarCell(value: .string("Original"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(existing, at: key)
        store.scriptConflict(at: key, versions: [Data([0x01])])

        let outcomes = try store.reconcileAllConflicts { _, _, _ in existing }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].versionsConsidered == 2) // current + 1 conflict
        #expect(outcomes[0].skippedReasons.isEmpty)

        // Conflict is cleared; envelope unchanged.
        let fetched = try #require(try store.read(key))
        expectEqual(fetched, existing)

        var sawConflictAgain = false
        _ = try store.reconcileAllConflicts { _, _, _ in
            sawConflictAgain = true
            return existing
        }
        #expect(sawConflictAgain == false)
    }

    @Test
    func scriptedConflictResolverThrowingRecordsErrorAndDoesNotRethrow() throws {
        struct ResolveBoom: Error, CustomStringConvertible {
            var description: String { "kaboom" }
        }
        let store = InMemorySidecarStore()
        let key = contactKey()
        store.scriptConflict(at: key, versions: [Data([0x01])])

        let outcomes = try store.reconcileAllConflicts { _, _, _ in
            throw ResolveBoom()
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].key == key)
        #expect(outcomes[0].versionsConsidered == 0)
        #expect(outcomes[0].skippedReasons.contains { $0.contains("kaboom") })
    }

    @Test
    func deleteClearsScriptedConflict() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        store.scriptConflict(at: key, versions: [Data([0x01])])
        try store.delete(key)

        let outcomes = try store.reconcileAllConflicts { _, _, _ in
            Issue.record("delete should have cleared the scripted conflict")
            return SidecarEnvelope(entityID: key.id, fields: [:])
        }
        #expect(outcomes.isEmpty)
    }

    @Test
    func downloadStatusReportsDownloadedForKnownKey() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        try store.write(envelope(), at: key)
        #expect(store.downloadStatus(key) == .downloaded)
    }

    @Test
    func downloadStatusReportsNotFoundForUnknownKey() throws {
        let store = InMemorySidecarStore()
        #expect(store.downloadStatus(contactKey("absent-id")) == .notFound)
    }

    @Test
    func requestDownloadIsNoOp() throws {
        let store = InMemorySidecarStore()
        try store.requestDownload(contactKey())
    }
}

// A minimal SidecarStoreProtocol conformer that implements only the v1
// surface — no conflict methods (those live on the @_spi
// SidecarConflictReconciling protocol; a backend with no multi-version
// conflict notion legitimately doesn't conform to it). Also deliberately
// does NOT implement downloadStatus / requestDownload so the protocol-
// extension defaults are exercised. This proves a third-party store
// without conflict semantics still composes with the orchestrator;
// reconcileSidecars() simply returns an empty report.
private final class MinimalSidecarStore: SidecarStoreProtocol {
    var envelopes: [SidecarKey: SidecarEnvelope] = [:]
    var throwNotYetDownloadedFor: Set<SidecarKey> = []

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        if throwNotYetDownloadedFor.contains(key) {
            throw SidecarStoreError.notYetDownloaded(key)
        }
        return envelopes[key]
    }

    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        envelopes[key] = envelope
    }

    func delete(_ key: SidecarKey) throws {
        envelopes.removeValue(forKey: key)
    }

    func allKeys() throws -> [SidecarKey] {
        Array(envelopes.keys)
    }
}

@Suite("ProtocolDefaults")
struct ProtocolDefaultsTests {
    @Test
    func defaultDownloadStatusReportsDownloadedForKnownKey() throws {
        let store = MinimalSidecarStore()
        let key = SidecarKey(kind: .contact, id: "known")
        try store.write(SidecarEnvelope(entityID: "known", fields: [:]), at: key)
        #expect(store.downloadStatus(key) == .downloaded)
    }

    @Test
    func defaultDownloadStatusReportsNotFoundForUnknownKey() throws {
        let store = MinimalSidecarStore()
        #expect(store.downloadStatus(SidecarKey(kind: .contact, id: "unknown")) == .notFound)
    }

    @Test
    func defaultDownloadStatusMapsNotYetDownloadedToNotStarted() throws {
        let store = MinimalSidecarStore()
        let key = SidecarKey(kind: .contact, id: "remote-pending")
        store.throwNotYetDownloadedFor.insert(key)
        #expect(store.downloadStatus(key) == .notStarted)
    }

    @Test
    func defaultRequestDownloadIsNoOp() throws {
        let store = MinimalSidecarStore()
        try store.requestDownload(SidecarKey(kind: .contact, id: "x"))
    }

    @Test
    func reconcileSidecarsOnStoreWithoutConflictReconcilingReturnsEmptyReport() throws {
        // A third-party SidecarStoreProtocol conformer with no concept of
        // multi-version conflicts won't implement SidecarConflictReconciling.
        // The orchestrator's as? cast fails; reconcileSidecars() returns an
        // empty report (it's still safe to call).
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: MinimalSidecarStore(),
            deviceID: "device-A"
        )
        let report = try sync.reconcileSidecars()
        #expect(report.fileOutcomes.isEmpty)
    }
}
