import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// contacts_list — the whole-book enumeration read (contacts_search needs a
/// 2+ character needle, so this is the only way to list EVERY contact).
/// These tests run the REAL mapping/pagination/id path: real `Contact`
/// values through the production `WireMapping.summary` + `WireRecordID`
/// derivation + the dispatcher's shared offset-cursor slicing. Only the
/// contact BOOK is the fake source (`allContacts` — a real
/// `ContactsRepository` needs the system Contacts store + TCC, which
/// headless `swift test` can't have).
final class ContactsListToolTests: XCTestCase {

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

    private func listPage(
        _ fixture: Fixture, type: String? = nil, limit: Int? = nil, cursor: String? = nil
    ) async -> WirePage<WireContactSummary>? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            type: type, limit: limit, cursor: cursor))
        guard case .contactPage(_, _, let page) = response else {
            XCTFail("expected a contact page; got \(String(describing: response))")
            return nil
        }
        return page
    }

    /// Every id in cursor order for the given filter — a full paged walk.
    private func fullWalk(
        _ fixture: Fixture, type: String? = nil, limit: Int? = nil
    ) async -> [String] {
        var ids: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            guard let page = await listPage(fixture, type: type, limit: limit, cursor: cursor) else {
                return ids
            }
            ids.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 50
        return ids
    }

    // MARK: - Kinds, order, ids

    /// The default fixture holds three contacts: one reconciled person, one
    /// never-written person, one organization. The list returns all three
    /// in (display name, id) order, each with its durable wire id — the
    /// minted GuessWho UUID for the reconciled card, the deterministic
    /// pre-mint preview for the others.
    func testListsEveryContactSortedWithKindsAndDurableIDs() async {
        let fixture = await Fixture.make()
        guard let page = await listPage(fixture) else { return }
        XCTAssertNil(page.nextCursor, "three contacts fit one page")
        XCTAssertEqual(
            page.items.map(\.name), ["Doe Industries", "Fresh Face", "Jane Doe"],
            "fixed lowercased-name order, independent of the source array")
        XCTAssertEqual(page.items.map(\.kind), ["organization", "person", "person"])

        XCTAssertEqual(
            page.items.first(where: { $0.name == "Jane Doe" })?.id,
            Sentinels.guessWhoUUID,
            "a reconciled contact lists under its minted GuessWho UUID")
        let expectedFreshID = await MainActor.run { Fixture.freshFace().deterministicGuessWhoID }
        XCTAssertEqual(
            page.items.first(where: { $0.name == "Fresh Face" })?.id,
            expectedFreshID,
            "a never-written contact lists under its deterministic pre-mint id")
    }

    func testTypeFilterSelectsOnlyThatKind() async {
        let fixture = await Fixture.make()
        guard let people = await listPage(fixture, type: "person") else { return }
        XCTAssertEqual(people.items.map(\.name), ["Fresh Face", "Jane Doe"])
        XCTAssertTrue(people.items.allSatisfy { $0.kind == "person" })

        // Tolerant argument parsing, same stance as the links kind values.
        guard let organizations = await listPage(fixture, type: " Organization ") else { return }
        XCTAssertEqual(organizations.items.map(\.name), ["Doe Industries"])
        XCTAssertTrue(organizations.items.allSatisfy { $0.kind == "organization" })
    }

    func testInvalidTypeArgumentRejected() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m",
            type: "company", limit: nil, cursor: nil))
        expectError(response, code: .invalidParams)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.invalidTypeArgument)
    }

    /// Reads never mint: listing the whole book — filters included — leaves
    /// every never-written contact identity-free and performs zero mints.
    func testListNeverMints() async {
        let fixture = await Fixture.make()
        _ = await fullWalk(fixture)
        _ = await fullWalk(fixture, type: "person")
        _ = await fullWalk(fixture, type: "organization")
        let (mintCount, identityURLCount) = await MainActor.run {
            (
                fixture.contacts.mintCount,
                fixture.contacts.contacts
                    .flatMap(\.urlAddresses)
                    .filter { $0.value.hasPrefix("guesswho://") }
                    .count
            )
        }
        XCTAssertEqual(mintCount, 0, "a list read must never mint an identity")
        XCTAssertEqual(identityURLCount, 1, "only the fixture's pre-existing identity URL exists")
    }

    // MARK: - Pagination correctness

    private static func pagerContacts(_ count: Int) -> [Contact] {
        (0..<count).map { index in
            Contact(
                localID: "ABPerson-LOCAL-PAGE-\(index)",
                givenName: String(format: "Person%02d", index),
                familyName: "Pager")
        }
    }

    func testPaginationCoversEveryContactExactlyOnce() async {
        let fixture = await Fixture.make()
        let expected = await MainActor.run { () -> [String] in
            let book = Self.pagerContacts(25)
            fixture.contacts.contacts = book
            return book.map(\.deterministicGuessWhoID)
        }
        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            guard let page = await listPage(fixture, limit: 10, cursor: cursor) else { return }
            XCTAssertLessThanOrEqual(page.items.count, 10)
            seen.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(seen.count, 25)
        XCTAssertEqual(Set(seen).count, 25, "pages must not overlap")
        XCTAssertEqual(Set(seen), Set(expected), "every contact appears exactly once")
    }

    /// The stable-sort property: the paged sequence is a function of the
    /// contact SET, not of the source array's incidental order — reordering
    /// the book between calls yields the identical sequence.
    func testOrderIsStableAcrossCallsAndSourceOrder() async {
        let fixture = await Fixture.make()
        await MainActor.run { fixture.contacts.contacts = Self.pagerContacts(25).shuffled() }
        let first = await fullWalk(fixture, limit: 7)
        await MainActor.run { fixture.contacts.contacts.reverse() }
        let second = await fullWalk(fixture, limit: 7)
        XCTAssertEqual(first, second, "the paged order must not depend on the source order")
        XCTAssertEqual(first.count, 25)
    }

    /// A cursor taken before the source array reorders still resumes the
    /// SAME sequence — no contact is skipped or repeated. (Contacts
    /// changing between pages is accepted best-effort; the same contact
    /// set must page consistently.)
    func testCursorResumesAfterSourceReorderWithoutSkipsOrDuplicates() async {
        let fixture = await Fixture.make()
        let expected = await MainActor.run { () -> Set<String> in
            let book = Self.pagerContacts(25)
            fixture.contacts.contacts = book
            return Set(book.map(\.deterministicGuessWhoID))
        }
        guard let firstPage = await listPage(fixture, limit: 10) else { return }
        var seen = firstPage.items.map(\.id)
        var cursor = firstPage.nextCursor
        XCTAssertNotNil(cursor)

        await MainActor.run { fixture.contacts.contacts.reverse() }

        var pages = 1
        while let next = cursor, pages < 10 {
            guard let page = await listPage(fixture, limit: 10, cursor: next) else { return }
            seen.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            pages += 1
        }
        XCTAssertEqual(seen.count, 25, "no skips")
        XCTAssertEqual(Set(seen).count, 25, "no duplicates")
        XCTAssertEqual(Set(seen), expected)
    }

    /// Contacts sharing one display name page without swapping: the wire id
    /// breaks the tie, making the order total.
    func testTiedDisplayNamesPageWithoutSwaps() async {
        let fixture = await Fixture.make()
        let expected = await MainActor.run { () -> [String] in
            let book = (0..<6).map { index in
                Contact(
                    localID: "ABPerson-LOCAL-TIED-\(index)",
                    givenName: "Alex", familyName: "Same")
            }
            fixture.contacts.contacts = book
            return book.map(\.deterministicGuessWhoID).sorted()
        }
        let seen = await fullWalk(fixture, limit: 1)
        XCTAssertEqual(seen, expected, "equal names must order by id, ascending")
    }

    func testInvalidCursorRejected() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m",
            type: nil, limit: nil, cursor: "made-up"))
        expectError(response, code: .invalidParams)
    }

    /// The shared response-size cap: an oversize page is the typed tooLarge
    /// error (never a silent truncation), and a smaller limit gets the data.
    func testOversizePageReturnsTypedTooLargeAndSmallerLimitSucceeds() async {
        let fixture = await Fixture.make()
        let bigOrganization = String(repeating: "Very Long Organization Name ", count: 80) // ~2.2KB
        await MainActor.run {
            fixture.contacts.contacts = (0..<210).map { index in
                Contact(
                    localID: "ABPerson-LOCAL-BIG-\(index)",
                    givenName: String(format: "Big%03d", index),
                    familyName: "Page",
                    organizationName: bigOrganization)
            }
        }
        let oversize = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m",
            type: nil, limit: 200, cursor: nil))
        expectError(oversize, code: .tooLarge)

        guard let small = await listPage(fixture, limit: 5) else { return }
        XCTAssertEqual(small.items.count, 5)
        XCTAssertNotNil(small.nextCursor)
    }

    // MARK: - Gates

    /// Read tool gating: off rejects, missing Contacts permission rejects
    /// (and hides from listTools), read-only allows.
    func testGatedLikeEveryContactRead() async {
        let fixture = await Fixture.make()

        // Default fixture mode is read-only: the read passes.
        guard let page = await listPage(fixture) else { return }
        XCTAssertFalse(page.items.isEmpty)

        await MainActor.run { fixture.gates.contactsAuthorized = false }
        expectError(await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m1",
            type: nil, limit: nil, cursor: nil)),
            code: .permissionDenied)
        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m2"))
        if case .toolList(_, _, let tools, _) = list {
            XCTAssertFalse(tools.map(\.name).contains(MCPTool.contactsList.rawValue))
        } else {
            XCTFail("expected toolList")
        }

        await MainActor.run {
            fixture.gates.contactsAuthorized = true
            fixture.gates.mcpAccess = .off
        }
        expectError(await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m3",
            type: nil, limit: nil, cursor: nil)),
            code: .disabled)
    }

    // MARK: - Exclusions

    /// The four Revision 2 exclusions hold on the list surface: no Apple
    /// note, no Apple local id, no device id, no identity-URL form — while
    /// the GuessWho UUID rides as the contact id.
    func testExclusionSentinelsAbsentFromListOutput() async {
        let fixture = await Fixture.make()
        var responses: [WireResponse] = []
        for type in [nil, "person", "organization", "bogus-type"] {
            if let response = await fixture.dispatcher.handle(.contactsList(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                type: type, limit: nil, cursor: nil)) {
                responses.append(response)
            }
        }
        let output = responses.map { $0.agentVisibleText + "\n" + $0.wireJSON }
            .joined(separator: "\n")
        XCTAssertFalse(output.contains(Sentinels.appleNote), "Apple note leaked")
        XCTAssertFalse(output.contains("ABPerson-LOCAL"), "Apple local id leaked")
        XCTAssertFalse(output.contains(Sentinels.deviceID), "modifiedBy device id leaked")
        XCTAssertFalse(output.contains("modifiedBy"), "modifiedBy key leaked")
        XCTAssertFalse(output.contains("guesswho://"), "identity URL form leaked")
        XCTAssertTrue(
            output.contains(Sentinels.guessWhoUUID),
            "the GuessWho UUID IS the contact id and should appear as one")
    }
}
