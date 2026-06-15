import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("NotesEnvelope")
struct NotesEnvelopeTests {
    private let entityID = "550e8400-e29b-41d4-a716-446655440000"
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)
    private let t3 = Date(timeIntervalSince1970: 1_700_001_000)
    private let idX = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idY = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let idZ = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    @Test
    func threeWayFoldOfDisjointNotes_allThreeSurvive() throws {
        let nX = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "X")
        let nY = makeNote(id: idY, modifiedAt: t2, modifiedBy: "device-B", body: "Y")
        let nZ = makeNote(id: idZ, modifiedAt: t3, modifiedBy: "device-C", body: "Z")
        let envA = envelope(notes: [nX])
        let envB = envelope(notes: [nY])
        let envC = envelope(notes: [nZ])

        let store = InMemorySidecarStore()
        store.scriptConflict(at: key(), versions: [
            try encode(envA), try encode(envB), try encode(envC),
        ])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()
        #expect(report.fileOutcomes.count == 1)
        #expect(report.fileOutcomes[0].mergedVersionCount == 3)
        #expect(report.fileOutcomes[0].skippedReasons.isEmpty)

        let merged = try #require(try store.read(key()))
        let notes = NotesCellCodec.decode(merged.fields["notes"])
        #expect(Set(notes) == Set([nX, nY, nZ]))
    }

    @Test
    func threeWayFoldWithTwoTombstonesSameID_laterTombstoneWins_noResurrection() throws {
        let live = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "alive")
        let tombEarly = makeNote(id: idX, modifiedAt: t2, modifiedBy: "device-B", body: "", deleted: true)
        let tombLate = makeNote(id: idX, modifiedAt: t3, modifiedBy: "device-C", body: "", deleted: true)

        let envA = envelope(notes: [live])
        let envB = envelope(notes: [tombEarly])
        let envC = envelope(notes: [tombLate])

        let store = InMemorySidecarStore()
        store.scriptConflict(at: key(), versions: [
            try encode(envA), try encode(envB), try encode(envC),
        ])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()
        #expect(report.fileOutcomes.count == 1)
        #expect(report.fileOutcomes[0].mergedVersionCount == 3)

        let merged = try #require(try store.read(key()))
        let notes = NotesCellCodec.decode(merged.fields["notes"])
        #expect(notes.count == 1)
        let survivor = try #require(notes.first)
        #expect(survivor.id == idX)
        #expect(survivor.deleted == true)
        #expect(survivor.modifiedAt == t3)
        #expect(survivor.modifiedBy == "device-C")
        // No resurrection: the live edit from envA loses LWW against the
        // later-stamped tombstone, so no live copy of idX remains.
        #expect(notes.contains(where: { !$0.deleted }) == false)
    }

    // MARK: - Helpers

    private func makeNote(
        id: UUID,
        modifiedAt: Date,
        modifiedBy: String,
        body: String,
        deleted: Bool = false
    ) -> ContactNote {
        ContactNote(
            id: id,
            createdAt: t1,
            modifiedAt: modifiedAt,
            modifiedBy: modifiedBy,
            body: body,
            deleted: deleted
        )
    }

    private func envelope(notes: [ContactNote]) -> SidecarEnvelope {
        let cell = NotesCellCodec.encodeCell(notes)
        let fields: [String: SidecarCell] = cell.map { ["notes": $0] } ?? [:]
        return SidecarEnvelope(schemaVersion: 1, entityID: entityID, fields: fields)
    }

    private func key() -> SidecarKey {
        SidecarKey(kind: .contact, id: entityID)
    }

    private func encode(_ env: SidecarEnvelope) throws -> Data {
        try JSONEncoder().encode(env)
    }

    private func makeSync(sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }
}
