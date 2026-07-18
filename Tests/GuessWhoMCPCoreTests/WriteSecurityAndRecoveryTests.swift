import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// INV-3's write-direction + write-echo legs (plans/cli-mcp.md Phase 2):
/// no write tool can touch the Apple contact note, and no write-echo
/// response leaks the sentinels or any sealed identifier.
final class WriteEchoSecurityTests: XCTestCase {

    private func writableFixture() async -> Fixture {
        // A raised write budget: the sweep exercises EVERY write tool in
        // one window, and a budget rejection would silently skip a tool's
        // echo from the scan.
        let fixture = await Fixture.make(writeLimitPerWindow: 200)
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        return fixture
    }

    /// Every write tool exercised against the fixture — success paths and
    /// error paths both, since errors are output too.
    private func allWriteOutputs(_ fixture: Fixture) async -> [WireResponse] {
        let dispatcher = fixture.dispatcher
        let helper = Fixture.helper
        var responses: [WireResponse] = []

        func run(_ request: WireRequest) async -> WireResponse {
            guard let response = await dispatcher.handle(request) else {
                XCTFail("expected an immediate response for \(request)")
                return .error(
                    helperId: helper, messageId: "missing",
                    code: .invalidParams, message: "missing")
            }
            responses.append(response)
            return response
        }
        func contactHandle(query: String, name: String) async -> String? {
            let response = await run(.contactsSearch(
                helperId: helper, messageId: TestMessageID.next(),
                query: query, limit: nil, cursor: nil))
            guard case .contactPage(_, _, let page) = response else { return nil }
            return page.items.first(where: { $0.name == name })?.id
        }

        guard let jane = await contactHandle(query: "jane", name: "Jane Doe"),
              let fresh = await contactHandle(query: "fresh", name: "Fresh Face"),
              let organization = await contactHandle(query: "doe", name: "Doe Industries")
        else {
            XCTFail("missing contact fixtures")
            return responses
        }

        let added = await run(.contactsAddNote(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, body: "write echo body", idempotencyToken: nil))
        if case .note(_, _, let note) = added {
            _ = await run(.contactsEditNote(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: jane, noteId: note.id, body: "write echo body 2", idempotencyToken: nil))
            _ = await run(.contactsDeleteNote(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: jane, noteId: note.id, idempotencyToken: nil))
        }

        let fieldSet = await run(.contactsSetCustomField(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, name: "Echo field", type: nil, value: "echo value",
            idempotencyToken: nil))
        if case .customField(_, _, let field) = fieldSet {
            _ = await run(.contactsDeleteCustomField(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: jane, fieldId: field.id, idempotencyToken: nil))
        }

        let linked = await run(.contactsAddLinkedContact(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, personId: fresh, note: "echo link", idempotencyToken: nil))
        if case .linkedContact(_, _, let row) = linked {
            _ = await run(.contactsRemoveLinkedContact(
                helperId: helper, messageId: TestMessageID.next(),
                linkId: row.id, idempotencyToken: nil))
        }
        _ = await run(.contactsAddLinkedOrganization(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, organizationId: organization, note: nil, idempotencyToken: nil))
        _ = await run(.contactsSetFavorite(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: fresh, favorite: true, idempotencyToken: nil))

        // Single-entry list edits (Phase 7): add/edit/remove per list,
        // plus the 0-match and ambiguous error outputs — all scanned.
        _ = await run(.contactsAddPhone(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "+1 555 0900", label: "work", idempotencyToken: nil))
        _ = await run(.contactsEditPhone(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, currentValue: "+1 555 0900",
            newValue: "+1 555 0901", newLabel: "work", idempotencyToken: nil))
        _ = await run(.contactsRemovePhone(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "+1 555 0901", idempotencyToken: nil))
        _ = await run(.contactsAddEmail(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "echo@doe.example", label: nil, idempotencyToken: nil))
        _ = await run(.contactsEditEmail(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, currentValue: "echo@doe.example",
            newValue: "echo2@doe.example", newLabel: nil, idempotencyToken: nil))
        _ = await run(.contactsRemoveEmail(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "echo2@doe.example", idempotencyToken: nil))
        _ = await run(.contactsAddURL(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "https://echo.example", label: nil, idempotencyToken: nil))
        _ = await run(.contactsEditURL(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, currentValue: "https://echo.example",
            newValue: "https://echo2.example", newLabel: nil, idempotencyToken: nil))
        _ = await run(.contactsRemoveURL(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "https://echo2.example", idempotencyToken: nil))
        _ = await run(.contactsAddRelatedName(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "Echo Relative", label: "cousin", idempotencyToken: nil))
        _ = await run(.contactsEditRelatedName(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, currentValue: "Echo Relative",
            newValue: "Echo B. Relative", newLabel: nil, idempotencyToken: nil))
        _ = await run(.contactsRemoveRelatedName(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "Echo B. Relative", idempotencyToken: nil))
        _ = await run(.contactsAddDate(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "--06-01", label: "echo day", idempotencyToken: nil))
        _ = await run(.contactsEditDate(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, currentValue: "--06-01",
            newValue: "--06-02", newLabel: nil, idempotencyToken: nil))
        _ = await run(.contactsRemoveDate(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "--06-02", idempotencyToken: nil))
        // Error outputs: a 0-match, an ambiguous match, a reserved URL.
        _ = await run(.contactsRemovePhone(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "+1 555 9999", idempotencyToken: nil))
        _ = await run(.contactsAddEmail(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "dupe@doe.example", label: "a", idempotencyToken: nil))
        _ = await run(.contactsAddEmail(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "dupe@doe.example", label: "b", idempotencyToken: nil))
        _ = await run(.contactsRemoveEmail(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "dupe@doe.example", idempotencyToken: nil))
        _ = await run(.contactsAddURL(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, value: "guesswho://contact/\(Sentinels.guessWhoUUID)",
            label: nil, idempotencyToken: nil))

        // Contact-record writes (Revision 2): create, patch, failed save,
        // and a user-confirmed delete — echo and error outputs all scanned.
        var createFields = WireContactFields()
        createFields.givenName = "Echo"
        createFields.familyName = "Person"
        createFields.phoneNumbers = [WireLabeledValue(label: "mobile", value: "+1 555 0000")]
        let created = await run(.contactsCreate(
            helperId: helper, messageId: TestMessageID.next(),
            kind: "person", fields: createFields, idempotencyToken: nil))
        var patch = WireContactScalarFields()
        patch.jobTitle = "Echo Tester"
        _ = await run(.contactsUpdate(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        // A failed contact-record save surfaces typed, never leaks.
        await MainActor.run {
            fixture.contacts.nextContactStoreError = NSError(
                domain: "NSCocoaErrorDomain", code: 134092,
                userInfo: [NSLocalizedDescriptionKey: Sentinels.appleNote])
        }
        _ = await run(.contactsUpdate(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        if case .contact(_, _, let createdContact) = created {
            await MainActor.run { fixture.confirmations.decisions = [true] }
            let probe = DeferredResponseProbe()
            await dispatcher.setDeferredResponder { response in
                await probe.record(response)
            }
            let immediate = await dispatcher.handle(.contactsDelete(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: createdContact.id, idempotencyToken: nil))
            XCTAssertNil(immediate, "the delete answers out of band")
            if let deferred = await probe.next() {
                responses.append(deferred)
            } else {
                XCTFail("expected the deferred delete response")
            }
        } else {
            XCTFail("expected the created contact echo")
        }

        // Error outputs: reserved name, blob type, un-adopted tag write.
        _ = await run(.contactsSetCustomField(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, name: "previousPhoto", type: nil, value: "x", idempotencyToken: nil))
        _ = await run(.contactsSetCustomField(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, name: "Blobby", type: "blob", value: "x", idempotencyToken: nil))

        let eventsResponse = await run(.eventsList(
            helperId: helper, messageId: TestMessageID.next(),
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        if case .eventPage(_, _, let page) = eventsResponse {
            if let gala = page.items.first(where: { $0.title == "Museum Gala" }) {
                let tagged = await run(.eventsAddTag(
                    helperId: helper, messageId: TestMessageID.next(),
                    eventId: gala.id, text: "echo tag", idempotencyToken: nil))
                if case .tag(_, _, let tag) = tagged {
                    _ = await run(.eventsEditTag(
                        helperId: helper, messageId: TestMessageID.next(),
                        eventId: gala.id, tagId: tag.id, text: "echo tag 2", idempotencyToken: nil))
                    _ = await run(.eventsDeleteTag(
                        helperId: helper, messageId: TestMessageID.next(),
                        eventId: gala.id, tagId: tag.id, idempotencyToken: nil))
                }
            }
            if let dentist = page.items.first(where: { $0.title == "Dentist" }) {
                _ = await run(.eventsAddTag(
                    helperId: helper, messageId: TestMessageID.next(),
                    eventId: dentist.id, text: "echo tag", idempotencyToken: nil))
            }
        }

        let createdGuide = await run(.guidesCreate(
            helperId: helper, messageId: TestMessageID.next(),
            name: "Echo Guide",
            places: [WireNewPlace(address: "9 Echo St", latitude: nil, longitude: nil)],
            idempotencyToken: nil))
        if case .guide(_, _, let guide) = createdGuide {
            let placesResponse = await run(.placesList(
                helperId: helper, messageId: TestMessageID.next(),
                guideId: guide.id, limit: nil, cursor: nil))
            if case .placePage(_, _, let placePage) = placesResponse,
               let place = placePage.items.first {
                _ = await run(.guidesReorderPlaces(
                    helperId: helper, messageId: TestMessageID.next(),
                    guideId: guide.id, placeIds: [place.id], idempotencyToken: nil))
                _ = await run(.placesDelete(
                    helperId: helper, messageId: TestMessageID.next(),
                    placeId: place.id, idempotencyToken: nil))
            }
            _ = await run(.guidesDelete(
                helperId: helper, messageId: TestMessageID.next(),
                guideId: guide.id, idempotencyToken: nil))
        }

        return responses
    }

    func testWriteToolsCannotTouchAppleNoteAndEchoesLeakNothing() async {
        let fixture = await writableFixture()
        let responses = await allWriteOutputs(fixture)
        XCTAssertGreaterThan(responses.count, 15, "the sweep should exercise every write tool")

        // Write-direction: after every write tool ran — including the
        // whole-card contacts_update — every original fixture contact's
        // Apple note is byte-identical: no tool has a parameter that can
        // reach it, and the update path carries it through untouched.
        let appleNotes = await MainActor.run {
            fixture.contacts.contacts
                .filter { $0.contactID.restorationToken.localID.hasPrefix("ABPerson-LOCAL-") }
                .filter { !$0.contactID.restorationToken.localID.contains("CREATED") }
                .map(\.note)
        }
        XCTAssertEqual(appleNotes.count, 3)
        for note in appleNotes {
            XCTAssertEqual(note, Sentinels.appleNote, "a write tool mutated the Apple contact note")
        }

        // Write-echo: the sentinel and every sealed identifier stay off the
        // wire across ALL write outputs, success and error alike.
        let output = responses.map { $0.agentVisibleText + "\n" + $0.wireJSON }.joined(separator: "\n")
        // The four excluded fields, absent from every write echo and error
        // (the ids that DO appear are the records' own durable UUIDs).
        XCTAssertFalse(output.contains(Sentinels.appleNote), "Apple note leaked via write echo")
        XCTAssertFalse(output.lowercased().contains("cabbage"), "Apple note fragment leaked")
        XCTAssertFalse(output.contains("guesswho://"), "identity URL form leaked")
        XCTAssertFalse(output.contains(Sentinels.localID), "Apple local id leaked")
        XCTAssertFalse(output.contains("ABPerson-LOCAL"), "an Apple local id leaked")
        XCTAssertFalse(output.contains(Sentinels.deviceID), "device id leaked")
        XCTAssertFalse(output.contains("modifiedBy"), "modifiedBy key leaked")
    }

    /// The search oracle still holds after writes (a write must not
    /// introduce an Apple-note-matching path).
    func testSearchStillNeverMatchesAppleNoteAfterWrites() async {
        let fixture = await writableFixture()
        _ = await allWriteOutputs(fixture)
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "classified-cabbage", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else {
            return XCTFail("expected a page")
        }
        XCTAssertEqual(page.items.count, 0)
    }
}

/// The Recently Deleted surface (plans/cli-mcp.md Phase 2 — the
/// prerequisite for enabling writes): agent deletions are visible,
/// restorable, and the modifiedAt guard blocks a restore over newer edits.
final class RecentlyDeletedTests: XCTestCase {

    private func writableFixture() async -> Fixture {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        return fixture
    }

    @MainActor
    private func makeService(_ fixture: Fixture) -> RecentlyDeletedService {
        RecentlyDeletedService(
            audit: fixture.audit, contacts: fixture.contacts, events: fixture.events)
    }

    private func addAndDeleteNote(
        _ fixture: Fixture, body: String
    ) async -> (contactHandle: String, noteID: String)? {
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = search,
              let jane = page.items.first(where: { $0.name == "Jane Doe" })?.id
        else { return nil }
        let added = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, body: body, idempotencyToken: nil))
        guard case .note(_, _, let note) = added else { return nil }
        let deleted = await fixture.dispatcher.handle(.contactsDeleteNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, noteId: note.id, idempotencyToken: nil))
        guard case .acknowledged = deleted else { return nil }
        return (jane, note.id)
    }

    func testDeletedNoteIsListedAndRestorable() async {
        let fixture = await writableFixture()
        guard let (_, _) = await addAndDeleteNote(fixture, body: "restore me") else {
            return XCTFail("setup failed")
        }
        let service = await makeService(fixture)

        let items = await service.items()
        guard let item = items.first(where: { $0.detail == "restore me" }) else {
            return XCTFail("the deleted note should appear in Recently Deleted")
        }
        XCTAssertEqual(item.kind, .note)
        XCTAssertTrue(item.title.contains("Jane Doe"), "rows resolve to a display name")
        XCTAssertTrue(item.canRestore)

        let restored = await service.restore(item)
        XCTAssertTrue(restored)

        // The note is live again through the same read the app renders.
        let liveBodies = await MainActor.run { () -> [String] in
            guard let jane = fixture.contacts.contacts.first(where: { $0.displayName == "Jane Doe" })
            else { return [] }
            return fixture.contacts.notes(for: jane.contactID).map(\.body)
        }
        XCTAssertTrue(liveBodies.contains("restore me"))

        // And it leaves the Recently Deleted list.
        let after = await service.items()
        XCTAssertFalse(after.contains { $0.detail == "restore me" })
    }

    /// The restore path must be TYPE-AWARE: a checkbox cell's value is a
    /// JSON bool, not a string, and a string-only restore guard would show
    /// an enabled Restore button that fails forever (review-cycle finding).
    /// Date locks the other non-plain-text branch of the same path.
    func testDeletedCheckboxAndDateCustomFieldsAreRestorable() async {
        let fixture = await writableFixture()
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = search,
              let jane = page.items.first(where: { $0.name == "Jane Doe" })?.id
        else { return XCTFail("no jane") }

        for (name, type, value) in [
            ("Newsletter", "checkbox", "true"),
            ("Next check-in", "date", "2026-08-01"),
        ] {
            let created = await fixture.dispatcher.handle(.contactsSetCustomField(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                contactId: jane, name: name, type: type, value: value,
                idempotencyToken: nil))
            guard case .customField(_, _, let field) = created else {
                return XCTFail("expected field echo for \(name), got \(created)")
            }
            let deleted = await fixture.dispatcher.handle(.contactsDeleteCustomField(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                contactId: jane, fieldId: field.id, idempotencyToken: nil))
            guard case .acknowledged = deleted else {
                return XCTFail("expected acknowledgement for \(name), got \(deleted)")
            }
        }

        let service = await makeService(fixture)
        let items = await service.items()
        for name in ["Newsletter", "Next check-in"] {
            guard let item = items.first(where: {
                $0.kind == .customField && $0.detail.hasPrefix(name)
            }) else {
                return XCTFail("deleted \(name) field should be listed")
            }
            XCTAssertTrue(item.canRestore, "\(name) should be restorable")
            let restored = await service.restore(item)
            XCTAssertTrue(restored, "\(name) restore must succeed, not fail forever")
        }

        // Both fields are live again with their ORIGINAL typed values.
        let liveFields = await MainActor.run { () -> [SidecarField] in
            guard let contact = fixture.contacts.contacts.first(where: { $0.displayName == "Jane Doe" })
            else { return [] }
            return fixture.contacts.fields(for: contact.contactID)
        }
        let newsletter = liveFields.first { $0.field == "Newsletter" }
        XCTAssertEqual(newsletter?.type, .checkbox)
        XCTAssertEqual(newsletter?.value, .bool(true), "the checkbox restores as its typed bool")
        let checkIn = liveFields.first { $0.field == "Next check-in" }
        XCTAssertEqual(checkIn?.type, .date)
        XCTAssertEqual(checkIn?.value, .string("2026-08-01T00:00:00Z"))
    }

    func testRestoreBlockedWhenRecordChangedSinceTheDelete() async {
        let fixture = await writableFixture()
        guard let (_, _) = await addAndDeleteNote(fixture, body: "contested") else {
            return XCTFail("setup failed")
        }
        // Something else (a human on another device, a later sync) touches
        // the tombstoned cell after the agent's delete: the live stamp no
        // longer matches the audited one.
        await MainActor.run {
            guard var list = fixture.contacts.notesByEffectiveID[Sentinels.guessWhoUUID],
                  let index = list.firstIndex(where: { $0.body == "contested" })
            else { return XCTFail("missing tombstone") }
            let old = list[index]
            list[index] = ContactNote(
                id: old.id, body: old.body, createdAt: old.createdAt,
                modifiedAt: old.modifiedAt.addingTimeInterval(30),
                modifiedBy: Sentinels.deviceID, deletedAt: old.deletedAt)
            fixture.contacts.notesByEffectiveID[Sentinels.guessWhoUUID] = list
        }

        let service = await makeService(fixture)
        let items = await service.items()
        guard let item = items.first(where: { $0.detail == "contested" }) else {
            return XCTFail("the deleted note should still be listed")
        }
        XCTAssertFalse(item.canRestore, "the modifiedAt guard must block the restore")
        let restored = await service.restore(item)
        XCTAssertFalse(restored, "a blocked item must not blind-restore")
    }

    func testDeletedTagAndLinkAreRestorable() async {
        let fixture = await writableFixture()
        let helper = Fixture.helper

        // Delete the fixture tag through the dispatcher.
        let eventsResponse = await fixture.dispatcher.handle(.eventsList(
            helperId: helper, messageId: TestMessageID.next(),
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let eventPage) = eventsResponse,
              let gala = eventPage.items.first(where: { $0.title == "Museum Gala" })
        else { return XCTFail("expected the gala") }
        let tagsResponse = await fixture.dispatcher.handle(.eventsListTags(
            helperId: helper, messageId: TestMessageID.next(),
            eventId: gala.id, limit: nil, cursor: nil))
        guard case .tagPage(_, _, let tagPage) = tagsResponse,
              let fundraiser = tagPage.items.first(where: { $0.text == "fundraiser" })
        else { return XCTFail("expected the fundraiser tag") }
        let tagDeleted = await fixture.dispatcher.handle(.eventsDeleteTag(
            helperId: helper, messageId: TestMessageID.next(),
            eventId: gala.id, tagId: fundraiser.id, idempotencyToken: nil))
        guard case .acknowledged = tagDeleted else { return XCTFail("tag delete failed") }

        // Delete the fixture person-link through the dispatcher.
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let contactPage) = search,
              let jane = contactPage.items.first(where: { $0.name == "Jane Doe" })?.id
        else { return XCTFail("no jane") }
        let linksResponse = await fixture.dispatcher.handle(.contactsListLinkedContacts(
            helperId: helper, messageId: TestMessageID.next(),
            contactId: jane, limit: nil, cursor: nil))
        guard case .linkedContactPage(_, _, let linkPage) = linksResponse,
              let roommate = linkPage.items.first(where: { $0.note == "College roommate" })
        else { return XCTFail("expected the person link") }
        let linkRemoved = await fixture.dispatcher.handle(.contactsRemoveLinkedContact(
            helperId: helper, messageId: TestMessageID.next(),
            linkId: roommate.id, idempotencyToken: nil))
        guard case .acknowledged = linkRemoved else { return XCTFail("link remove failed") }

        let service = await makeService(fixture)
        let items = await service.items()
        guard let tagItem = items.first(where: { $0.kind == .eventTag }) else {
            return XCTFail("deleted tag should be listed")
        }
        guard let linkItem = items.first(where: { $0.kind == .linkedContact }) else {
            return XCTFail("removed link should be listed")
        }
        XCTAssertTrue(tagItem.canRestore)
        XCTAssertTrue(linkItem.canRestore)

        let tagRestored = await service.restore(tagItem)
        let linkRestored = await service.restore(linkItem)
        XCTAssertTrue(tagRestored)
        XCTAssertTrue(linkRestored)

        let tagLive = await MainActor.run { () -> Bool in
            let galaUUID = fixture.events.events[0].id.uuidString.lowercased()
            return fixture.events.eventTags(forEventUUID: galaUUID)
                .contains { $0.text == "fundraiser" }
        }
        XCTAssertTrue(tagLive, "the restored tag is live again")

        let linkLive = await MainActor.run { () -> Bool in
            fixture.contacts.linksByID.values.contains {
                $0.note == "College roommate" && $0.deletedAt == nil
            }
        }
        XCTAssertTrue(linkLive, "the restored link is live again")
    }
}
