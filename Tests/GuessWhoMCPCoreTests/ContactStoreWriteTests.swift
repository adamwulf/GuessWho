import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The Revision 2 Contact Store write parity: contacts_create /
/// contacts_update patch semantics, the pass-through protections (Apple
/// note untouched, identity URLs preserved, no identity injection), the
/// typed failure mapping (incl. the documented 134092 save fragility), and
/// the user-confirmed contacts_delete.
final class ContactStoreWriteTests: XCTestCase {

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

    private func writableFixture() async -> Fixture {
        let fixture = await Fixture.make()
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

    // MARK: - Create

    func testCreateContactRoundTrip() async {
        let fixture = await writableFixture()
        var fields = WireContactFields()
        fields.givenName = "Nova"
        fields.familyName = "Chen"
        fields.jobTitle = "Archivist"
        fields.phoneNumbers = [WireLabeledValue(label: "mobile", value: "+1 555 0111")]
        fields.emailAddresses = [WireLabeledValue(label: "work", value: "nova@chen.example")]
        fields.birthday = "1990-04-02"

        let response = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: nil, fields: fields, idempotencyToken: nil))
        guard case .contact(_, _, let card) = response else {
            return XCTFail("expected the created card, got \(String(describing: response))")
        }
        XCTAssertEqual(card.name, "Nova Chen")
        XCTAssertEqual(card.kind, "person")
        XCTAssertEqual(card.jobTitle, "Archivist")
        XCTAssertEqual(card.phoneNumbers, [WireLabeledValue(label: "mobile", value: "+1 555 0111")])
        XCTAssertEqual(card.birthday, "1990-04-02")
        XCTAssertFalse(card.id.isEmpty)

        // The record exists in the live book, Apple note EMPTY (no wire
        // path ever writes one), and the returned id resolves back to it.
        let stored = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Nova Chen" }
        }
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.note, "")
        let fetched = await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: card.id))
        guard case .contact(_, _, let refetched) = fetched else {
            return XCTFail("the new contact's id should resolve")
        }
        XCTAssertEqual(refetched.name, "Nova Chen")
    }

    func testCreateOrganizationAndKindValidation() async {
        let fixture = await writableFixture()
        var fields = WireContactFields()
        fields.organization = "Chen Archives"
        let response = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: "organization", fields: fields, idempotencyToken: nil))
        guard case .contact(_, _, let card) = response else {
            return XCTFail("expected the created card")
        }
        XCTAssertEqual(card.kind, "organization")
        XCTAssertEqual(card.organization, "Chen Archives")

        let badKind = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: "robot", fields: fields, idempotencyToken: nil))
        expectError(badKind, code: .invalidParams)

        let empty = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: nil, fields: WireContactFields(), idempotencyToken: nil))
        expectError(empty, code: .invalidParams)
        XCTAssertEqual(empty?.errorPayload?.message, WireErrorMessage.contactNeedsAName)
    }

    func testCreateIsIdempotentUnderARetriedToken() async {
        let fixture = await writableFixture()
        var fields = WireContactFields()
        fields.givenName = "Once"
        fields.familyName = "Only"
        let first = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: "create-1",
            kind: nil, fields: fields, idempotencyToken: "tok-create"))
        guard case .contact(_, _, let card) = first else { return XCTFail("expected card") }
        let retry = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: "create-2",
            kind: nil, fields: fields, idempotencyToken: "tok-create"))
        guard case .contact(_, _, let replayed) = retry else { return XCTFail("expected replay") }
        XCTAssertEqual(replayed.id, card.id, "the replay must return the ORIGINAL contact")
        let count = await MainActor.run {
            fixture.contacts.contacts.filter { $0.displayName == "Once Only" }.count
        }
        XCTAssertEqual(count, 1, "a retried create must not duplicate the contact")
    }

    // MARK: - Update (patch semantics + pass-through protections)

    func testUpdatePatchesOnlyProvidedFieldsAndCarriesNoteAndIdentityThrough() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Jane Doe" }
        }

        var patch = WireContactFields()
        patch.jobTitle = "Director"
        patch.urlAddresses = [WireLabeledValue(label: "portfolio", value: "https://jane.example/work")]
        let response = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        guard case .contact(_, _, let card) = response else {
            return XCTFail("expected the updated card, got \(String(describing: response))")
        }
        XCTAssertEqual(card.jobTitle, "Director")
        XCTAssertEqual(card.urlAddresses.map(\.value), ["https://jane.example/work"])
        // Untouched fields survive the patch.
        XCTAssertEqual(card.name, "Jane Doe")
        XCTAssertEqual(card.phoneNumbers.map(\.value), before?.phoneNumbers.map(\.value))

        let after = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Jane Doe" }
        }
        // The Apple note rides through BYTE-IDENTICAL — the wire neither
        // read nor rewrote it.
        XCTAssertEqual(after?.note, Sentinels.appleNote)
        // The internal identity URL keeps its slot even though the wire
        // replaced the whole visible URL list.
        XCTAssertEqual(
            after?.urlAddresses.filter { $0.value.hasPrefix("guesswho://") }.map(\.value),
            ["guesswho://contact/\(Sentinels.guessWhoUUID)"])
        XCTAssertEqual(
            after?.urlAddresses.filter { !$0.value.hasPrefix("guesswho://") }.map(\.value),
            ["https://jane.example/work"])
    }

    func testUpdateClearsWithEmptyValuesAndRejectsEmptyPatch() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }

        var patch = WireContactFields()
        patch.jobTitle = ""
        patch.emailAddresses = []
        let response = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        guard case .contact(_, _, let card) = response else {
            return XCTFail("expected the updated card")
        }
        XCTAssertNil(card.jobTitle, "an empty string clears the field")
        XCTAssertEqual(card.emailAddresses, [], "an empty list clears the list")

        let empty = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: WireContactFields(), idempotencyToken: nil))
        expectError(empty, code: .invalidParams)
        XCTAssertEqual(empty?.errorPayload?.message, WireErrorMessage.updateNeedsAField)
    }

    /// An agent must not be able to plant (or spoof) the app's reserved
    /// address form through the writable URL list — create or update.
    func testReservedURLInjectionRejected() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        var patch = WireContactFields()
        patch.urlAddresses = [
            WireLabeledValue(label: nil, value: "guesswho://contact/11111111-2222-4333-8444-555555555555"),
        ]
        let update = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        expectError(update, code: .invalidParams)
        XCTAssertEqual(update?.errorPayload?.message, WireErrorMessage.reservedWebAddress)

        var createFields = WireContactFields()
        createFields.givenName = "Sneaky"
        createFields.urlAddresses = patch.urlAddresses
        let create = await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: nil, fields: createFields, idempotencyToken: nil))
        expectError(create, code: .invalidParams)

        // Jane's identity URL is untouched.
        let after = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Jane Doe" }
        }
        XCTAssertEqual(
            after?.urlAddresses.filter { $0.value.hasPrefix("guesswho://") }.map(\.value),
            ["guesswho://contact/\(Sentinels.guessWhoUUID)"])
    }

    /// The wire id is a lookup key, never a writable field: no update
    /// argument can change it, and the card's identity survives any patch.
    func testUpdateCannotChangeTheContactID() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        var patch = WireContactFields()
        patch.givenName = "Janet"
        let response = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        guard case .contact(_, _, let card) = response else {
            return XCTFail("expected the updated card")
        }
        XCTAssertEqual(card.id, jane, "a reconciled contact's id never changes on edit")
        XCTAssertEqual(card.givenName, "Janet")
    }

    // MARK: - Failure mapping (TCC + the 134092 family)

    func testStoreRejectedSaveSurfacesAsTypedWriteFailed() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await MainActor.run {
            fixture.contacts.nextContactStoreError = NSError(
                domain: "NSCocoaErrorDomain", code: 134092,
                userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed."])
        }
        var patch = WireContactFields()
        patch.jobTitle = "Never lands"
        let response = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        expectError(response, code: .writeFailed)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.writeFailed)
        let after = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Jane Doe" }?.jobTitle
        }
        XCTAssertEqual(after, "Curator", "a rejected save must not claim success")
    }

    func testRevokedContactsAccessSurfacesAsPermissionDenied() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await MainActor.run {
            fixture.contacts.nextContactStoreError = NSError(
                domain: "CNErrorDomain", code: 100, userInfo: [:])
        }
        var patch = WireContactFields()
        patch.jobTitle = "Denied"
        let response = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        expectError(response, code: .permissionDenied)
    }

    func testDeletedElsewhereSurfacesAsNotFound() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await MainActor.run {
            fixture.contacts.nextContactStoreError = NSError(
                domain: "CNErrorDomain", code: 200, userInfo: [:])
        }
        var patch = WireContactFields()
        patch.jobTitle = "Gone"
        let response = await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: patch, idempotencyToken: nil))
        expectError(response, code: .notFound)
    }

    // MARK: - Gates

    func testContactRecordWritesRejectedUnderReadOnly() async {
        let fixture = await Fixture.make() // read-only default
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        var fields = WireContactFields()
        fields.givenName = "Blocked"
        expectError(await fixture.dispatcher.handle(.contactsCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: nil, fields: fields, idempotencyToken: nil)),
            code: .readOnly)
        expectError(await fixture.dispatcher.handle(.contactsUpdate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, fields: fields, idempotencyToken: nil)),
            code: .readOnly)
        expectError(await fixture.dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, idempotencyToken: nil)),
            code: .readOnly)
        let names = await MainActor.run { fixture.contacts.contacts.map(\.displayName) }
        XCTAssertEqual(Set(names), ["Jane Doe", "Fresh Face", "Doe Industries"])
    }

    // MARK: - contacts_delete (confirmation-gated, fire-and-forget)

    private func deleteProbe(_ fixture: Fixture) async -> DeferredResponseProbe {
        let probe = DeferredResponseProbe()
        await fixture.dispatcher.setDeferredResponder { response in
            await probe.record(response)
        }
        return probe
    }

    func testDeleteProceedsOnlyOnUserApproval() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let probe = await deleteProbe(fixture)
        await MainActor.run { fixture.confirmations.decisions = [true] }

        let immediate = await fixture.dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-1",
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(immediate, "the request path answers out of band, never blocking on the human")

        guard let deferred = await probe.next() else {
            return XCTFail("expected the deferred delete response")
        }
        guard case .acknowledged(_, "del-1", let message) = deferred else {
            return XCTFail("expected an acknowledgement correlated to the request, got \(deferred)")
        }
        XCTAssertEqual(message, WireAckMessage.contactDeleted)

        let (names, prompted) = await MainActor.run {
            (fixture.contacts.contacts.map(\.displayName), fixture.confirmations.promptedNames)
        }
        XCTAssertFalse(names.contains("Jane Doe"), "the approved delete removes the contact")
        XCTAssertEqual(prompted, ["Jane Doe"], "the dialog names the SPECIFIC contact")

        let entries = await fixture.audit.entries()
        XCTAssertTrue(entries.contains { $0.action == .deleteContact && $0.subjectName == "Jane Doe" })
    }

    func testDeleteDeclinedIsANormalResultAndChangesNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let probe = await deleteProbe(fixture)
        await MainActor.run { fixture.confirmations.decisions = [false] }

        let immediate = await fixture.dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-2",
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(immediate)
        guard let deferred = await probe.next() else {
            return XCTFail("expected the deferred response")
        }
        // Declined is a NORMAL result (not an error), so the agent reads an
        // answer instead of retry-looping.
        XCTAssertNil(deferred.errorPayload)
        guard case .acknowledged(_, _, let message) = deferred else {
            return XCTFail("expected an acknowledgement")
        }
        XCTAssertEqual(message, WireAckMessage.contactDeleteDeclined)
        let names = await MainActor.run { fixture.contacts.contacts.map(\.displayName) }
        XCTAssertTrue(names.contains("Jane Doe"), "a declined delete changes nothing")
    }

    func testDeleteRefusedWhenNothingCanPresentTheConfirmation() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let probe = await deleteProbe(fixture)
        // decisions empty -> the fake reports "nothing to present on".
        let immediate = await fixture.dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-3",
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(immediate)
        guard let deferred = await probe.next() else {
            return XCTFail("expected the deferred response")
        }
        XCTAssertEqual(deferred.errorPayload?.code, .requiresAppAction)
        XCTAssertEqual(deferred.errorPayload?.message, WireErrorMessage.confirmationUnavailable)
        let names = await MainActor.run { fixture.contacts.contacts.map(\.displayName) }
        XCTAssertTrue(names.contains("Jane Doe"), "no dialog seen -> no delete, ever")
    }

    /// THE safety property of confirmation-gated deletes (the EssentialMCP
    /// gap that must never be inherited): an approval that arrives AFTER
    /// the caller's wait has expired performs NO delete and sends NO late
    /// success — "the agent saw a timeout" and "the delete fired" are
    /// mutually exclusive. Driven deterministically through the injected
    /// clock, with the REAL tool timeout and margin.
    func testConfirmationApprovedAfterAbandonmentDoesNotDelete() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let clock = MutableClock()
        let gate = SlowConfirmationSource()
        let probe = DeferredResponseProbe()
        let dispatcher = ToolDispatcher(
            contacts: fixture.contacts, events: fixture.events,
            guides: fixture.guides, links: fixture.links, gates: fixture.gates,
            confirmations: gate, audit: fixture.audit,
            now: { clock.now })
        await dispatcher.setDeferredResponder { response in
            await probe.record(response)
        }

        let immediate = await dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-late",
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(immediate, "the request answers out of band")

        // The human ponders past the caller's entire wait — the helper has
        // already reported a timeout to the agent — and only THEN clicks
        // Delete.
        clock.advance(by: MCPTool.contactsDelete.timeout + 1)
        await gate.release(with: true)

        guard let deferred = await probe.next() else {
            return XCTFail("expected the deferred response")
        }
        XCTAssertEqual(deferred.errorPayload?.code, .writeFailed)
        XCTAssertEqual(deferred.errorPayload?.message, WireErrorMessage.confirmationExpired)
        XCTAssertEqual(deferred.messageId, "del-late")

        // Nothing was deleted — the engine's delete path was never reached —
        // and no late success ever follows for the abandoned message id.
        let (names, engineDeletes) = await MainActor.run {
            (fixture.contacts.contacts.map(\.displayName),
             fixture.contacts.deletedContactLocalIDs)
        }
        XCTAssertTrue(names.contains("Jane Doe"), "an abandoned approval must never delete")
        XCTAssertTrue(engineDeletes.isEmpty, "the delete path must not be reached at all")
        let extra = await probe.next()
        XCTAssertNil(extra, "no further response may follow for the abandoned call")
        let entries = await fixture.audit.entries()
        XCTAssertFalse(entries.contains { $0.action == .deleteContact },
                       "an unperformed delete must not be audited as performed")
    }

    /// The margin edge: an approval just INSIDE the margin window (elapsed
    /// > timeout - margin, but < timeout) is already refused — the margin
    /// is what keeps the host's clock from disagreeing with the helper's.
    func testConfirmationApprovedInsideTheMarginWindowIsRefused() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let clock = MutableClock()
        let gate = SlowConfirmationSource()
        let probe = DeferredResponseProbe()
        let dispatcher = ToolDispatcher(
            contacts: fixture.contacts, events: fixture.events,
            guides: fixture.guides, links: fixture.links, gates: fixture.gates,
            confirmations: gate, audit: nil,
            now: { clock.now })
        await dispatcher.setDeferredResponder { response in
            await probe.record(response)
        }

        let immediate = await dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-margin",
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(immediate)

        clock.advance(
            by: MCPTool.contactsDelete.timeout
                - ToolDispatcher.confirmationTimeoutMargin + 1)
        await gate.release(with: true)

        guard let deferred = await probe.next() else {
            return XCTFail("expected the deferred response")
        }
        XCTAssertEqual(deferred.errorPayload?.message, WireErrorMessage.confirmationExpired)
        let names = await MainActor.run { fixture.contacts.contacts.map(\.displayName) }
        XCTAssertTrue(names.contains("Jane Doe"))
    }

    func testSecondDeleteWhileConfirmationPendingIsBusy() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let probe = await deleteProbe(fixture)

        // A confirmation source that blocks until released, so the first
        // request is genuinely pending when the second arrives.
        let gate = SlowConfirmationSource()
        let dispatcher = ToolDispatcher(
            contacts: fixture.contacts, events: fixture.events,
            guides: fixture.guides, links: fixture.links, gates: fixture.gates,
            confirmations: gate, audit: nil)
        await dispatcher.setDeferredResponder { response in
            await probe.record(response)
        }

        let first = await dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-4",
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(first)
        let second = await dispatcher.handle(.contactsDelete(
            helperId: Fixture.helper, messageId: "del-5",
            contactId: jane, idempotencyToken: nil))
        expectError(second, code: .busy)
        XCTAssertEqual(second?.errorPayload?.message, WireErrorMessage.confirmationAlreadyPending)

        await gate.release(with: false)
        guard let deferred = await probe.next() else {
            return XCTFail("expected the first delete's deferred response")
        }
        XCTAssertEqual(deferred.messageId, "del-4")
    }
}

/// A manually-advanced clock for the abandonment tests: the dispatcher
/// reads time only through its injected `now`, so advancing this drives
/// the timed-out-then-approved race deterministically.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = Date()
    private var offset: TimeInterval = 0

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return base.addingTimeInterval(offset)
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        offset += interval
        lock.unlock()
    }
}

/// A confirmation source that parks until released — for the
/// one-dialog-at-a-time and abandonment tests. `release` may run before
/// the dispatcher's task has even asked (the spawn is fire-and-forget), so
/// an early decision is buffered and handed out on the ask.
@MainActor
private final class SlowConfirmationSource: MCPConfirmationSource {
    private var continuation: CheckedContinuation<Bool?, Never>?
    private var bufferedDecision: Bool??

    nonisolated init() {}

    func confirmContactDelete(named contactName: String) async -> Bool? {
        if let decision = bufferedDecision {
            bufferedDecision = nil
            return decision
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(with decision: Bool?) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: decision)
        } else {
            bufferedDecision = decision
        }
    }
}
