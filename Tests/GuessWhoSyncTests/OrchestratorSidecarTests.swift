import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("OrchestratorSidecar")
struct OrchestratorSidecarTests {
    private let deviceID = "device-A"

    private func makeSync(
        events: InMemoryEventStore = InMemoryEventStore(),
        sidecars: InMemorySidecarStore = InMemorySidecarStore()
    ) -> (GuessWhoSync, InMemoryEventStore, InMemorySidecarStore) {
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: events,
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, events, sidecars)
    }

    private func makeEvent(eventKitID: String = "EVT-1") -> Event {
        Event(
            id: UUID(),
            eventKitID: eventKitID,
            title: "WWDC Keynote",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_007_200),
            isAllDay: false,
            location: "Apple Park",
            eventKitNotes: "Original notes"
        )
    }

    // MARK: - §9.7 Event sidecars

    @Test
    func eventLookupByEventKitID() throws {
        let event = makeEvent()
        let events = InMemoryEventStore(events: [event])
        let fetched = try events.fetch(eventKitID: event.eventKitID!)
        #expect(fetched == event)
    }

    @Test
    func writingSidecarForEventDoesNotMutateTheEvent() throws {
        let event = makeEvent()
        let events = InMemoryEventStore(events: [event])
        let (sync, _, sidecars) = makeSync(events: events)

        let key = SidecarKey.forEvent(event)
        let id = try sync.addField(at: key, field: "notes", type: .note, value: .string("hello"))

        let after = try #require(try events.fetch(eventKitID: event.eventKitID!))
        #expect(after == event)

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.entityID == event.id.uuidString.lowercased())
        let cell = try #require(envelope.fields[id.uuidString])
        #expect(cell.modifiedBy == deviceID)
        #expect(cell.deletedAt == nil)

        let field = try #require(try sync.field(at: key, id: id))
        #expect(field.field == "notes")
        #expect(field.type == .note)
        #expect(field.value == .string("hello"))
    }

    @Test
    func perFieldInstancesAreIndependentOnEventSidecars() throws {
        let event = makeEvent()
        let events = InMemoryEventStore(events: [event])
        let (sync, _, sidecars) = makeSync(events: events)
        let key = SidecarKey.forEvent(event)

        let firstID = try sync.addField(at: key, field: "notes", type: .note, value: .string("first"))
        let firstModifiedAt = try #require(try sync.field(at: key, id: firstID)).modifiedAt

        try sync.setField(at: key, id: firstID, field: "notes", value: .string("second"))
        let updated = try #require(try sync.field(at: key, id: firstID))
        #expect(updated.value == .string("second"))
        #expect(updated.modifiedBy == deviceID)
        #expect(updated.modifiedAt >= firstModifiedAt)
        #expect(updated.deletedAt == nil)

        let attendeesID = try sync.addField(at: key, field: "attendees", type: .checkbox, value: .bool(true))
        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.keys.sorted() == [attendeesID.uuidString, firstID.uuidString].sorted())

        let notesField = try #require(try sync.field(at: key, id: firstID))
        #expect(notesField.value == .string("second"))

        let attendeesField = try #require(try sync.field(at: key, id: attendeesID))
        #expect(attendeesField.value == .bool(true))
        #expect(attendeesField.type == .checkbox)
    }

    // MARK: - Field-instance API (§7.3)

    @Test
    func addFieldCreatesSidecarIfNoneExists() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440000")

        #expect(try sidecars.read(key) == nil)
        let id = try sync.addField(at: key, field: "nickname", type: .note, value: .string("Bear"))

        let envelope = try #require(try sync.sidecar(at: key))
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.entityID == key.id)
        #expect(envelope.fields.count == 1)
        let cell = try #require(envelope.fields[id.uuidString])
        #expect(cell.modifiedBy == deviceID)
        #expect(cell.deletedAt == nil)
        #expect(abs(cell.modifiedAt.timeIntervalSinceNow) < 1.0)

        let field = try #require(try sync.field(at: key, id: id))
        #expect(field.field == "nickname")
        #expect(field.type == .note)
        #expect(field.value == .string("Bear"))
    }

    @Test
    func setFieldUpdatesExistingCell() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440001")

        let id = try sync.addField(at: key, field: "nickname", type: .note, value: .string("Bear"))
        try sync.setField(at: key, id: id, field: "nickname", value: .string("Honey"))

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == 1)
        let cell = try #require(envelope.fields[id.uuidString])
        #expect(cell.modifiedBy == deviceID)
        #expect(cell.deletedAt == nil)
        #expect(abs(cell.modifiedAt.timeIntervalSinceNow) < 1.0)

        let field = try #require(try sync.field(at: key, id: id))
        #expect(field.value == .string("Honey"))
        #expect(field.type == .note)
    }

    @Test
    func deleteFieldSetsDeletedAtAndPreservesOthers() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440002")

        let nickID = try sync.addField(at: key, field: "nickname", type: .note, value: .string("Bear"))
        let notesID = try sync.addField(at: key, field: "notes", type: .note, value: .string("met at WWDC"))
        try sync.deleteField(at: key, id: nickID)

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.keys.sorted() == [nickID.uuidString, notesID.uuidString].sorted())

        let nickCell = try #require(envelope.fields[nickID.uuidString])
        #expect(nickCell.modifiedBy == deviceID)
        #expect(nickCell.deletedAt != nil)
        #expect(abs(nickCell.modifiedAt.timeIntervalSinceNow) < 1.0)
        // The inner value object is preserved on soft delete.
        #expect(SidecarField.type(of: nickCell) == .note)

        let notesCell = try #require(envelope.fields[notesID.uuidString])
        #expect(notesCell.deletedAt == nil)
        let notesField = try #require(try sync.field(at: key, id: notesID))
        #expect(notesField.value == .string("met at WWDC"))
    }

    @Test
    func deleteFieldOnMissingCellIsNoOp() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440003")

        #expect(try sidecars.read(key) == nil)
        try sync.deleteField(at: key, id: UUID())

        #expect(try sidecars.read(key) == nil)
    }

    @Test
    func addFieldThrowsOnTypeValueMismatch() throws {
        let (sync, _, _) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440004")

        #expect(throws: SidecarStoreError.self) {
            try sync.addField(at: key, field: "flag", type: .checkbox, value: .string("not a bool"))
        }
    }

    @Test
    func setFieldRevivesSoftDeletedCell() throws {
        let (sync, _, _) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440005")

        let id = try sync.addField(at: key, field: "nickname", type: .note, value: .string("Bear"))
        try sync.deleteField(at: key, id: id)
        let deleted = try #require(try sync.field(at: key, id: id))
        #expect(deleted.deletedAt != nil)

        try sync.setField(at: key, id: id, field: "nickname", value: .string("Bear-cub"))
        let revived = try #require(try sync.field(at: key, id: id))
        #expect(revived.deletedAt == nil)
        #expect(revived.value == .string("Bear-cub"))
    }

    @Test
    func fieldsReturnsEveryDecodedField() throws {
        let (sync, _, _) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440006")

        let aID = try sync.addField(at: key, field: "nickname", type: .note, value: .string("Bear"))
        let bID = try sync.addField(at: key, field: "birthday", type: .date, value: .string("2026-01-01T00:00:00Z"))

        let all = try sync.fields(at: key)
        let ids = Set(all.map(\.id))
        #expect(ids == [aID, bID])
    }
}
