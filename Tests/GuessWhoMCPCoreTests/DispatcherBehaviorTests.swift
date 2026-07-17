import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Gates, sealed-id lifecycle, pagination, caps, and rate limiting —
/// the dispatch-core behavior the Phase 1 exit criteria name.
final class DispatcherBehaviorTests: XCTestCase {

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

    // MARK: - Gates

    func testMasterToggleOffHidesToolsAndRejectsCallsServerSide() async {
        let fixture = await Fixture.make()
        await MainActor.run { fixture.gates.isMCPEnabled = false }

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
            fixture.gates.isMCPEnabled = false
            fixture.gates.isCLIEnabled = true
        }
        let cliHelper = RequestOrigin.cli.makeHelperId()
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: cliHelper, messageId: "m", query: "jane", limit: nil, cursor: nil))
        if case .contactPage = response {} else {
            XCTFail("CLI origin should pass while only MCP is disabled; got \(response)")
        }
    }

    // MARK: - Sealed ids

    func testUnknownIdIsStaleNotTransportError() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "m", contactId: "never-minted"))
        expectError(response, code: .staleHandle)
    }

    func testWrongKindIdIsInvalidParams() async {
        let fixture = await Fixture.make()
        let guidesResponse = await fixture.dispatcher.handle(.guidesList(
            helperId: Fixture.helper, messageId: "m", limit: nil, cursor: nil))
        guard case .guidePage(_, _, let page) = guidesResponse,
              let guideHandle = page.items.first?.id
        else { return XCTFail("expected a guide") }

        let response = await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "m2", contactId: guideHandle))
        expectError(response, code: .invalidParams)
    }

    func testSameRecordKeepsSameIdWithinARun() async {
        let fixture = await Fixture.make()
        func janeHandle() async -> String? {
            let response = await fixture.dispatcher.handle(.contactsSearch(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                query: "jane", limit: nil, cursor: nil))
            guard case .contactPage(_, _, let page) = response else { return nil }
            return page.items.first(where: { $0.name == "Jane Doe" })?.id
        }
        let first = await janeHandle()
        let second = await janeHandle()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "ids must be stable across repeated reads in one run")
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

/// Sealed-handle registry unit behavior.
final class HandleRegistryTests: XCTestCase {
    func testMintingIsIdempotentPerReferent() async {
        let registry = HandleRegistry()
        let referent = HandleReferent.group(localID: "G1")
        let first = await registry.handle(for: referent)
        let second = await registry.handle(for: referent)
        XCTAssertEqual(first, second)
        let other = await registry.handle(for: .group(localID: "G2"))
        XCTAssertNotEqual(first, other)
    }

    func testHandlesAreOpaqueTokensNotUUIDs() async {
        let registry = HandleRegistry()
        let handle = await registry.handle(for: .group(localID: "G1"))
        XCTAssertEqual(handle.count, 32)
        XCTAssertNil(handle.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}"#, options: .regularExpression))
        XCTAssertNotNil(handle.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression))
    }

    func testUnknownHandleResolvesToNothing() async {
        let registry = HandleRegistry()
        let entry = await registry.entry(for: "feedfacefeedfacefeedfacefeedface")
        XCTAssertNil(entry)
    }

    @MainActor
    func testFingerprintMintedOnlyForContactsWithoutDurableIdentity() async {
        let registry = HandleRegistry()
        let fresh = Fixture.freshFace()
        let fingerprint = HandleRegistry.displayNameFingerprint(fresh)
        let handle = await registry.handle(
            for: .contact(fresh.contactID.restorationToken), fingerprint: fingerprint)
        let entry = await registry.entry(for: handle)
        XCTAssertEqual(entry?.fingerprint, fingerprint)
        XCTAssertNotEqual(fingerprint, 0)

        // Same name → same fingerprint (deterministic, process-independent).
        let again = HandleRegistry.displayNameFingerprint(Fixture.freshFace())
        XCTAssertEqual(fingerprint, again)
    }
}
