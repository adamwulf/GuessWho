import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

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
        let store = InMemorySidecarStore()
        let key = contactKey()
        let env = envelope(fields: [
            "nickname": .value(.string("Bear"), modifiedAt: when, modifiedBy: "device-A")
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
            "x": .value(.string("A"), modifiedAt: when, modifiedBy: "device")
        ])
        let envB = envelope(id: "b", fields: [
            "y": .value(.string("B"), modifiedAt: when, modifiedBy: "device")
        ])
        try store.write(envA, at: a)
        try store.write(envB, at: b)

        let fetchedA = try #require(try store.read(a))
        let fetchedB = try #require(try store.read(b))
        expectEqual(fetchedA, envA)
        expectEqual(fetchedB, envB)
    }

    @Test
    func scriptedConflictResolveWriteUpdatesEnvelopeAndClearsConflict() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        let v1 = Data([0x01])
        let v2 = Data([0x02])
        store.scriptConflict(at: key, versions: [v1, v2])

        let merged = envelope(fields: [
            "nickname": .value(.string("Bear"), modifiedAt: when, modifiedBy: "device-A")
        ])
        let outcomes = try store.reconcileConflicts { receivedKey, versions in
            #expect(receivedKey == key)
            #expect(versions == [v1, v2])
            return .write(merged: merged, skip: [])
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].key == key)
        #expect(outcomes[0].mergedVersionCount == 2)
        #expect(outcomes[0].skippedReasons.isEmpty)

        let fetched = try #require(try store.read(key))
        expectEqual(fetched, merged)

        let secondPass = try store.reconcileConflicts { _, _ in
            Issue.record("conflict should have been cleared")
            return .leave
        }
        #expect(secondPass.isEmpty)
    }

    @Test
    func scriptedConflictResolveLeaveDoesNotUpdateEnvelope() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        let existing = envelope(fields: [
            "nickname": .value(.string("Original"), modifiedAt: when, modifiedBy: "device-A")
        ])
        try store.write(existing, at: key)
        store.scriptConflict(at: key, versions: [Data([0x01])])

        let outcomes = try store.reconcileConflicts { _, _ in .leave }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].mergedVersionCount == 0)
        #expect(outcomes[0].skippedReasons.isEmpty)

        let fetched = try #require(try store.read(key))
        expectEqual(fetched, existing)

        var sawConflictAgain = false
        _ = try store.reconcileConflicts { _, _ in
            sawConflictAgain = true
            return .leave
        }
        #expect(sawConflictAgain)
    }

    @Test
    func scriptedConflictResolveRecoverySiblingLeavesConflictAndReportsSuffix() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        store.scriptConflict(at: key, versions: [Data([0x01])])

        let outcomes = try store.reconcileConflicts { _, _ in
            .writeRecoverySibling(merged: self.envelope(), suffix: "recovered.20260614")
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].mergedVersionCount == 0)
        #expect(outcomes[0].skippedReasons == ["wrote recovery sibling: recovered.20260614"])

        var sawConflictAgain = false
        _ = try store.reconcileConflicts { _, _ in
            sawConflictAgain = true
            return .leave
        }
        #expect(sawConflictAgain)
    }

    @Test
    func scriptedConflictResolverThrowingRecordsErrorAndDoesNotRethrow() throws {
        struct ResolveBoom: Error, CustomStringConvertible {
            var description: String { "kaboom" }
        }
        let store = InMemorySidecarStore()
        let key = contactKey()
        store.scriptConflict(at: key, versions: [Data([0x01])])

        let outcomes = try store.reconcileConflicts { _, _ in
            throw ResolveBoom()
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].key == key)
        #expect(outcomes[0].mergedVersionCount == 0)
        #expect(outcomes[0].skippedReasons.contains { $0.contains("kaboom") })
    }

    @Test
    func scriptedConflictSkipMatchingIsByByteEquality() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        let v1 = Data([0x01, 0x02])
        let v2 = Data([0x03, 0x04])
        let v3 = Data([0x05, 0x06])
        store.scriptConflict(at: key, versions: [v1, v2, v3])

        let merged = envelope()
        let outcomes = try store.reconcileConflicts { _, _ in
            .write(merged: merged, skip: [Data([0x03, 0x04])])
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].mergedVersionCount == 2)
    }

    @Test
    func deleteClearsScriptedConflict() throws {
        let store = InMemorySidecarStore()
        let key = contactKey()
        store.scriptConflict(at: key, versions: [Data([0x01])])
        try store.delete(key)

        let outcomes = try store.reconcileConflicts { _, _ in
            Issue.record("delete should have cleared the scripted conflict")
            return .leave
        }
        #expect(outcomes.isEmpty)
    }
}
