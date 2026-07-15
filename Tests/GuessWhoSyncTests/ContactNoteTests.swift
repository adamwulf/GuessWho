import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactNote (typed notes API)")
struct ContactNoteTests {
    private func makeOrchestrator(deviceID: String = "device-A") -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: events,
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars)
    }

    private let contactKey = SidecarKey(kind: .contact, id: "11111111-1111-1111-1111-111111111111")

    // MARK: - add / read

    @Test
    func addNoteRoundTrip() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addNote(at: contactKey, body: "Met at WWDC")
        let notes = try sync.notes(at: contactKey)
        #expect(notes.count == 1)
        #expect(notes[0].id == id)
        #expect(notes[0].body == "Met at WWDC")
        #expect(notes[0].deletedAt == nil)
    }

    @Test
    func addNoteAllowsEmptyBody() throws {
        // The convenience layer doesn't reject empty strings — the UI gates
        // user-facing whitespace. This is a *layer* contract: the package
        // round-trips whatever the caller hands it.
        let (sync, _) = makeOrchestrator()
        _ = try sync.addNote(at: contactKey, body: "")
        let notes = try sync.notes(at: contactKey)
        #expect(notes.count == 1)
        #expect(notes[0].body == "")
    }

    @Test
    func multipleNotesAreSeparateCells() throws {
        let (sync, _) = makeOrchestrator()
        let a = try sync.addNote(at: contactKey, body: "A")
        let b = try sync.addNote(at: contactKey, body: "B")
        #expect(a != b)
        let notes = try sync.notes(at: contactKey)
        #expect(notes.count == 2)
        #expect(Set(notes.map(\.body)) == Set(["A", "B"]))
    }

    // MARK: - createdAt ASC ordering

    @Test
    func notesSortByCreatedAtAscending() throws {
        let (sync, _) = makeOrchestrator()
        let first = try sync.addNote(at: contactKey, body: "oldest")
        // Use a fresh per-call sleep so the second cell's createdAt is
        // strictly newer than the first's at ISO8601 millisecond precision.
        Thread.sleep(forTimeInterval: 0.02)
        let second = try sync.addNote(at: contactKey, body: "middle")
        Thread.sleep(forTimeInterval: 0.02)
        let third = try sync.addNote(at: contactKey, body: "newest")

        let notes = try sync.notes(at: contactKey)
        #expect(notes.map(\.id) == [first, second, third])
        #expect(notes.map(\.body) == ["oldest", "middle", "newest"])
    }

    @Test
    func notesBreakCreatedAtTiesByIDString() throws {
        // Two cells with identical createdAt — pre-compose the envelope so
        // both share a single ISO8601 stamp, then assert ordering falls
        // back to id.uuidString.
        let (sync, sidecars) = makeOrchestrator()
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!

        func cell(body: String) -> SidecarCell {
            let inner = SidecarField.makeInnerValue(
                field: GuessWhoSync.contactNoteFieldName,
                type: .note,
                value: .string(body),
                createdAt: stamp
            )
            return SidecarCell(value: inner, modifiedAt: stamp, modifiedBy: "device-A")
        }

        try sidecars.write(
            SidecarEnvelope(
                entityID: contactKey.id,
                fields: [
                    highID.uuidString: cell(body: "high"),
                    lowID.uuidString: cell(body: "low"),
                ]
            ),
            at: contactKey
        )

        let notes = try sync.notes(at: contactKey)
        #expect(notes.map(\.id) == [lowID, highID])
    }

    // MARK: - user-set dates

    @Test
    func addNoteWithExplicitCreatedAtRoundTrips() throws {
        // The note's user-visible date is settable at add time (back- or
        // forward-dated); whole-second stamps round-trip ISO8601 exactly.
        let (sync, _) = makeOrchestrator()
        let pastDate = Date(timeIntervalSince1970: 1_000_000)
        let id = try sync.addNote(at: contactKey, body: "back-dated", createdAt: pastDate)
        let note = try #require(try sync.notes(at: contactKey).first)
        #expect(note.id == id)
        #expect(note.createdAt == pastDate)
        // The cell's modifiedAt stamp is the actual write time, not the
        // user-picked date.
        #expect(note.modifiedAt > pastDate)
    }

    @Test
    func addNoteWithExplicitCreatedAtSortsByThatDate() throws {
        // A back-dated note sorts BEFORE an earlier-written note whose
        // stamp is newer — ordering follows the user-visible date.
        let (sync, _) = makeOrchestrator()
        let now = try sync.addNote(at: contactKey, body: "written first")
        let backDated = try sync.addNote(
            at: contactKey,
            body: "written second, dated earlier",
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let notes = try sync.notes(at: contactKey)
        #expect(notes.map(\.id) == [backDated, now])
    }

    @Test
    func editNoteRestampsCreatedAt() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addNote(at: contactKey, body: "v1")
        let newDate = Date(timeIntervalSince1970: 2_000_000)
        try sync.editNote(at: contactKey, id: id, newBody: "v2", createdAt: newDate)
        let updated = try #require(try sync.notes(at: contactKey).first)
        #expect(updated.id == id)
        #expect(updated.body == "v2")
        #expect(updated.createdAt == newDate)
    }

    @Test
    func editNoteRestampReordersNotes() throws {
        let (sync, _) = makeOrchestrator()
        let a = try sync.addNote(at: contactKey, body: "A", createdAt: Date(timeIntervalSince1970: 1_000_000))
        let b = try sync.addNote(at: contactKey, body: "B", createdAt: Date(timeIntervalSince1970: 2_000_000))
        #expect(try sync.notes(at: contactKey).map(\.id) == [a, b])
        // Move A after B; the live list re-sorts by the new date.
        try sync.editNote(at: contactKey, id: a, newBody: "A", createdAt: Date(timeIntervalSince1970: 3_000_000))
        #expect(try sync.notes(at: contactKey).map(\.id) == [b, a])
    }

    // MARK: - edit

    @Test
    func editNoteUpdatesBodyPreservesCreatedAt() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addNote(at: contactKey, body: "v1")
        let original = try #require(try sync.notes(at: contactKey).first)
        Thread.sleep(forTimeInterval: 0.02)
        try sync.editNote(at: contactKey, id: id, newBody: "v2")
        let updated = try #require(try sync.notes(at: contactKey).first)
        #expect(updated.id == id)
        #expect(updated.body == "v2")
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.modifiedAt > original.modifiedAt)
    }

    @Test
    func editMissingNoteIsSilentNoOp() throws {
        let (sync, sidecars) = makeOrchestrator()
        try sync.editNote(at: contactKey, id: UUID(), newBody: "ghost")
        #expect(try sidecars.read(contactKey) == nil)
    }

    // MARK: - delete

    @Test
    func deleteNoteRemovesFromLiveList() throws {
        let (sync, _) = makeOrchestrator()
        let a = try sync.addNote(at: contactKey, body: "keep")
        Thread.sleep(forTimeInterval: 0.02)
        let b = try sync.addNote(at: contactKey, body: "drop")
        try sync.deleteNote(at: contactKey, id: b)
        let notes = try sync.notes(at: contactKey)
        #expect(notes.map(\.id) == [a])
    }

    @Test
    func deletedNotesAppearInAllNotes() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addNote(at: contactKey, body: "x")
        try sync.deleteNote(at: contactKey, id: id)
        let live = try sync.notes(at: contactKey)
        let all = try sync.allNotes(at: contactKey)
        #expect(live.isEmpty)
        #expect(all.count == 1)
        #expect(all[0].id == id)
        #expect(all[0].isDeleted)
        // Soft-delete preserves the body so the tombstone records what
        // was removed — useful for inspection / debugging.
        #expect(all[0].body == "x")
    }

    @Test
    func editAfterDeleteUndeletes() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addNote(at: contactKey, body: "v1")
        try sync.deleteNote(at: contactKey, id: id)
        try sync.editNote(at: contactKey, id: id, newBody: "v2")
        let notes = try sync.notes(at: contactKey)
        #expect(notes.count == 1)
        #expect(notes[0].body == "v2")
        #expect(notes[0].deletedAt == nil)
    }

    // MARK: - filtering

    @Test
    func notesIgnoresOtherFieldTypesOnSameEntity() throws {
        // A `.note`-typed cell whose `field` name is NOT contactNoteFieldName
        // (e.g. a future per-date note attached to an anniversary) and a
        // `.checkbox` cell should both be skipped by the typed notes view.
        let (sync, _) = makeOrchestrator()
        let userNote = try sync.addNote(at: contactKey, body: "user-typed")
        _ = try sync.addField(
            at: contactKey,
            field: "anniversary remark",
            type: .note,
            value: .string("ignored")
        )
        _ = try sync.addField(
            at: contactKey,
            field: "vip",
            type: .checkbox,
            value: .bool(true)
        )
        let notes = try sync.notes(at: contactKey)
        #expect(notes.count == 1)
        #expect(notes[0].id == userNote)
    }

    @Test
    func notesAtEmptyKeyReturnsEmpty() throws {
        let (sync, _) = makeOrchestrator()
        let notes = try sync.notes(at: contactKey)
        #expect(notes.isEmpty)
    }

    // MARK: - writer stamping

    @Test
    func addNoteStampsCallingDeviceID() throws {
        let (sync, _) = makeOrchestrator(deviceID: "device-XYZ")
        _ = try sync.addNote(at: contactKey, body: "hi")
        let n = try #require(try sync.notes(at: contactKey).first)
        #expect(n.modifiedBy == "device-XYZ")
    }

    @Test
    func editNoteStampsCurrentDeviceID() throws {
        // addField is stamped by whichever orchestrator wrote it; an edit
        // from a different orchestrator must bump modifiedBy to that
        // device. Same underlying sidecar store, different orchestrators.
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let writer = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")
        let editor = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-B")
        let id = try writer.addNote(at: contactKey, body: "v1")
        try editor.editNote(at: contactKey, id: id, newBody: "v2")
        let n = try #require(try editor.notes(at: contactKey).first)
        #expect(n.modifiedBy == "device-B")
    }
}
