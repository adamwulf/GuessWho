import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Phase 2 exit criteria (plans/cli-mcp.md): the write tools, the consent
/// gate, the blast-radius bounds (budget, idempotency), the concurrency
/// guards (single-flight, post-mint verify, fingerprint), the custom-field
/// guardrails, event-tag Option B, and the audit trail.
final class WriteToolTests: XCTestCase {

    private func expectError(
        _ response: WireResponse, code: WireErrorCode,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let payload = response.errorPayload else {
            return XCTFail("expected \(code) error, got \(response)", file: file, line: line)
        }
        XCTAssertEqual(payload.code, code, file: file, line: line)
        XCTAssertFalse(payload.message.isEmpty, file: file, line: line)
    }

    /// A fixture with writes enabled (the shipping default is read-only;
    /// tests opt in the way the user's toggle would).
    private func writableFixture(
        writeLimitPerWindow: Int = 30, writeWindowSeconds: TimeInterval = 60
    ) async -> Fixture {
        let fixture = await Fixture.make(
            writeLimitPerWindow: writeLimitPerWindow,
            writeWindowSeconds: writeWindowSeconds)
        await MainActor.run {
            fixture.gates.isMCPReadOnly = false
            fixture.gates.isCLIReadOnly = false
        }
        return fixture
    }

    private func contactHandle(
        _ fixture: Fixture, query: String, name: String
    ) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: query, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.name == name })?.id
    }

    private func janeHandle(_ fixture: Fixture) async -> String? {
        await contactHandle(fixture, query: "jane", name: "Jane Doe")
    }

    // MARK: - Consent gate (writes rejected under read-only)

    func testWritesRejectedPerCallUnderReadOnlyAndHiddenFromListTools() async {
        let fixture = await Fixture.make() // read-only: the shipping default
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }

        // Hidden from listTools…
        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, _) = list else { return XCTFail("expected toolList") }
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(MCPTool.contactsSearch.rawValue), "reads stay visible")
        XCTAssertFalse(names.contains(MCPTool.contactsAddNote.rawValue), "writes hidden under read-only")

        // …AND rejected per-call server-side (hiding is UX, not the gate).
        let write = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "m2",
            contactId: jane, body: "should not land", idempotencyToken: nil))
        expectError(write, code: .readOnly)
        let notes = await MainActor.run {
            fixture.contacts.notesByEffectiveID[Sentinels.guessWhoUUID] ?? []
        }
        XCTAssertFalse(notes.contains { $0.body == "should not land" })
    }

    func testWriteToolsListedOnceReadOnlyIsOff() async {
        let fixture = await writableFixture()
        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, _) = list else { return XCTFail("expected toolList") }
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(MCPTool.contactsAddNote.rawValue))
        XCTAssertTrue(names.contains(MCPTool.eventsAddTag.rawValue))
        XCTAssertTrue(names.contains(MCPTool.guidesCreate.rawValue))
    }

    // MARK: - Note writes + echo

    func testAddEditDeleteNoteRoundTrip() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }

        let added = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, body: "Prefers oat milk", idempotencyToken: nil))
        guard case .note(_, _, let note) = added else {
            return XCTFail("expected note echo, got \(added)")
        }
        XCTAssertEqual(note.body, "Prefers oat milk")

        let edited = await fixture.dispatcher.handle(.contactsEditNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, noteId: note.id, body: "Prefers oat milk, no sugar",
            idempotencyToken: nil))
        guard case .note(_, _, let editedNote) = edited else {
            return XCTFail("expected note echo, got \(edited)")
        }
        XCTAssertEqual(editedNote.body, "Prefers oat milk, no sugar")
        XCTAssertEqual(editedNote.id, note.id, "an edit keeps the note's id")

        let deleted = await fixture.dispatcher.handle(.contactsDeleteNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, noteId: note.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = deleted else {
            return XCTFail("expected acknowledgement, got \(deleted)")
        }
        XCTAssertEqual(message, WireAckMessage.noteDeleted)

        // Soft-delete only: the record remains as a tombstone.
        let tombstones = await MainActor.run {
            (fixture.contacts.notesByEffectiveID[Sentinels.guessWhoUUID] ?? [])
                .filter { $0.body == "Prefers oat milk, no sugar" }
        }
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertNotNil(tombstones.first?.deletedAt, "delete must tombstone, not remove")
    }

    func testEditUnknownNoteIsNotFound() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }
        // A handle of the wrong kind is rejected as stale before any write.
        let response = await fixture.dispatcher.handle(.contactsEditNote(
            helperId: Fixture.helper, messageId: "m",
            contactId: jane, noteId: "not-minted", body: "x", idempotencyToken: nil))
        expectError(response, code: .staleHandle)
    }

    // MARK: - Custom-field guardrails

    func testBlobTypedCustomFieldWriteRejected() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }
        let response = await fixture.dispatcher.handle(.contactsSetCustomField(
            helperId: Fixture.helper, messageId: "m",
            contactId: jane, name: "Sneaky", type: "blob",
            value: "blob:sha256/feedface", idempotencyToken: nil))
        expectError(response, code: .invalidParams)
        XCTAssertEqual(response.errorPayload?.message, WireErrorMessage.invalidFieldType)
        let fields = await MainActor.run {
            fixture.contacts.fieldsByEffectiveID[Sentinels.guessWhoUUID] ?? []
        }
        XCTAssertFalse(fields.contains { $0.field == "Sneaky" })
    }

    func testReservedFieldNamesRejected() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }
        // previousPhoto would clobber the photo-restore snapshot via the
        // type-replace upsert; "note" would overwrite a user note in place.
        for name in ["previousPhoto", "PreviousPhoto", "note", "Note", "tag"] {
            let response = await fixture.dispatcher.handle(.contactsSetCustomField(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                contactId: jane, name: name, type: nil,
                value: "clobber", idempotencyToken: nil))
            expectError(response, code: .invalidParams)
            XCTAssertEqual(response.errorPayload?.message, WireErrorMessage.reservedFieldName)
        }
        let fields = await MainActor.run {
            fixture.contacts.fieldsByEffectiveID[Sentinels.guessWhoUUID] ?? []
        }
        // The snapshot blob is untouched, and no user note was replaced.
        XCTAssertTrue(fields.contains { $0.field == "previousPhoto" && $0.type == .blob })
        XCTAssertFalse(fields.contains { value in
            if case .string(let string) = value.value { return string == "clobber" }
            return false
        })
    }

    func testCheckboxAndDateFieldsValidateAndNormalize() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }

        let checkbox = await fixture.dispatcher.handle(.contactsSetCustomField(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, name: "Newsletter", type: "checkbox",
            value: "true", idempotencyToken: nil))
        guard case .customField(_, _, let checkboxField) = checkbox else {
            return XCTFail("expected field echo, got \(checkbox)")
        }
        XCTAssertEqual(checkboxField.type, "checkbox")
        XCTAssertEqual(checkboxField.value, "true")

        let badCheckbox = await fixture.dispatcher.handle(.contactsSetCustomField(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, name: "Newsletter2", type: "checkbox",
            value: "yes please", idempotencyToken: nil))
        expectError(badCheckbox, code: .invalidParams)

        let date = await fixture.dispatcher.handle(.contactsSetCustomField(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, name: "Next check-in", type: "date",
            value: "2026-08-01", idempotencyToken: nil))
        guard case .customField(_, _, let dateField) = date else {
            return XCTFail("expected field echo, got \(date)")
        }
        XCTAssertEqual(dateField.type, "date")
        XCTAssertEqual(dateField.value, "2026-08-01T00:00:00Z", "date values normalize to internet date-time")

        let badDate = await fixture.dispatcher.handle(.contactsSetCustomField(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, name: "Next check-in 2", type: "date",
            value: "whenever", idempotencyToken: nil))
        expectError(badDate, code: .invalidParams)
    }

    // MARK: - Event-tag Option B

    func testTagWriteOnUnadoptedEventReturnsTypedErrorAndMintsNothing() async {
        let fixture = await writableFixture()
        let list = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: "m",
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = list,
              let dentist = page.items.first(where: { $0.title == "Dentist" })
        else { return XCTFail("expected the system-only event") }

        let response = await fixture.dispatcher.handle(.eventsAddTag(
            helperId: Fixture.helper, messageId: "m2",
            eventId: dentist.id, text: "checkup", idempotencyToken: nil))
        expectError(response, code: .requiresAppAction)
        XCTAssertEqual(response.errorPayload?.message, WireErrorMessage.eventNeedsAppFirst)

        // Writes-do-not-adopt: no record was created and the engine's tag
        // write path was never reached.
        let (recordCount, tagWrites) = await MainActor.run {
            (fixture.events.events.count, fixture.events.tagWriteEventUUIDs)
        }
        XCTAssertEqual(recordCount, 1, "no new event record may appear")
        XCTAssertTrue(tagWrites.isEmpty, "the tag write path must not be reached")
    }

    func testTagRoundTripOnAdoptedEvent() async {
        let fixture = await writableFixture()
        let list = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: "m",
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = list,
              let gala = page.items.first(where: { $0.title == "Museum Gala" })
        else { return XCTFail("expected the gala") }

        let added = await fixture.dispatcher.handle(.eventsAddTag(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            eventId: gala.id, text: "black-tie", idempotencyToken: nil))
        guard case .tag(_, _, let tag) = added else {
            return XCTFail("expected tag echo, got \(added)")
        }
        XCTAssertEqual(tag.text, "black-tie")

        let edited = await fixture.dispatcher.handle(.eventsEditTag(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            eventId: gala.id, tagId: tag.id, text: "cocktail", idempotencyToken: nil))
        guard case .tag(_, _, let editedTag) = edited else {
            return XCTFail("expected tag echo, got \(edited)")
        }
        XCTAssertEqual(editedTag.text, "cocktail")

        let deleted = await fixture.dispatcher.handle(.eventsDeleteTag(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            eventId: gala.id, tagId: tag.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = deleted else {
            return XCTFail("expected acknowledgement, got \(deleted)")
        }
        XCTAssertEqual(message, WireAckMessage.tagDeleted)
    }

    // MARK: - Contact double-mint (single-flight + post-mint verify)

    func testConcurrentFirstWritesToNeverReconciledContactDontStrandAWrite() async {
        let fixture = await writableFixture()
        guard let fresh = await contactHandle(fixture, query: "fresh", name: "Fresh Face") else {
            return XCTFail("no fresh contact")
        }

        async let first = fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "race-1",
            contactId: fresh, body: "first writer", idempotencyToken: nil))
        async let second = fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "race-2",
            contactId: fresh, body: "second writer", idempotencyToken: nil))
        let (r1, r2) = await (first, second)
        XCTAssertNil(r1.errorPayload, "first write should succeed")
        XCTAssertNil(r2.errorPayload, "second write should succeed")

        let (mintCount, bodies) = await MainActor.run { () -> (Int, [String]) in
            let identity = fixture.contacts.contacts
                .first { $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88" }?
                .contactID.restorationToken.guessWhoID
            let notes = identity.flatMap { fixture.contacts.notesByEffectiveID[$0] } ?? []
            return (fixture.contacts.mintCount, notes.map(\.body))
        }
        XCTAssertEqual(mintCount, 1, "the single-flight must serialize the two first-writers onto ONE mint")
        XCTAssertEqual(Set(bodies), ["first writer", "second writer"],
                       "both writes must land under the card's one identity — no stranded write")
    }

    func testPostMintVerifyRetriesWhenAConcurrentMintWins() async {
        let fixture = await writableFixture()
        guard let fresh = await contactHandle(fixture, query: "fresh", name: "Fresh Face") else {
            return XCTFail("no fresh contact")
        }
        // The next mint loses: its data lands under its own UUID while the
        // card gets a different writer's identity (agent-vs-UI, which the
        // single-flight cannot serialize).
        await MainActor.run { fixture.contacts.simulateLosingMintOnce = true }

        let response = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "verify-1",
            contactId: fresh, body: "must not strand", idempotencyToken: nil))
        XCTAssertNil(response.errorPayload, "the verify+retry should heal the losing mint")

        let bodies = await MainActor.run { () -> [String] in
            let identity = fixture.contacts.contacts
                .first { $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88" }?
                .contactID.restorationToken.guessWhoID
            let notes = identity.flatMap { fixture.contacts.notesByEffectiveID[$0] } ?? []
            return notes.map(\.body)
        }
        XCTAssertTrue(bodies.contains("must not strand"),
                      "the note must be reachable under the card's CANONICAL identity")
    }

    // MARK: - Nil-identity fingerprint guard

    func testWriteBlockedWhenNilIdentityContactWasRepointed() async {
        let fixture = await writableFixture()
        guard let fresh = await contactHandle(fixture, query: "fresh", name: "Fresh Face") else {
            return XCTFail("no fresh contact")
        }
        // Mid-conversation, system unification re-points the local id at a
        // DIFFERENT person (simulated by the display name changing).
        await MainActor.run {
            guard let index = fixture.contacts.contacts.firstIndex(where: {
                $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88"
            }) else { return }
            var repointed = fixture.contacts.contacts[index]
            repointed.givenName = "Somebody"
            repointed.familyName = "Else"
            fixture.contacts.contacts[index] = repointed
        }
        let response = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "m",
            contactId: fresh, body: "wrong person", idempotencyToken: nil))
        expectError(response, code: .staleHandle)
        let allBodies = await MainActor.run {
            fixture.contacts.notesByEffectiveID.values.flatMap { $0 }.map(\.body)
        }
        XCTAssertFalse(allBodies.contains("wrong person"), "the write must not land on the re-pointed card")
    }

    // MARK: - Idempotency

    func testRetriedWriteWithSameTokenDoesNotDuplicate() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }

        let first = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "idem-1",
            contactId: jane, body: "only once", idempotencyToken: "tok-alpha"))
        guard case .note(_, _, let firstNote) = first else {
            return XCTFail("expected note echo, got \(first)")
        }
        let retry = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "idem-2",
            contactId: jane, body: "only once", idempotencyToken: "tok-alpha"))
        guard case .note(_, _, let retryNote) = retry else {
            return XCTFail("expected the replayed note echo, got \(retry)")
        }
        XCTAssertEqual(retryNote.id, firstNote.id, "the replay must return the ORIGINAL result")
        XCTAssertEqual(retry.messageId, "idem-2", "the replay must be re-addressed to the retry's message id")

        let count = await MainActor.run {
            (fixture.contacts.notesByEffectiveID[Sentinels.guessWhoUUID] ?? [])
                .filter { $0.body == "only once" }.count
        }
        XCTAssertEqual(count, 1, "a retried token must not create a duplicate")
    }

    // MARK: - Write budget

    func testWriteBudgetIsGlobalPerHostRunEvenAcrossHelperReconnect() async {
        let fixture = await writableFixture(writeLimitPerWindow: 2, writeWindowSeconds: 60)
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }

        for index in 0..<2 {
            let response = await fixture.dispatcher.handle(.contactsAddNote(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                contactId: jane, body: "budget \(index)", idempotencyToken: nil))
            XCTAssertNil(response.errorPayload, "write \(index) should pass")
        }
        // A "reconnected" helper (fresh random id) must NOT reset the
        // budget — it is keyed per host run, never per helper.
        let reconnected = RequestOrigin.mcp.makeHelperId()
        let flooded = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: reconnected, messageId: TestMessageID.next(),
            contactId: jane, body: "budget 3", idempotencyToken: nil))
        expectError(flooded, code: .busy)
        XCTAssertEqual(flooded.errorPayload?.message, WireErrorMessage.writeBusy)
    }

    // MARK: - Audit log

    func testAgentWriteAppearsInAuditLogWithDurableReferent() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture) else { return XCTFail("no jane") }

        let added = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, body: "for the record", idempotencyToken: nil))
        XCTAssertNil(added.errorPayload)

        let entries = await fixture.audit.entries()
        guard let entry = entries.last else { return XCTFail("expected an audit entry") }
        XCTAssertEqual(entry.action, .addNote)
        XCTAssertEqual(entry.subjectKind, .contact)
        XCTAssertEqual(entry.subjectID, Sentinels.guessWhoUUID, "the durable referent, not a wire id")
        XCTAssertEqual(entry.subjectName, "Jane Doe")
        XCTAssertNotNil(entry.instanceID)
        XCTAssertNotNil(entry.postModifiedAt)
        XCTAssertEqual(entry.newValue, "for the record")

        // The audited referent must never appear in the wire output.
        XCTAssertFalse(added.wireJSON.contains(Sentinels.guessWhoUUID))
        if let instanceID = entry.instanceID {
            XCTAssertFalse(added.wireJSON.lowercased().contains(instanceID.lowercased()),
                           "the raw instance UUID must not cross the wire")
        }
    }

    // MARK: - Linked contacts / favorites / guides

    func testAddLinkedContactEnforcesKindAndEchoesRow() async {
        let fixture = await writableFixture()
        guard let jane = await janeHandle(fixture),
              let fresh = await contactHandle(fixture, query: "fresh", name: "Fresh Face"),
              let organization = await contactHandle(fixture, query: "doe", name: "Doe Industries")
        else { return XCTFail("missing fixtures") }

        // Wrong kind → pointed to the right tool.
        let wrongKind = await fixture.dispatcher.handle(.contactsAddLinkedContact(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, personId: organization, note: nil, idempotencyToken: nil))
        expectError(wrongKind, code: .invalidParams)

        let added = await fixture.dispatcher.handle(.contactsAddLinkedContact(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, personId: fresh, note: "Old colleague", idempotencyToken: nil))
        guard case .linkedContact(_, _, let row) = added else {
            return XCTFail("expected linked-contact echo, got \(added)")
        }
        XCTAssertEqual(row.kind, "person")
        XCTAssertEqual(row.note, "Old colleague")
        XCTAssertEqual(row.contact.name, "Fresh Face")

        let removed = await fixture.dispatcher.handle(.contactsRemoveLinkedContact(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            linkId: row.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = removed else {
            return XCTFail("expected acknowledgement, got \(removed)")
        }
        XCTAssertEqual(message, WireAckMessage.linkRemoved)
    }

    func testSetFavoriteIsIdempotentAndMintsNothingOnClearOfUntouchedContact() async {
        let fixture = await writableFixture()
        guard let fresh = await contactHandle(fixture, query: "fresh", name: "Fresh Face") else {
            return XCTFail("no fresh contact")
        }
        // Clearing the favorite of a never-touched contact is a no-op and
        // must not mint an identity.
        let cleared = await fixture.dispatcher.handle(.contactsSetFavorite(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: fresh, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = cleared else { return XCTFail("expected acknowledgement") }
        let mintsAfterClear = await MainActor.run { fixture.contacts.mintCount }
        XCTAssertEqual(mintsAfterClear, 0, "a no-op favorite clear must not mint")

        let set = await fixture.dispatcher.handle(.contactsSetFavorite(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: fresh, favorite: true, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = set else {
            return XCTFail("expected acknowledgement")
        }
        XCTAssertEqual(message, WireAckMessage.favoriteSet)
        let favorite = await MainActor.run { () -> Bool in
            guard let contact = fixture.contacts.contacts.first(where: {
                $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88"
            }) else { return false }
            return fixture.contacts.isFavorite(contact.contactID)
        }
        XCTAssertTrue(favorite)
    }

    func testGuideCreateReorderDelete() async {
        let fixture = await writableFixture()
        let created = await fixture.dispatcher.handle(.guidesCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            name: "Taco Tour",
            places: [
                WireNewPlace(address: "1 Salsa Way", latitude: nil, longitude: nil),
                WireNewPlace(address: "2 Guac Blvd", latitude: 30.1, longitude: -97.7),
            ],
            idempotencyToken: nil))
        guard case .guide(_, _, let guide) = created else {
            return XCTFail("expected guide echo, got \(created)")
        }
        XCTAssertEqual(guide.name, "Taco Tour")

        let placesResponse = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            guideId: guide.id, limit: nil, cursor: nil))
        guard case .placePage(_, _, let page) = placesResponse, page.items.count == 2 else {
            return XCTFail("expected the guide's two places")
        }
        let reversed = page.items.map(\.id).reversed().map { $0 }
        let reorder = await fixture.dispatcher.handle(.guidesReorderPlaces(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            guideId: guide.id, placeIds: reversed, idempotencyToken: nil))
        guard case .acknowledged(_, _, let reorderMessage) = reorder else {
            return XCTFail("expected acknowledgement, got \(reorder)")
        }
        XCTAssertEqual(reorderMessage, WireAckMessage.placesReordered)

        let deletePlace = await fixture.dispatcher.handle(.placesDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            placeId: page.items[0].id, idempotencyToken: nil))
        guard case .acknowledged = deletePlace else {
            return XCTFail("expected acknowledgement, got \(deletePlace)")
        }

        let deleteGuide = await fixture.dispatcher.handle(.guidesDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            guideId: guide.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let deleteMessage) = deleteGuide else {
            return XCTFail("expected acknowledgement, got \(deleteGuide)")
        }
        XCTAssertEqual(deleteMessage, WireAckMessage.guideDeleted)
    }
}
