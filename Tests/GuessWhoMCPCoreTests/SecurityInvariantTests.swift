import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// INV-3 (the Apple note never crosses the wire, in content OR in match-
/// presence) and INV-3b (positive field allowlist: no identity URL, no raw
/// UUID/local id, no device id) — plans/cli-mcp.md Phase 1 exit criteria.
final class SecurityInvariantTests: XCTestCase {

    /// Every read tool exercised against the fixture, including error
    /// responses — the complete Phase 1 output surface.
    private func allOutputs(_ fixture: Fixture) async -> [WireResponse] {
        let dispatcher = fixture.dispatcher
        let helper = Fixture.helper
        var responses: [WireResponse] = []
        var contactHandles: [String] = []
        var eventHandles: [String] = []
        var groupHandles: [String] = []
        var guideHandles: [String] = []

        func run(_ request: WireRequest) async -> WireResponse {
            let response = await dispatcher.handle(request)
            responses.append(response)
            return response
        }

        for query in ["doe", "fresh", "jane"] {
            let response = await run(.contactsSearch(
                helperId: helper, messageId: TestMessageID.next(),
                query: query, limit: nil, cursor: nil))
            if case .contactPage(_, _, let page) = response {
                contactHandles.append(contentsOf: page.items.map(\.id))
            }
        }
        XCTAssertFalse(contactHandles.isEmpty, "fixture searches should find contacts")

        for handle in Set(contactHandles) {
            _ = await run(.contactsGet(helperId: helper, messageId: TestMessageID.next(), contactId: handle))
            _ = await run(.contactsListNotes(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: handle, limit: nil, cursor: nil))
            _ = await run(.contactsListCustomFields(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: handle, limit: nil, cursor: nil))
            _ = await run(.contactsListLinkedContacts(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: handle, limit: nil, cursor: nil))
            _ = await run(.contactsListLinkedOrganizations(
                helperId: helper, messageId: TestMessageID.next(),
                contactId: handle, limit: nil, cursor: nil))
        }

        _ = await run(.contactsListFavorites(
            helperId: helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        let groupsResponse = await run(.contactsListGroups(
            helperId: helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        if case .groupPage(_, _, let page) = groupsResponse {
            groupHandles = page.items.map(\.id)
        }
        for handle in groupHandles {
            _ = await run(.groupsListMembers(
                helperId: helper, messageId: TestMessageID.next(),
                groupId: handle, limit: nil, cursor: nil))
        }

        let eventsResponse = await run(.eventsList(
            helperId: helper, messageId: TestMessageID.next(),
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        if case .eventPage(_, _, let page) = eventsResponse {
            eventHandles = page.items.map(\.id)
        }
        XCTAssertFalse(eventHandles.isEmpty, "fixture window should find events")
        for handle in eventHandles {
            _ = await run(.eventsGet(helperId: helper, messageId: TestMessageID.next(), eventId: handle))
            _ = await run(.eventsListTags(
                helperId: helper, messageId: TestMessageID.next(),
                eventId: handle, limit: nil, cursor: nil))
        }

        let guidesResponse = await run(.guidesList(
            helperId: helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        if case .guidePage(_, _, let page) = guidesResponse {
            guideHandles = page.items.map(\.id)
        }
        for handle in guideHandles {
            _ = await run(.guidesGet(helperId: helper, messageId: TestMessageID.next(), guideId: handle))
            _ = await run(.placesList(
                helperId: helper, messageId: TestMessageID.next(),
                guideId: handle, limit: nil, cursor: nil))
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
                XCTFail("search should return a page; got \(response)")
                continue
            }
            XCTAssertEqual(
                page.items.count, 0,
                "search(\(query)) matched via the Apple note — match-presence leak (INV-3)")
        }
    }

    // MARK: - INV-3b: allowlist / identity sealing

    func testSearchForGuessWhoFindsNothing() async {
        let fixture = await Fixture.make()
        for query in ["guesswho", "guesswho://", Sentinels.guessWhoUUID] {
            let response = await fixture.dispatcher.handle(.contactsSearch(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                query: query, limit: nil, cursor: nil))
            guard case .contactPage(_, _, let page) = response else {
                XCTFail("search should return a page; got \(response)")
                continue
            }
            XCTAssertEqual(
                page.items.count, 0,
                "search(\(query)) matched the internal identity URL (INV-3b)")
        }
    }

    func testNoSealedIdentifierAppearsInAnyOutput() async {
        let fixture = await Fixture.make()
        let output = combinedOutput(await allOutputs(fixture))

        XCTAssertFalse(output.contains("guesswho://"), "identity URL leaked")
        XCTAssertFalse(output.contains(Sentinels.guessWhoUUID), "GuessWho UUID leaked")
        XCTAssertFalse(output.contains(Sentinels.localID), "Apple local id leaked")
        XCTAssertFalse(output.contains("ABPerson-LOCAL"), "an Apple local id leaked")
        XCTAssertFalse(output.contains(Sentinels.deviceID), "modifiedBy device id leaked")
        XCTAssertFalse(output.contains("modifiedBy"), "modifiedBy key leaked")
        XCTAssertFalse(output.contains("CNGroup-LOCAL"), "group local id leaked")
        XCTAssertFalse(output.contains("EK-SENTINEL"), "system calendar id leaked")

        // No bare UUID of ANY kind: every id on the wire is a sealed
        // 32-hex-char token, deliberately not UUID-shaped.
        let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        XCTAssertNil(
            output.range(of: uuidPattern, options: .regularExpression),
            "a raw UUID crossed the wire")
    }

    func testGoldenDTOKeySetsMatchAllowlist() async throws {
        let fixture = await Fixture.make()
        let helper = Fixture.helper

        func jsonKeys(_ text: String) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            guard let dictionary = object as? [String: Any] else { return [] }
            return Set(dictionary.keys)
        }
        func itemKeys(_ text: String) throws -> [Set<String>] {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            guard let dictionary = object as? [String: Any],
                  let items = dictionary["items"] as? [[String: Any]] else { return [] }
            return items.map { Set($0.keys) }
        }

        let searchResponse = await fixture.dispatcher.handle(.contactsSearch(
            helperId: helper, messageId: "m1", query: "jane", limit: nil, cursor: nil))
        let summaryAllowlist: Set<String> = ["id", "kind", "name", "organization", "jobTitle"]
        for keys in try itemKeys(searchResponse.agentVisibleText) {
            XCTAssertTrue(keys.isSubset(of: summaryAllowlist), "summary keys \(keys) exceed allowlist")
            XCTAssertTrue(keys.isSuperset(of: ["id", "kind", "name"]))
        }
        guard case .contactPage(_, _, let searchPage) = searchResponse,
              let janeHandle = searchPage.items.first?.id
        else {
            return XCTFail("expected Jane in search results")
        }

        let contactResponse = await fixture.dispatcher.handle(.contactsGet(
            helperId: helper, messageId: "m2", contactId: janeHandle))
        let contactAllowlist: Set<String> = [
            "id", "kind", "name", "givenName", "familyName", "nickname",
            "organization", "department", "jobTitle", "phoneNumbers",
            "emailAddresses", "postalAddresses", "urlAddresses", "birthday",
            "dates", "isFavorite",
        ]
        let contactKeys = try jsonKeys(contactResponse.agentVisibleText)
        XCTAssertTrue(contactKeys.isSubset(of: contactAllowlist), "contact keys \(contactKeys) exceed allowlist")
        XCTAssertTrue(contactKeys.isSuperset(of: ["id", "kind", "name", "phoneNumbers", "isFavorite"]))
        XCTAssertFalse(contactKeys.contains("note"), "Apple-note-shaped key on the contact DTO")

        let notesResponse = await fixture.dispatcher.handle(.contactsListNotes(
            helperId: helper, messageId: "m3", contactId: janeHandle, limit: nil, cursor: nil))
        for keys in try itemKeys(notesResponse.agentVisibleText) {
            XCTAssertEqual(keys, ["id", "body", "createdAt", "modifiedAt"])
        }

        let fieldsResponse = await fixture.dispatcher.handle(.contactsListCustomFields(
            helperId: helper, messageId: "m4", contactId: janeHandle, limit: nil, cursor: nil))
        for keys in try itemKeys(fieldsResponse.agentVisibleText) {
            XCTAssertEqual(keys, ["id", "name", "type", "value", "modifiedAt"])
        }

        let groupsResponse = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: helper, messageId: "m5", limit: nil, cursor: nil))
        for keys in try itemKeys(groupsResponse.agentVisibleText) {
            XCTAssertEqual(keys, ["id", "name"], "group DTO must carry ONLY id+name (no localID)")
        }
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
