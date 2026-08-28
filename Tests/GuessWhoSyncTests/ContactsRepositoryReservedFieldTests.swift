import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Reserved-name fields must never surface through `fields(for:)`, the
/// accessor that drives the user-facing custom-fields list (the app UI and the
/// CLI/MCP `list-custom-fields` surface both). A user note and an event tag are
/// physically `.note`-typed cells named `contactNoteFieldName` ("note") /
/// `eventTagFieldName` — they share the field store but are their own concept,
/// read through `notes(for:)` and the tag accessors. Surfacing them as custom
/// fields showed a dated note a SECOND time (same UUID) as a "note" custom
/// field, and read as duplication. This is the read-side mirror of the
/// write-side reserved-name rejection in `set-custom-field`: 'note' is not a
/// user custom field on read either.
@Suite("ContactsRepository reserved-field filtering")
struct ContactsRepositoryReservedFieldTests {
    private func makeSync(contacts: InMemoryContactStore, sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }

    @Test @MainActor
    func noteFieldIsHiddenFromUserVisibleCustomFields() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada")
        let contactStore = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        // A dated note and a genuine user custom field on the same contact.
        let noteID = try await repository.addNote(for: id, body: "coffee at 3pm")
        _ = try await repository.upsertField(
            for: id, field: "Coffee order", value: "oat latte", type: .note)

        // A sidecar write may have minted the GuessWho UUID; re-resolve the id.
        let freshID = try #require(repository.contact(localID: "ada")).contactID

        // The note is a note — read through the notes API by its UUID.
        let notes = repository.notes(for: freshID)
        #expect(notes.contains { $0.id == noteID && $0.body == "coffee at 3pm" })

        // The note is NOT also a custom field: neither by its UUID nor by the
        // reserved "note" name. The genuine user field still shows.
        let fields = repository.fields(for: freshID)
        #expect(fields.contains { $0.field == "Coffee order" && $0.type == .note })
        #expect(!fields.contains { $0.id == noteID })
        #expect(!fields.contains { $0.field == GuessWhoSync.contactNoteFieldName })
    }

    @Test @MainActor
    func deletingTheNoteLeavesTheGenuineCustomFieldIntact() async throws {
        // Guards the flip side of the shared store: because the note never
        // appeared as a custom field, deleting it touches only the note — the
        // real custom field the user added stays put.
        let contact = Contact(localID: "ada", givenName: "Ada")
        let contactStore = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        let noteID = try await repository.addNote(for: id, body: "temporary")
        _ = try await repository.upsertField(
            for: id, field: "Coffee order", value: "oat latte", type: .note)

        var freshID = try #require(repository.contact(localID: "ada")).contactID
        try await repository.deleteNote(for: freshID, id: noteID)
        freshID = try #require(repository.contact(localID: "ada")).contactID

        #expect(repository.notes(for: freshID).isEmpty)
        let fields = repository.fields(for: freshID)
        #expect(fields.contains { $0.field == "Coffee order" })
    }
}
