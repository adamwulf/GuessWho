import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventNotesTags")
struct EventNotesTagsTests {
    private func makeOrchestrator(
        deviceID: String = "device-A"
    ) -> (GuessWhoSync, InMemorySidecarStore) {
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

    private let eventKey = SidecarKey(
        kind: .event,
        id: "11111111-1111-1111-1111-111111111111"
    )

    // MARK: - Tags

    @Test
    func tagsAtReturnsEventTagWithIdMatchingFieldInstance() throws {
        let (sync, _) = makeOrchestrator()
        let a = try sync.addTag(at: eventKey, text: "alpha")
        Thread.sleep(forTimeInterval: 0.02)
        let b = try sync.addTag(at: eventKey, text: "beta")
        Thread.sleep(forTimeInterval: 0.02)
        let c = try sync.addTag(at: eventKey, text: "gamma")

        let tags = try sync.tags(at: eventKey)
        #expect(tags.count == 3)
        #expect(tags.map(\.id) == [a, b, c])
        #expect(tags.map(\.text) == ["alpha", "beta", "gamma"])

        // edit
        try sync.editTag(at: eventKey, id: b, text: "BETA")
        let tags2 = try sync.tags(at: eventKey)
        #expect(tags2.first(where: { $0.id == b })?.text == "BETA")

        // delete
        try sync.deleteTag(at: eventKey, id: a)
        let tags3 = try sync.tags(at: eventKey)
        #expect(tags3.map(\.id) == [b, c])
    }

    @Test
    func tagsAndNotesDiscriminatedByFieldName() throws {
        let (sync, _) = makeOrchestrator()
        let noteID = try sync.addNote(at: eventKey, body: "this is a note")
        let tagID = try sync.addTag(at: eventKey, text: "important")

        let notes = try sync.notes(at: eventKey)
        #expect(notes.count == 1)
        #expect(notes[0].id == noteID)
        #expect(notes[0].body == "this is a note")

        let tags = try sync.tags(at: eventKey)
        #expect(tags.count == 1)
        #expect(tags[0].id == tagID)
        #expect(tags[0].text == "important")
    }

    @Test
    func noteWhoseBodyContainsWordTagIsStillANote() throws {
        let (sync, _) = makeOrchestrator()
        // Body content includes the word "tag" — discriminator is the
        // FIELD NAME, not the value's contents.
        _ = try sync.addNote(at: eventKey, body: "remember to tag this")
        let notes = try sync.notes(at: eventKey)
        let tags = try sync.tags(at: eventKey)
        #expect(notes.count == 1)
        #expect(tags.isEmpty)
        #expect(notes[0].body == "remember to tag this")
    }
}
