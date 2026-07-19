import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The single-entry list tools (plans/cli-mcp.md Phase 7): add appends ONE
/// entry, remove/edit change exactly the ONE entry whose value exactly
/// matches, a 0-match answers typed notFound, duplicate exact values
/// answer typed ambiguous, and NOTHING is ever changed on either failure.
/// Everything runs through the dispatcher's real match/apply/save logic
/// over the same editableContact/saveContact funnel contacts_update uses —
/// the fake stays at the record-book (TCC) boundary only.
final class MultiValueEditToolTests: XCTestCase {

    private func expectError(
        _ response: WireResponse?, code: WireErrorCode, message: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let payload = response?.errorPayload else {
            return XCTFail(
                "expected \(code) error, got \(String(describing: response))",
                file: file, line: line)
        }
        XCTAssertEqual(payload.code, code, file: file, line: line)
        if let message {
            XCTAssertEqual(payload.message, message, file: file, line: line)
        }
    }

    private func expectCard(
        _ response: WireResponse?,
        file: StaticString = #filePath, line: UInt = #line
    ) -> WireContact? {
        guard case .contact(_, _, let card) = response else {
            XCTFail(
                "expected the updated card, got \(String(describing: response))",
                file: file, line: line)
            return nil
        }
        return card
    }

    private func writableFixture(
        writeLimitPerWindow: Int = 30
    ) async -> Fixture {
        let fixture = await Fixture.make(writeLimitPerWindow: writeLimitPerWindow)
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        return fixture
    }

    private func janeID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.name == "Jane Doe" })?.id
    }

    private func storedJane(_ fixture: Fixture) async -> Contact? {
        await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Jane Doe" }
        }
    }

    private func mutateJane(_ fixture: Fixture, _ mutate: @escaping (inout Contact) -> Void) async {
        await MainActor.run {
            guard let index = fixture.contacts.contacts.firstIndex(where: {
                $0.displayName == "Jane Doe"
            }) else { return }
            var jane = fixture.contacts.contacts[index]
            mutate(&jane)
            fixture.contacts.contacts[index] = jane
        }
    }

    // MARK: - Add appends one, everything else untouched

    func testAddPhoneAppendsOneAndLeavesEverythingElseUntouched() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await storedJane(fixture)

        let response = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 0200", label: "work", idempotencyToken: nil))
        guard let card = expectCard(response) else { return }
        XCTAssertEqual(card.phoneNumbers.map(\.value), ["+1 (555) 010-7788", "+1 555 0200"])
        XCTAssertEqual(card.phoneNumbers.map(\.label), ["mobile", "work"])

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.map(\.value), ["+1 (555) 010-7788", "+1 555 0200"])
        // Everything the call didn't name is byte-identical — the Apple
        // note above all.
        XCTAssertEqual(after?.note, Sentinels.appleNote)
        XCTAssertEqual(after?.emailAddresses.map(\.value), before?.emailAddresses.map(\.value))
        XCTAssertEqual(after?.urlAddresses.map(\.value), before?.urlAddresses.map(\.value))
        XCTAssertEqual(after?.jobTitle, before?.jobTitle)
    }

    func testAddEmailWithoutLabelDefaultsToEmptyLabel() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let response = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", value: "jane@home.example", label: nil, idempotencyToken: nil))
        guard expectCard(response) != nil else { return }
        let after = await storedJane(fixture)
        XCTAssertEqual(
            after?.emailAddresses.map(\.value), ["jane@doe.example", "jane@home.example"])
        XCTAssertEqual(after?.emailAddresses.last?.label, "")
    }

    // MARK: - Remove takes exactly the matched entry

    func testRemovePhoneRemovesExactlyTheMatchedOne() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) {
            $0.phoneNumbers.append(LabeledValue(label: "work", value: "+1 555 0300"))
        }

        let response = await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 (555) 010-7788", idempotencyToken: nil))
        guard let card = expectCard(response) else { return }
        XCTAssertEqual(card.phoneNumbers.map(\.value), ["+1 555 0300"])
        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.map(\.value), ["+1 555 0300"])
        XCTAssertEqual(after?.note, Sentinels.appleNote)
    }

    /// The symmetric round trip: a tool-added entry, removed by its exact
    /// value, leaves the list exactly as it started — the original entry
    /// untouched down to its label.
    func testAddThenRemoveEmailRestoresTheOriginalList() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await storedJane(fixture)

        let added = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", value: "jane@temp.example", label: "temp", idempotencyToken: nil))
        guard let addedCard = expectCard(added) else { return }
        XCTAssertEqual(
            addedCard.emailAddresses.map(\.value), ["jane@doe.example", "jane@temp.example"])

        let removed = await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", value: "jane@temp.example", idempotencyToken: nil))
        guard let removedCard = expectCard(removed) else { return }
        XCTAssertEqual(removedCard.emailAddresses.map(\.value), ["jane@doe.example"])

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.emailAddresses.map(\.value), before?.emailAddresses.map(\.value))
        XCTAssertEqual(after?.emailAddresses.map(\.label), before?.emailAddresses.map(\.label))
        XCTAssertEqual(after?.note, Sentinels.appleNote)
    }

    // MARK: - Edit replaces value (and label) in place

    func testEditEmailReplacesValueAndLabelInPlace() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) {
            $0.emailAddresses.append(LabeledValue(label: "home", value: "jane@home.example"))
        }

        let response = await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", currentValue: "jane@doe.example",
            newValue: "jane@newdoe.example", newLabel: "personal", idempotencyToken: nil))
        guard let card = expectCard(response) else { return }
        // In place: position 0 keeps position 0; the neighbor is untouched.
        XCTAssertEqual(card.emailAddresses.map(\.value), ["jane@newdoe.example", "jane@home.example"])
        XCTAssertEqual(card.emailAddresses.map(\.label), ["personal", "home"])
    }

    func testEditPhoneKeepsTheLabelWhenNoNewLabelIsGiven() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let response = await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", currentValue: "+1 (555) 010-7788",
            newValue: "+1 555 0400", newLabel: nil, idempotencyToken: nil))
        guard let card = expectCard(response) else { return }
        XCTAssertEqual(card.phoneNumbers.map(\.value), ["+1 555 0400"])
        XCTAssertEqual(card.phoneNumbers.map(\.label), ["mobile"])
    }

    // MARK: - 0 matches: typed notFound, nothing changed

    func testZeroMatchIsTypedNotFoundForEveryListAndChangesNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) {
            $0.contactRelations = [
                LabeledContactRelation(label: "mother", value: ContactRelation(name: "Ann Doe"))
            ]
            $0.dates = [LabeledDate(label: "anniversary", value: DateComponents(month: 12, day: 25))]
        }
        let before = await storedJane(fixture)

        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 9999", idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noPhoneWithThatValue)
        expectError(await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", currentValue: "nobody@nowhere.example",
            newValue: "still@nowhere.example", newLabel: nil, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noEmailWithThatValue)
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "url", value: "https://nope.example", idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noURLWithThatValue)
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "related_name", value: "Nobody Doe", idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noRelatedNameWithThatValue)
        // A year-qualified date does NOT match a stored year-less date —
        // they are different values, so this is a 0-match.
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "1990-12-25", idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noDateWithThatValue)

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.map(\.value), before?.phoneNumbers.map(\.value))
        XCTAssertEqual(after?.emailAddresses.map(\.value), before?.emailAddresses.map(\.value))
        XCTAssertEqual(after?.urlAddresses.map(\.value), before?.urlAddresses.map(\.value))
        XCTAssertEqual(after?.contactRelations.count, 1)
        XCTAssertEqual(after?.dates.count, 1)
    }

    // MARK: - Duplicate exact values: typed ambiguous, nothing changed

    func testDuplicateExactValuesAreTypedAmbiguousAndChangeNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        // Two entries per list with the SAME value (labels differ — value
        // matching alone cannot tell them apart, and the wire must never
        // guess).
        await mutateJane(fixture) {
            $0.phoneNumbers.append(LabeledValue(label: "work", value: "+1 (555) 010-7788"))
            $0.emailAddresses.append(LabeledValue(label: "home", value: "jane@doe.example"))
            $0.urlAddresses.append(LabeledValue(label: "mirror", value: "https://janedoe.example"))
            $0.contactRelations = [
                LabeledContactRelation(label: "mother", value: ContactRelation(name: "Ann Doe")),
                LabeledContactRelation(label: "manager", value: ContactRelation(name: "Ann Doe")),
            ]
            $0.dates = [
                LabeledDate(label: "anniversary", value: DateComponents(month: 12, day: 25)),
                LabeledDate(label: "first met", value: DateComponents(month: 12, day: 25)),
            ]
        }
        let before = await storedJane(fixture)

        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 (555) 010-7788", idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousPhoneValue)
        expectError(await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", currentValue: "jane@doe.example",
            newValue: "other@doe.example", newLabel: nil, idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousEmailValue)
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "url", value: "https://janedoe.example", idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousURLValue)
        expectError(await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "related_name", currentValue: "Ann Doe",
            newValue: "Ann B. Doe", newLabel: nil, idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousRelatedNameValue)
        // The two stored spellings render to the same canonical date, so
        // any spelling of the needle hits both.
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "--12-25", idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousDateValue)

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.map(\.value), before?.phoneNumbers.map(\.value))
        XCTAssertEqual(after?.emailAddresses.map(\.value), before?.emailAddresses.map(\.value))
        XCTAssertEqual(after?.urlAddresses.map(\.value), before?.urlAddresses.map(\.value))
        XCTAssertEqual(after?.contactRelations.map(\.value.name), ["Ann Doe", "Ann Doe"])
        XCTAssertEqual(after?.dates.count, 2)
        XCTAssertEqual(after?.note, Sentinels.appleNote)
    }

    // MARK: - Web addresses: the identity URL is untouchable

    func testURLEditsRideTheVisibleListAndNeverTouchTheIdentityURL() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let identity = "guesswho://contact/\(Sentinels.guessWhoUUID)"

        let added = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "url", value: "https://blog.janedoe.example", label: "blog",
            idempotencyToken: nil))
        guard let addedCard = expectCard(added) else { return }
        XCTAssertEqual(
            addedCard.urlAddresses.map(\.value),
            ["https://janedoe.example", "https://blog.janedoe.example"])

        let edited = await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "url", currentValue: "https://janedoe.example",
            newValue: "https://jane.example/work", newLabel: "portfolio", idempotencyToken: nil))
        guard let editedCard = expectCard(edited) else { return }
        XCTAssertEqual(
            editedCard.urlAddresses.map(\.value),
            ["https://jane.example/work", "https://blog.janedoe.example"])
        XCTAssertEqual(editedCard.urlAddresses.first?.label, "portfolio")

        let removed = await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "url", value: "https://jane.example/work", idempotencyToken: nil))
        guard let removedCard = expectCard(removed) else { return }
        XCTAssertEqual(removedCard.urlAddresses.map(\.value), ["https://blog.janedoe.example"])

        // The identity URL is structurally unmatchable: naming it exactly
        // is a 0-match (it isn't on the visible card), and after every
        // operation above it still holds its slot verbatim.
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "url", value: identity, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noURLWithThatValue)
        let after = await storedJane(fixture)
        XCTAssertEqual(
            after?.urlAddresses.filter { $0.value.hasPrefix("guesswho://") }.map(\.value),
            [identity])

        // And no echo along the way leaked the identity URL form.
        for response in [added, edited, removed] {
            let text = (response?.agentVisibleText ?? "") + (response?.wireJSON ?? "")
            XCTAssertFalse(text.contains("guesswho://"), "identity URL form leaked")
        }
    }

    // MARK: - Dates: canonical matching across spellings

    func testDateEditsMatchCanonicallyAcrossSpellings() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }

        let addYearless = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "--12-25", label: "stockings", idempotencyToken: nil))
        guard let card1 = expectCard(addYearless) else { return }
        XCTAssertEqual(card1.dates.map(\.date), ["--12-25"])
        XCTAssertEqual(card1.dates.first?.label, "stockings")

        let addFull = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "1990-04-02", label: "anniversary", idempotencyToken: nil))
        guard let card2 = expectCard(addFull) else { return }
        XCTAssertEqual(card2.dates.map(\.date), ["--12-25", "1990-04-02"])

        // The stored entry was minted from the wire spelling; matching goes
        // through the same canonical rendering, so the read-back value
        // matches verbatim and the year-qualified entry is the only hit.
        let edited = await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", currentValue: "1990-04-02",
            newValue: "1991-04-02", newLabel: nil, idempotencyToken: nil))
        guard let card3 = expectCard(edited) else { return }
        XCTAssertEqual(card3.dates.map(\.date), ["--12-25", "1991-04-02"])
        XCTAssertEqual(card3.dates.last?.label, "anniversary", "no newLabel keeps the label")

        let removed = await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "--12-25", idempotencyToken: nil))
        guard let card4 = expectCard(removed) else { return }
        XCTAssertEqual(card4.dates.map(\.date), ["1991-04-02"])

        // The contact's birthday is a contacts_update scalar, not a listed
        // date — untouched throughout.
        let after = await storedJane(fixture)
        XCTAssertEqual(after?.birthday, DateComponents(year: 1984, month: 3, day: 14))
    }

    func testUnparseableDateValueIsTypedInvalidParams() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "12/25/1990", label: nil, idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.invalidCalendarDateValue)
        // An unparseable MATCH value is a spelling problem, not a missing
        // entry — invalidParams, never a misleading notFound.
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "date", value: "christmas", idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.invalidCalendarDateValue)
    }

    // MARK: - Related names

    func testRelatedNameAddEditRemoveRoundTrip() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }

        let added = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "related_name", value: "Ann Doe", label: "mother", idempotencyToken: nil))
        guard let card1 = expectCard(added) else { return }
        XCTAssertEqual(card1.relatedNames.map(\.value), ["Ann Doe"])
        XCTAssertEqual(card1.relatedNames.first?.label, "mother")

        let edited = await fixture.dispatcher.handle(.contactsEditValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "related_name", currentValue: "Ann Doe",
            newValue: "Ann B. Doe", newLabel: nil, idempotencyToken: nil))
        guard let card2 = expectCard(edited) else { return }
        XCTAssertEqual(card2.relatedNames.map(\.value), ["Ann B. Doe"])
        XCTAssertEqual(card2.relatedNames.first?.label, "mother")

        let removed = await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "related_name", value: "Ann B. Doe", idempotencyToken: nil))
        guard let card3 = expectCard(removed) else { return }
        XCTAssertEqual(card3.relatedNames, [])
    }

    // MARK: - Argument validation

    func testWhitespaceOnlyValueIsTypedInvalidParams() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "   ", label: nil, idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.emptyValueArgument)
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", value: " ", idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.emptyValueArgument)
    }

    func testUnknownContactIsNotFound() async {
        let fixture = await writableFixture()
        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: "bogus-id", field: "phone", value: "+1 555 0100", label: nil, idempotencyToken: nil)),
            code: .notFound)
    }

    func testInvalidFieldIsTypedInvalidParamsAndChangesNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await storedJane(fixture)

        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "birthday", value: "--03-14",
            label: nil, idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.invalidContactListField)

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers, before?.phoneNumbers)
        XCTAssertEqual(after?.emailAddresses, before?.emailAddresses)
        XCTAssertEqual(after?.urlAddresses, before?.urlAddresses)
        XCTAssertEqual(after?.dates, before?.dates)
        XCTAssertEqual(after?.birthday, before?.birthday)
    }

    // MARK: - Gates, budget surface, idempotency, failure mapping

    func testListEditsRejectedPerCallUnderReadOnlyAndHiddenFromListTools() async {
        let fixture = await Fixture.make() // read-only: the shipping default
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }

        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, _) = list else { return XCTFail("expected toolList") }
        let names = Set(tools.map(\.name))
        for tool in [MCPTool.contactsAddValue, .contactsDeleteValue, .contactsEditValue] {
            XCTAssertFalse(names.contains(tool.rawValue), "\(tool.rawValue) visible under read-only")
        }

        let before = await storedJane(fixture)
        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 0500", label: nil, idempotencyToken: nil)),
            code: .readOnly)
        expectError(await fixture.dispatcher.handle(.contactsDeleteValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "email", value: "jane@doe.example", idempotencyToken: nil)),
            code: .readOnly)
        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.map(\.value), before?.phoneNumbers.map(\.value))
        XCTAssertEqual(after?.emailAddresses.map(\.value), before?.emailAddresses.map(\.value))
    }

    func testAllListToolsListedUnderReadWrite() async {
        let fixture = await writableFixture()
        let list = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, _) = list else { return XCTFail("expected toolList") }
        let names = Set(tools.map(\.name))
        for tool in [MCPTool.contactsAddValue, .contactsDeleteValue, .contactsEditValue] {
            XCTAssertTrue(names.contains(tool.rawValue), "\(tool.rawValue) missing under read-write")
        }
    }

    func testRetriedAddWithSameIdempotencyTokenDoesNotDuplicate() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }

        let first = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: "add-email-1",
            contactId: jane, field: "email", value: "jane@once.example", label: nil,
            idempotencyToken: "tok-add-email"))
        guard let firstCard = expectCard(first) else { return }
        let retry = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: "add-email-2",
            contactId: jane, field: "email", value: "jane@once.example", label: nil,
            idempotencyToken: "tok-add-email"))
        guard let replayed = expectCard(retry) else { return }
        XCTAssertEqual(replayed.emailAddresses.map(\.value), firstCard.emailAddresses.map(\.value))

        let after = await storedJane(fixture)
        XCTAssertEqual(
            after?.emailAddresses.filter { $0.value == "jane@once.example" }.count, 1,
            "a retried add must not append the entry twice")
    }

    /// Concurrent single-entry edits to the SAME contact's SAME list are a
    /// read-modify-write race: two writers that both read the pre-edit
    /// card would each save a list missing the other's entry, silently
    /// losing one. The per-localID single-flight the list-edit path holds
    /// (the same withWriteKeysLocked every contact write uses) serializes
    /// the whole editableContact→mutate→saveContact sequence, so EVERY
    /// concurrent add must land. Regression guard: this fails (flakily,
    /// by losing entries) if the list-edit path ever stops taking the
    /// lock.
    func testConcurrentAddsToTheSameListAreSerializedAndLoseNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }

        let values = ["+1 555 1001", "+1 555 1002", "+1 555 1003", "+1 555 1004"]
        let responses = await withTaskGroup(of: WireResponse?.self) { group in
            for value in values {
                group.addTask {
                    await fixture.dispatcher.handle(.contactsAddValue(
                        helperId: Fixture.helper, messageId: TestMessageID.next(),
                        contactId: jane, field: "phone", value: value, label: nil, idempotencyToken: nil))
                }
            }
            var collected: [WireResponse?] = []
            for await response in group { collected.append(response) }
            return collected
        }
        for response in responses {
            XCTAssertNotNil(expectCard(response), "every concurrent add must report success")
        }

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.count, 5, "a lost entry means the write ran unserialized")
        XCTAssertEqual(
            Set(after?.phoneNumbers.map(\.value) ?? []),
            Set(["+1 (555) 010-7788"] + values))
        XCTAssertEqual(after?.note, Sentinels.appleNote)
    }

    func testListEditsCountAgainstTheWriteBudget() async {
        let fixture = await writableFixture(writeLimitPerWindow: 1)
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let first = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 0600", label: nil, idempotencyToken: nil))
        XCTAssertNotNil(expectCard(first))
        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 0601", label: nil, idempotencyToken: nil)),
            code: .busy, message: WireErrorMessage.writeBusy)
    }

    func testStoreRejectedListEditSurfacesTypedWriteFailedAndChangesNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await MainActor.run {
            fixture.contacts.nextContactStoreError = NSError(
                domain: "NSCocoaErrorDomain", code: 134092,
                userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed."])
        }
        expectError(await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 0700", label: nil, idempotencyToken: nil)),
            code: .writeFailed, message: WireErrorMessage.writeFailed)
        let after = await storedJane(fixture)
        XCTAssertEqual(after?.phoneNumbers.map(\.value), ["+1 (555) 010-7788"],
                       "a rejected save must not claim success")
    }

    func testAgentListEditAppearsInAuditLog() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        _ = await fixture.dispatcher.handle(.contactsAddValue(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, field: "phone", value: "+1 555 0800", label: nil, idempotencyToken: nil))
        let entries = await fixture.audit.entries()
        XCTAssertTrue(entries.contains {
            $0.action == .editContact && $0.subjectName == "Jane Doe"
                && $0.newValue == "phoneNumbers"
        })
    }
}
