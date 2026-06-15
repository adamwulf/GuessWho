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

    private func makeEvent(externalID: String = "EVT-1") -> Event {
        Event(
            externalID: externalID,
            title: "WWDC Keynote",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_007_200),
            isAllDay: false,
            location: "Apple Park",
            notes: "Original notes"
        )
    }

    // MARK: - §9.7 Event sidecars

    @Test
    func eventLookupByExternalID() throws {
        let event = makeEvent()
        let events = InMemoryEventStore(events: [event])
        let fetched = try events.fetch(externalID: event.externalID)
        #expect(fetched == event)
    }

    @Test
    func writingSidecarForEventDoesNotMutateTheEvent() throws {
        let event = makeEvent()
        let events = InMemoryEventStore(events: [event])
        let (sync, _, sidecars) = makeSync(events: events)

        let key = SidecarKey.forEvent(event)
        try sync.setField("notes", value: .string("hello"), at: key)

        let after = try #require(try events.fetch(externalID: event.externalID))
        #expect(after == event)

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.entityID == event.externalID)
        switch envelope.fields["notes"] {
        case let .value(v, _, modifiedBy):
            #expect(v == .string("hello"))
            #expect(modifiedBy == deviceID)
        default:
            Issue.record("expected value cell for notes")
        }
    }

    @Test
    func perFieldLWWAppliesToEventSidecars() throws {
        let event = makeEvent()
        let events = InMemoryEventStore(events: [event])
        let (sync, _, sidecars) = makeSync(events: events)
        let key = SidecarKey.forEvent(event)

        try sync.setField("notes", value: .string("first"), at: key)
        let firstModifiedAt: Date
        switch try #require(try sidecars.read(key)).fields["notes"] {
        case let .value(_, modifiedAt, _):
            firstModifiedAt = modifiedAt
        default:
            firstModifiedAt = .distantPast
            Issue.record("expected value cell")
        }

        try sync.setField("notes", value: .string("second"), at: key)
        switch try #require(try sidecars.read(key)).fields["notes"] {
        case let .value(v, modifiedAt, modifiedBy):
            #expect(v == .string("second"))
            #expect(modifiedBy == deviceID)
            #expect(modifiedAt >= firstModifiedAt)
        default:
            Issue.record("expected value cell")
        }

        try sync.setField("attendees", value: .number(3), at: key)
        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.keys.sorted() == ["attendees", "notes"])
        switch envelope.fields["notes"] {
        case let .value(v, _, _):
            #expect(v == .string("second"))
        default:
            Issue.record("expected notes value cell to coexist with attendees")
        }
        switch envelope.fields["attendees"] {
        case let .value(v, _, _):
            #expect(v == .number(3))
        default:
            Issue.record("expected attendees value cell")
        }
    }

    // MARK: - Orchestrator setField / deleteField

    @Test
    func setFieldCreatesSidecarIfNoneExists() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440000")

        #expect(try sidecars.read(key) == nil)
        try sync.setField("nickname", value: .string("Bear"), at: key)

        let envelope = try #require(try sync.sidecar(at: key))
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.entityID == key.id)
        #expect(envelope.fields.count == 1)
        switch envelope.fields["nickname"] {
        case let .value(v, modifiedAt, modifiedBy):
            #expect(v == .string("Bear"))
            #expect(modifiedBy == deviceID)
            #expect(abs(modifiedAt.timeIntervalSinceNow) < 1.0)
        default:
            Issue.record("expected value cell for nickname")
        }
    }

    @Test
    func setFieldOverwritesExistingCell() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440001")

        try sync.setField("nickname", value: .string("Bear"), at: key)
        try sync.setField("nickname", value: .string("Honey"), at: key)

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == 1)
        switch envelope.fields["nickname"] {
        case let .value(v, modifiedAt, modifiedBy):
            #expect(v == .string("Honey"))
            #expect(modifiedBy == deviceID)
            #expect(abs(modifiedAt.timeIntervalSinceNow) < 1.0)
        default:
            Issue.record("expected value cell after overwrite")
        }
    }

    @Test
    func deleteFieldWritesTombstoneAndPreservesOthers() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440002")

        try sync.setField("nickname", value: .string("Bear"), at: key)
        try sync.setField("notes", value: .string("met at WWDC"), at: key)
        try sync.deleteField("nickname", at: key)

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.keys.sorted() == ["nickname", "notes"])
        switch envelope.fields["nickname"] {
        case let .tombstone(modifiedAt, modifiedBy):
            #expect(modifiedBy == deviceID)
            #expect(abs(modifiedAt.timeIntervalSinceNow) < 1.0)
        default:
            Issue.record("expected tombstone cell for nickname")
        }
        switch envelope.fields["notes"] {
        case let .value(v, _, _):
            #expect(v == .string("met at WWDC"))
        default:
            Issue.record("expected notes value cell to remain")
        }
    }

    @Test
    func deleteFieldOnFreshSidecarCreatesTombstoneOnlyEnvelope() throws {
        let (sync, _, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440003")

        #expect(try sidecars.read(key) == nil)
        try sync.deleteField("nickname", at: key)

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.entityID == key.id)
        #expect(envelope.fields.count == 1)
        switch envelope.fields["nickname"] {
        case let .tombstone(modifiedAt, modifiedBy):
            #expect(modifiedBy == deviceID)
            #expect(abs(modifiedAt.timeIntervalSinceNow) < 1.0)
        default:
            Issue.record("expected tombstone-only envelope")
        }
    }
}
