import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The focused-exclusion invariants (plans/cli-mcp.md Revision 2): the wire
/// carries the whole record EXCEPT four named fields — the Apple contact
/// note (INV-3, in content AND in match-presence), Apple local identifiers,
/// the `modifiedBy` device id, and the `guesswho://` URL form. Each has a
/// sentinel planted in the fixture; every tool output (reads, lists,
/// search, errors — the write direction is covered in
/// WriteSecurityAndRecoveryTests) is scanned for all of them.
final class SecurityInvariantTests: XCTestCase {

    /// Every read tool exercised against the fixture, including error
    /// responses — the complete read-side output surface.
    private func allOutputs(_ fixture: Fixture) async -> [WireResponse] {
        let dispatcher = fixture.dispatcher
        let helper = Fixture.helper
        var responses: [WireResponse] = []
        var contactIDs: [String] = []
        var eventIDs: [String] = []
        var groupIDs: [String] = []
        var guideIDs: [String] = []

        func run(_ request: WireRequest) async -> WireResponse {
            guard let response = await dispatcher.handle(request) else {
                XCTFail("read tools always answer immediately")
                return .error(
                    helperId: helper, messageId: "missing",
                    code: .invalidParams, message: "missing")
            }
            responses.append(response)
            return response
        }

        for query in ["doe", "fresh", "jane"] {
            let response = await run(.contactsSearch(
                helperId: helper, messageId: TestMessageID.next(),
                query: query, limit: nil, cursor: nil))
            if case .contactPage(_, _, let page) = response {
                contactIDs.append(contentsOf: page.items.map(\.id))
            }
        }
        XCTAssertFalse(contactIDs.isEmpty, "fixture searches should find contacts")

        for id in Set(contactIDs) {
            _ = await run(.contactsGet(helperId: helper, messageId: TestMessageID.next(), contactId: id))
            _ = await run(.contactsListNotes(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: id, limit: nil, cursor: nil))
            _ = await run(.contactsListCustomFields(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: id, limit: nil, cursor: nil))
            _ = await run(.contactsListLinkedContacts(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: id, limit: nil, cursor: nil))
            _ = await run(.contactsListLinkedOrganizations(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: id, limit: nil, cursor: nil))
        }

        _ = await run(.contactsListFavorites(
            helperId: helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        let groupsResponse = await run(.contactsListGroups(
            helperId: helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        if case .groupPage(_, _, let page) = groupsResponse {
            groupIDs = page.items.map(\.id)
        }
        for id in groupIDs {
            _ = await run(.groupsListMembers(
                helperId: helper, messageId: TestMessageID.next(),
                groupId: id, limit: nil, cursor: nil))
        }

        let eventsResponse = await run(.eventsList(
            helperId: helper, messageId: TestMessageID.next(),
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        if case .eventPage(_, _, let page) = eventsResponse {
            eventIDs = page.items.map(\.id)
        }
        XCTAssertFalse(eventIDs.isEmpty, "fixture window should find events")
        for id in eventIDs {
            _ = await run(.eventsGet(helperId: helper, messageId: TestMessageID.next(), eventId: id))
            _ = await run(.eventsListTags(
                helperId: helper, messageId: TestMessageID.next(),
                eventId: id, limit: nil, cursor: nil))
        }

        let guidesResponse = await run(.guidesList(
            helperId: helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        if case .guidePage(_, _, let page) = guidesResponse {
            guideIDs = page.items.map(\.id)
        }
        for id in guideIDs {
            _ = await run(.guidesGet(helperId: helper, messageId: TestMessageID.next(), guideId: id))
            _ = await run(.placesList(
                helperId: helper, messageId: TestMessageID.next(),
                guideId: id, limit: nil, cursor: nil))
        }
        _ = await run(.placesList(
            helperId: helper, messageId: TestMessageID.next(),
            guideId: nil, limit: nil, cursor: nil))

        _ = await run(.listTools(helperId: helper, messageId: TestMessageID.next()))

        // Error responses are output too (INV-3's "AND error responses").
        _ = await run(.contactsGet(
            helperId: helper, messageId: TestMessageID.next(), contactId: "not-a-real-id"))
        _ = await run(.contactsSearch(
            helperId: helper, messageId: TestMessageID.next(), query: "x", limit: nil, cursor: nil))
        _ = await run(.eventsList(
            helperId: helper, messageId: TestMessageID.next(),
            startDate: "garbage", endDate: "2025-12-01T00:00:00Z", limit: nil, cursor: nil))

        return responses
    }

    private func combinedOutput(_ responses: [WireResponse]) -> String {
        responses.map { $0.agentVisibleText + "\n" + $0.wireJSON }.joined(separator: "\n")
    }

    // MARK: - INV-3: Apple note exclusion

    func testAppleNoteSentinelAbsentFromEveryOutputAndError() async {
        let fixture = await Fixture.make()
        let output = combinedOutput(await allOutputs(fixture))
        XCTAssertFalse(
            output.contains(Sentinels.appleNote),
            "the Apple contact note leaked into tool output")
        XCTAssertFalse(
            output.lowercased().contains("cabbage"),
            "an Apple-note fragment leaked into tool output")
        // Structural: the contact payload key set simply has no note-shaped
        // key (absence of the key, not an empty value).
        XCTAssertFalse(output.contains("\"note\" :") && output.contains("classified"),
                       "note-shaped key carrying Apple note content")
    }

    func testSearchNeverMatchesAppleNote() async {
        let fixture = await Fixture.make()
        for query in [Sentinels.appleNote, "classified-cabbage", "cabbage-9481", "XAPPLENOTESENTINELX"] {
            let response = await fixture.dispatcher.handle(.contactsSearch(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                query: query, limit: nil, cursor: nil))
            guard case .contactPage(_, _, let page) = response else {
                XCTFail("search should return a page; got \(String(describing: response))")
                continue
            }
            XCTAssertEqual(
                page.items.count, 0,
                "search(\(query)) matched via the Apple note — match-presence leak (INV-3)")
        }
    }

    // MARK: - Identity-URL exclusion (the id is the bare UUID, never the URL)

    func testSearchForGuessWhoURLFindsNothing() async {
        let fixture = await Fixture.make()
        for query in ["guesswho", "guesswho://"] {
            let response = await fixture.dispatcher.handle(.contactsSearch(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                query: query, limit: nil, cursor: nil))
            guard case .contactPage(_, _, let page) = response else {
                XCTFail("search should return a page; got \(String(describing: response))")
                continue
            }
            XCTAssertEqual(
                page.items.count, 0,
                "search(\(query)) matched the internal identity URL form")
        }
    }

    // MARK: - The targeted exclusion test (replaces the allowlist golden test)

    /// One sentinel per excluded field, asserted absent from EVERY read
    /// output and error. (The write direction — no tool accepting these
    /// fields, write echoes clean — is WriteSecurityAndRecoveryTests.)
    func testExcludedFieldSentinelsAppearInZeroReadOutputs() async {
        let fixture = await Fixture.make()
        let output = combinedOutput(await allOutputs(fixture))

        // Exclusion 1: the Apple contact note.
        XCTAssertFalse(output.contains(Sentinels.appleNote), "Apple note leaked")
        // Exclusion 2: Apple local identifiers — contact, group, calendar.
        XCTAssertFalse(output.contains(Sentinels.localID), "Apple local id leaked")
        XCTAssertFalse(output.contains("ABPerson-LOCAL"), "an Apple local id leaked")
        XCTAssertFalse(output.contains("CNGroup-LOCAL"), "group local id leaked")
        XCTAssertFalse(output.contains("EK-SENTINEL"), "raw calendar id leaked (must ride derived)")
        // Exclusion 3: the modifiedBy device id.
        XCTAssertFalse(output.contains(Sentinels.deviceID), "modifiedBy device id leaked")
        XCTAssertFalse(output.contains("modifiedBy"), "modifiedBy key leaked")
        // Exclusion 4: the guesswho:// URL FORM. The bare UUID is the
        // contact's id and DOES appear; the URL wrapping never may.
        XCTAssertFalse(output.contains("guesswho://"), "identity URL form leaked")
        XCTAssertTrue(
            output.contains(Sentinels.guessWhoUUID),
            "the GuessWho UUID IS the contact id and should appear as one")
    }

    /// The contact id is the plain GuessWho UUID and stays stable across
    /// repeated reads (it is the record's own durable identity).
    func testContactIDIsTheGuessWhoUUID() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response,
              let jane = page.items.first(where: { $0.name == "Jane Doe" })
        else { return XCTFail("expected Jane") }
        XCTAssertEqual(jane.id, Sentinels.guessWhoUUID)
    }

    /// The attachment-typed field never surfaces (the previousPhoto
    /// phantom-row lesson, inherited through fields(for:)).
    func testBlobFieldsNeverSurface() async {
        let fixture = await Fixture.make()
        let output = combinedOutput(await allOutputs(fixture))
        XCTAssertFalse(output.contains("previousPhoto"), "reserved attachment field leaked")
        XCTAssertFalse(output.contains("blob:sha256"), "attachment payload leaked")
    }
}
