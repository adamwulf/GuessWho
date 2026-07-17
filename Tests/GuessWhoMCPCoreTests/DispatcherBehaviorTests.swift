import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Gates, wire-id lifecycle, pagination, caps, and rate limiting — the
/// dispatch-core behavior the exit criteria name (ids per Revision 2: the
/// contact id IS the GuessWho UUID, stable across the deterministic mint).
final class DispatcherBehaviorTests: XCTestCase {

    private func expectError(
        _ response: WireResponse?, code: WireErrorCode,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let payload = response?.errorPayload else {
            return XCTFail(
                "expected \(code) error, got \(String(describing: response))",
                file: file, line: line)
        }
        XCTAssertEqual(payload.code, code, file: file, line: line)
        XCTAssertFalse(payload.message.isEmpty, file: file, line: line)
    }

    // MARK: - Gates

    func testMasterToggleOffHidesToolsAndRejectsCallsServerSide() async {
        let fixture = await Fixture.make()
        await MainActor.run { fixture.gates.mcpAccess = .off }

        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, let status) = list else {
            return XCTFail("expected toolList")
        }
        XCTAssertTrue(tools.isEmpty, "toggle off must hide every tool")
        XCTAssertEqual(status, WireErrorMessage.disabled)

        // Hiding is UX; the per-call gate is the enforcement: a direct
        // call to an unlisted tool is rejected server-side.
        let call = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: "m2", query: "jane", limit: nil, cursor: nil))
        expectError(call, code: .disabled)
    }

    func testPermissionGateHidesAndRejectsPerDomain() async {
        let fixture = await Fixture.make()
        await MainActor.run { fixture.gates.contactsAuthorized = false }

        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, _) = list else {
            return XCTFail("expected toolList")
        }
        let names = Set(tools.map(\.name))
        XCTAssertFalse(names.contains(MCPTool.contactsSearch.rawValue))
        XCTAssertTrue(names.contains(MCPTool.eventsList.rawValue), "events stay visible")
        XCTAssertTrue(names.contains(MCPTool.guidesList.rawValue), "guides need no permission")

        let call = await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "m2", contactId: "whatever"))
        expectError(call, code: .permissionDenied)
    }

    /// CLI-origin helper ids gate on the CLI toggle, independent of MCP.
    func testOriginPicksItsOwnToggle() async {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.gates.mcpAccess = .off
            fixture.gates.cliAccess = .readOnly
        }
        let cliHelper = RequestOrigin.cli.makeHelperId()
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: cliHelper, messageId: "m", query: "jane", limit: nil, cursor: nil))
        if case .contactPage = response {} else {
            XCTFail("CLI origin should pass while only MCP is disabled; got \(response)")
        }
    }

    // MARK: - Wire ids

    func testUnknownIdIsNotFound() async {
        let fixture = await Fixture.make()
        // Not id-shaped at all.
        expectError(await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "m", contactId: "never-minted")),
            code: .notFound)
        // UUID-shaped but referring to nothing.
        expectError(await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "m2",
            contactId: UUID().uuidString.lowercased())),
            code: .notFound)
    }

    func testWrongKindIdIsNotFound() async {
        let fixture = await Fixture.make()
        let guidesResponse = await fixture.dispatcher.handle(.guidesList(
            helperId: Fixture.helper, messageId: "m", limit: nil, cursor: nil))
        guard case .guidePage(_, _, let page) = guidesResponse,
              let guideID = page.items.first?.id
        else { return XCTFail("expected a guide") }

        // A guide's UUID handed to a contacts tool resolves to no contact.
        let response = await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "m2", contactId: guideID))
        expectError(response, code: .notFound)
    }

    func testSameRecordKeepsSameIdWithinARun() async {
        let fixture = await Fixture.make()
        func janeID() async -> String? {
            let response = await fixture.dispatcher.handle(.contactsSearch(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                query: "jane", limit: nil, cursor: nil))
            guard case .contactPage(_, _, let page) = response else { return nil }
            return page.items.first(where: { $0.name == "Jane Doe" })?.id
        }
        let first = await janeID()
        let second = await janeID()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "ids must be stable across repeated reads")
    }

    /// THE Revision 2 id property: the id handed out for a never-written
    /// contact is the exact UUID the deterministic mint assigns on its
    /// first write — one id, stable across the mint boundary.
    func testPreMintIdSurvivesTheMint() async {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "fresh", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = search,
              let preMintID = page.items.first(where: { $0.name == "Fresh Face" })?.id
        else { return XCTFail("expected the fresh contact") }

        // First write mints.
        let write = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: preMintID, body: "first write", idempotencyToken: nil))
        XCTAssertNil(write?.errorPayload)

        let (mintedUUID, mintCount) = await MainActor.run { () -> (String?, Int) in
            let contact = fixture.contacts.contacts.first {
                $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88"
            }
            return (contact?.contactID.restorationToken.guessWhoID, fixture.contacts.mintCount)
        }
        XCTAssertEqual(mintCount, 1)
        XCTAssertEqual(mintedUUID, preMintID,
                       "the card must mint EXACTLY the id the wire already handed out")

        // And the same id still lists after the mint.
        let again = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "fresh", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let pageAfter) = again else { return XCTFail("no page") }
        XCTAssertEqual(
            pageAfter.items.first(where: { $0.name == "Fresh Face" })?.id, preMintID)
    }

    /// An event with no GuessWho record of its own (system calendar only)
    /// still resolves for events_get via its system id — and no record is
    /// minted by the read.
    func testUnadoptedEventResolvesWithoutMinting() async {
        let fixture = await Fixture.make()
        let listResponse = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: "m",
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = listResponse else {
            return XCTFail("expected events")
        }
        guard let dentist = page.items.first(where: { $0.title == "Dentist" }) else {
            return XCTFail("expected the system-only event in the list")
        }
        let getResponse = await fixture.dispatcher.handle(.eventsGet(
            helperId: Fixture.helper, messageId: "m2", eventId: dentist.id))
        guard case .event(_, _, let event) = getResponse else {
            return XCTFail("expected the event to resolve; got \(getResponse)")
        }
        XCTAssertEqual(event.title, "Dentist")
        // Reads never mint: the stored-events list is untouched.
        let stored = await MainActor.run { fixture.events.events.count }
        XCTAssertEqual(stored, 1)
    }

    // MARK: - Bounded reads

    func testPaginationLimitAndCursor() async {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.contacts.contacts = (0..<25).map { index in
                Contact(givenName: "Person\(index)", familyName: "Pager")
            }
        }
        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let response = await fixture.dispatcher.handle(.contactsSearch(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                query: "pager", limit: 10, cursor: cursor))
            guard case .contactPage(_, _, let page) = response else {
                return XCTFail("expected a page; got \(response)")
            }
            XCTAssertLessThanOrEqual(page.items.count, 10)
            seen.append(contentsOf: page.items.map(\.name))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(seen.count, 25)
        XCTAssertEqual(Set(seen).count, 25, "pages must not overlap")
    }

    func testInvalidCursorRejected() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: "m", query: "jane",
            limit: nil, cursor: "made-up"))
        expectError(response, code: .invalidParams)
    }

    func testOversizePageReturnsTypedTooLargeNotTruncation() async {
        let fixture = await Fixture.make()
        let bigBody = String(repeating: "long note content ", count: 20_000) // ~360KB
        await MainActor.run {
            fixture.contacts.notesByEffectiveID[Sentinels.guessWhoUUID] = [
                ContactNote(
                    id: UUID(), body: bigBody,
                    createdAt: Date(), modifiedAt: Date(),
                    modifiedBy: Sentinels.deviceID)
            ]
        }
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: "m", query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = search,
              let jane = page.items.first(where: { $0.name == "Jane Doe" })
        else { return XCTFail("expected Jane") }

        let response = await fixture.dispatcher.handle(.contactsListNotes(
            helperId: Fixture.helper, messageId: "m2", contactId: jane.id,
            limit: nil, cursor: nil))
        expectError(response, code: .tooLarge)
    }

    // MARK: - Search bounds

    func testShortNeedleRejected() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: "m", query: " j ", limit: nil, cursor: nil))
        expectError(response, code: .invalidParams)
    }

    func testSearchRateLimitIsGlobalAcrossHelpers() async {
        let fixture = await Fixture.make()
        let limited = ToolDispatcher(
            contacts: fixture.contacts, events: fixture.events,
            guides: fixture.guides, gates: fixture.gates,
            searchLimitPerWindow: 2, searchWindowSeconds: 60)

        let helperA = RequestOrigin.mcp.makeHelperId()
        let helperB = RequestOrigin.mcp.makeHelperId()
        let first = await limited.handle(.contactsSearch(
            helperId: helperA, messageId: "1", query: "jane", limit: nil, cursor: nil))
        if case .contactPage = first {} else { XCTFail("first search should pass") }
        let second = await limited.handle(.contactsSearch(
            helperId: helperB, messageId: "2", query: "jane", limit: nil, cursor: nil))
        if case .contactPage = second {} else { XCTFail("second search should pass") }
        // Third search — from a DIFFERENT helper — still hits the budget:
        // the window is per host run, not per helper (re-announce is cheap).
        let third = await limited.handle(.contactsSearch(
            helperId: RequestOrigin.mcp.makeHelperId(), messageId: "3",
            query: "jane", limit: nil, cursor: nil))
        expectError(third, code: .busy)
    }
}

/// Deterministic-identity unit behavior (Revision 2): the wire id scheme
/// and the package's deterministic mint agree by construction.
final class DeterministicIdentityTests: XCTestCase {

    @MainActor
    func testDeterministicMintIsAValidStableUUID() {
        let fresh = Fixture.freshFace()
        let first = fresh.deterministicGuessWhoID
        let second = Fixture.freshFace().deterministicGuessWhoID
        XCTAssertEqual(first, second, "same inputs must derive the same UUID")
        XCTAssertNotNil(UUID(uuidString: first), "must be a real UUID (the GuessWho id format)")
        XCTAssertEqual(first, first.lowercased(), "canonical lowercase")
        // Distinct contacts derive distinct UUIDs.
        XCTAssertNotEqual(first, Fixture.janeDoe().deterministicGuessWhoID)
    }

    /// The pre-mint id embeds the display name: if system unification
    /// re-points the localID at a DIFFERENT person, the id stops resolving
    /// (the structural stale-localID guard) — asserted end-to-end here.
    func testPreMintIdStopsResolvingWhenTheContactIsRepointed() async {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "fresh", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = search,
              let preMintID = page.items.first(where: { $0.name == "Fresh Face" })?.id
        else { return XCTFail("expected the fresh contact") }

        await MainActor.run {
            guard let index = fixture.contacts.contacts.firstIndex(where: {
                $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88"
            }) else { return }
            var repointed = fixture.contacts.contacts[index]
            repointed.givenName = "Somebody"
            repointed.familyName = "Else"
            fixture.contacts.contacts[index] = repointed
        }

        let write = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "m",
            contactId: preMintID, body: "wrong person", idempotencyToken: nil))
        XCTAssertEqual(write?.errorPayload?.code, .notFound,
                       "a re-pointed pre-mint id must stop resolving, never misdirect a write")
        let allBodies = await MainActor.run {
            fixture.contacts.notesByEffectiveID.values.flatMap { $0 }.map(\.body)
        }
        XCTAssertFalse(allBodies.contains("wrong person"))
    }

    /// System-only events ride a DERIVED id (never the raw calendar id),
    /// and it keeps resolving after the user adopts the event in the app.
    func testSystemEventIdIsDerivedAndSurvivesAdoption() async {
        let fixture = await Fixture.make()
        let list = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: "m",
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = list,
              let dentist = page.items.first(where: { $0.title == "Dentist" })
        else { return XCTFail("expected the system-only event") }
        XCTAssertFalse(dentist.id.contains("EK-SENTINEL"), "raw calendar id must not ride")
        XCTAssertTrue(dentist.id.hasPrefix("e-"))

        // The user opens the event in the app: a record now exists for the
        // calendar id. The SAME wire id keeps resolving, now to the record.
        await MainActor.run {
            let adopted = Event(
                id: UUID(),
                eventKitID: "EK-SENTINEL-42",
                title: "Dentist",
                startDate: Date(timeIntervalSince1970: 1_760_100_000),
                endDate: Date(timeIntervalSince1970: 1_760_103_600))
            fixture.events.events.append(adopted)
            fixture.events.eventKitOnlyEvents.removeValue(forKey: "EK-SENTINEL-42")
        }
        let after = await fixture.dispatcher.handle(.eventsGet(
            helperId: Fixture.helper, messageId: "m2", eventId: dentist.id))
        guard case .event(_, _, let event) = after else {
            return XCTFail("the derived id should still resolve after adoption; got \(String(describing: after))")
        }
        XCTAssertEqual(event.title, "Dentist")
    }
}
