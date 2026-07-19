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
        _ fixture: Fixture, kind: String? = nil, favoritesOnly: Bool? = nil,
        groupId: String? = nil, limit: Int? = nil, cursor: String? = nil
    ) async -> WirePage<WireContactSummary>? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: kind, favoritesOnly: favoritesOnly, groupId: groupId,
            limit: limit, cursor: cursor))
        guard case .contactPage(_, _, let page) = response else {
            XCTFail("expected a contact page; got \(String(describing: response))")
            return nil
        }
        return page
    }

    /// Every id in cursor order for the given filter — a full paged walk.
    private func fullWalk(
        _ fixture: Fixture, kind: String? = nil, favoritesOnly: Bool? = nil,
        groupId: String? = nil, limit: Int? = nil
    ) async -> [String] {
        var ids: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            guard let page = await listPage(
                fixture, kind: kind, favoritesOnly: favoritesOnly,
                groupId: groupId, limit: limit, cursor: cursor)
            else {
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

    func testKindFilterSelectsOnlyThatKind() async {
        let fixture = await Fixture.make()
        guard let people = await listPage(fixture, kind: "person") else { return }
        XCTAssertEqual(people.items.map(\.name), ["Fresh Face", "Jane Doe"])
        XCTAssertTrue(people.items.allSatisfy { $0.kind == "person" })

        // Tolerant argument parsing, same stance as the links kind values.
        guard let organizations = await listPage(fixture, kind: " Organization ") else { return }
        XCTAssertEqual(organizations.items.map(\.name), ["Doe Industries"])
        XCTAssertTrue(organizations.items.allSatisfy { $0.kind == "organization" })
    }

    func testInvalidKindArgumentRejected() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m",
            kind: "company", favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil))
        expectError(response, code: .invalidParams)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.invalidKindFilterArgument)
    }

    /// Reads never mint: listing the whole book — filters included — leaves
    /// every never-written contact identity-free and performs zero mints.
    func testListNeverMints() async {
        let fixture = await Fixture.make()
        _ = await fullWalk(fixture)
        _ = await fullWalk(fixture, kind: "person")
        _ = await fullWalk(fixture, kind: "organization")
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
            kind: nil, favoritesOnly: nil, groupId: nil, limit: nil, cursor: "made-up"))
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
            kind: nil, favoritesOnly: nil, groupId: nil, limit: 200, cursor: nil))
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
            kind: nil, favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil)),
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
            kind: nil, favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil)),
            code: .disabled)
    }

    // MARK: - Exclusions

    /// The four Revision 2 exclusions hold on the list surface: no Apple
    /// note, no Apple local id, no device id, no identity-URL form — while
    /// the GuessWho UUID rides as the contact id.
    func testExclusionSentinelsAbsentFromListOutput() async {
        let fixture = await Fixture.make()
        var responses: [WireResponse] = []
        for kind in [nil, "person", "organization", "bogus-type"] {
            if let response = await fixture.dispatcher.handle(.contactsList(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                kind: kind, favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil)) {
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

    // MARK: - Favorites filter (folded from the retired favorites tool)

    /// The single wire id of the fixture's one group ("Museum Friends"), as
    /// an agent would obtain it from contacts_list_groups.
    private func onlyGroupID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: Fixture.helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        guard case .groupPage(_, _, let page) = response else {
            XCTFail("expected a group page; got \(String(describing: response))")
            return nil
        }
        return page.items.first?.id
    }

    /// favoritesOnly:true returns only the favorites; false and omitted both
    /// return every contact. The default fixture favorites exactly Jane Doe.
    func testFavoritesOnlyFiltersToFavorites() async {
        let fixture = await Fixture.make()

        guard let favorites = await listPage(fixture, favoritesOnly: true) else { return }
        XCTAssertEqual(favorites.items.map(\.name), ["Jane Doe"],
                       "favoritesOnly:true returns only the marked favorite")
        XCTAssertEqual(favorites.items.first?.id, Sentinels.guessWhoUUID)

        guard let unfilteredFalse = await listPage(fixture, favoritesOnly: false) else { return }
        XCTAssertEqual(unfilteredFalse.items.map(\.name),
                       ["Doe Industries", "Fresh Face", "Jane Doe"],
                       "favoritesOnly:false lists everyone, same as omitting it")
        guard let unfilteredNil = await listPage(fixture, favoritesOnly: nil) else { return }
        XCTAssertEqual(unfilteredFalse.items.map(\.id), unfilteredNil.items.map(\.id))
    }

    /// The folded favorites path inherits the deterministic (name, id) sort
    /// the standalone favorites read never had — favorites page in stable
    /// order regardless of the source array's order, tie-broken by id.
    func testFavoritesPathIsDeterministicallySorted() async {
        let fixture = await Fixture.make()
        let expected = await MainActor.run { () -> [String] in
            let book = (0..<8).map { index in
                Contact(
                    localID: "ABPerson-LOCAL-FAV-\(index)",
                    givenName: "Alex", familyName: "Same")
            }
            fixture.contacts.contacts = book
            // Every one of them is a favorite (effectiveID == localID pre-mint).
            fixture.contacts.favoriteEffectiveIDs = Set(book.map(\.contactID.restorationToken.localID))
            return book.map(\.deterministicGuessWhoID).sorted()
        }
        let first = await fullWalk(fixture, favoritesOnly: true, limit: 3)
        await MainActor.run { fixture.contacts.contacts.reverse() }
        let second = await fullWalk(fixture, favoritesOnly: true, limit: 3)
        XCTAssertEqual(first, expected, "tied names order by id, independent of source order")
        XCTAssertEqual(first, second, "the favorites paged order is stable across source reorder")
    }

    // MARK: - Group filter (folded from the retired group-members tool)

    /// groupId returns only that group's members. The fixture's one group
    /// holds exactly Jane Doe.
    func testGroupIdFiltersToGroupMembers() async {
        let fixture = await Fixture.make()
        guard let groupID = await onlyGroupID(fixture) else { return }
        guard let page = await listPage(fixture, groupId: groupID) else { return }
        XCTAssertEqual(page.items.map(\.name), ["Jane Doe"],
                       "only the group's member is returned")
        XCTAssertEqual(page.items.first?.id, Sentinels.guessWhoUUID)
    }

    /// A valid group that happens to have NO members returns an empty page —
    /// explicitly NOT a notFound. This pins the empty-valid-group vs
    /// bad-group distinction so a future regression can't collapse the two:
    /// the id resolves to a real group, so the members lookup runs and
    /// yields nothing, which is a legitimate (empty) result, not an error.
    func testValidGroupWithNoMembersReturnsEmptyPageNotNotFound() async {
        let fixture = await Fixture.make()
        // A real, resolvable group with no membership entry — the fake's
        // members(ofGroup:) returns [] for a group absent from membersByGroup.
        await MainActor.run {
            fixture.contacts.groups.append(
                ContactGroup(localID: "CNGroup-LOCAL-EMPTY", name: "Empty Group"))
        }
        // Take the empty group's wire id the way an agent would: from
        // contacts_list_groups, by name.
        let groupsResponse = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: Fixture.helper, messageId: TestMessageID.next(), limit: nil, cursor: nil))
        guard case .groupPage(_, _, let groups) = groupsResponse,
              let emptyGroupID = groups.items.first(where: { $0.name == "Empty Group" })?.id
        else {
            return XCTFail("expected the empty group in contacts_list_groups; got \(String(describing: groupsResponse))")
        }

        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m",
            kind: nil, favoritesOnly: nil, groupId: emptyGroupID, limit: nil, cursor: nil))
        // A valid-but-empty group is a contactPage, never an error.
        XCTAssertNil(response?.errorPayload,
                     "an empty valid group must not be a notFound / error")
        guard case .contactPage(_, _, let page) = response else {
            return XCTFail("expected an empty contact page; got \(String(describing: response))")
        }
        XCTAssertTrue(page.items.isEmpty, "the group has no members")
        XCTAssertNil(page.nextCursor, "an empty page has no next cursor")
    }

    /// A groupId that resolves to no group is a typed notFound — never a
    /// silently empty page (the behavior the retired group-members tool had).
    func testUnknownGroupIdIsNotFoundNotEmpty() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "m",
            kind: nil, favoritesOnly: nil, groupId: "group-that-does-not-exist",
            limit: nil, cursor: nil))
        expectError(response, code: .notFound)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.notFoundGroup)
    }

    // MARK: - AND-composition (the capability gain over the retired tools)

    /// favoritesOnly + kind intersect: only favorites of that kind survive.
    func testFavoritesAndKindCompose() async {
        let fixture = await Fixture.make()
        // Add a favorite organization alongside the favorite person (Jane).
        await MainActor.run {
            let org = Contact(
                localID: "ABPerson-LOCAL-FAV-ORG",
                contactType: .organization,
                organizationName: "Favored Org")
            fixture.contacts.contacts.append(org)
            fixture.contacts.favoriteEffectiveIDs.insert(org.contactID.restorationToken.localID)
        }
        // favorites ∩ person = just Jane; favorites ∩ organization = just the org.
        guard let favPeople = await listPage(fixture, kind: "person", favoritesOnly: true) else { return }
        XCTAssertEqual(favPeople.items.map(\.name), ["Jane Doe"])
        guard let favOrgs = await listPage(fixture, kind: "organization", favoritesOnly: true) else { return }
        XCTAssertEqual(favOrgs.items.map(\.name), ["Favored Org"])
    }

    /// groupId + favoritesOnly intersect: a group member that is not a
    /// favorite is filtered out even though it is in the group.
    func testGroupIdAndFavoritesCompose() async {
        let fixture = await Fixture.make()
        let groupID = await onlyGroupID(fixture)
        guard let groupID else { return }

        // The default group holds only Jane, who IS a favorite: group ∩
        // favorites = Jane.
        guard let both = await listPage(fixture, favoritesOnly: true, groupId: groupID) else { return }
        XCTAssertEqual(both.items.map(\.name), ["Jane Doe"])

        // Drop Jane from favorites: the same group+favorites query now
        // intersects to nothing, while the plain group query still finds her.
        await MainActor.run { fixture.contacts.favoriteEffectiveIDs = [] }
        guard let none = await listPage(fixture, favoritesOnly: true, groupId: groupID) else { return }
        XCTAssertTrue(none.items.isEmpty, "a non-favorite group member is filtered by favoritesOnly")
        guard let groupOnly = await listPage(fixture, groupId: groupID) else { return }
        XCTAssertEqual(groupOnly.items.map(\.name), ["Jane Doe"],
                       "the plain group filter still returns the member")
    }
}
