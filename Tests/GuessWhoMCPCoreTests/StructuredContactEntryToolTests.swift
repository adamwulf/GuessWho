import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Structured-entry tool coverage (postal address / social profile / instant
/// message add-edit-delete).
///
/// The mutation-bearing cases run against the **production** stack through
/// `MCPProductionFixture`: a real `ContactsRepository` over the substituted
/// `RecordingContactStore` OS boundary, the real dispatcher, real on-disk
/// sidecars. Every add / edit / delete therefore reaches the same
/// `editableContact` → mutate → `saveContact` path the app runs, and every
/// durability assertion reads the **boundary** record back through
/// `RecordingContactStore` (or reloads the repository) — never a fake array.
///
/// The pure gate / malformed-payload cases stay on `Fixture` (Fakes.swift):
/// they are rejected in the dispatcher before any store interaction, so the
/// production stack would add nothing an in-memory book cannot already prove.
@MainActor
final class StructuredContactEntryToolTests: XCTestCase {
    private let home = WirePostalAddress(
        label: "home", street: "1 Main St\nUnit 2", subLocality: "Downtown",
        city: "Austin", subAdministrativeArea: "Travis", state: "TX",
        postalCode: "78701", country: "United States", isoCountryCode: "US")
    private let office = WirePostalAddress(
        label: "work", street: "200 Congress Ave", subLocality: "Central",
        city: "Austin", subAdministrativeArea: "Travis", state: "TX",
        postalCode: "78701", country: "United States", isoCountryCode: "US")
    private let linkedIn = WireSocialProfile(
        label: "work", service: "LinkedIn", username: "jane-doe",
        url: "https://www.linkedin.com/in/jane-doe")
    private let mastodon = WireSocialProfile(
        label: "personal", service: "Mastodon", username: "@jane@example.social",
        url: "https://example.social/@jane")
    private let signal = WireInstantMessage(
        label: "mobile", service: "Signal", username: "+15550107788")
    private let matrix = WireInstantMessage(
        label: "work", service: "Matrix", username: "@jane:example.org")

    /// The reconciled seed contact's stable wire id (her GuessWho UUID).
    private let adaID = MCPProductionFixture.adaGuessWhoID

    // MARK: - Production-fixture helpers

    /// A production fixture whose gates are opened for writes — the app's
    /// user-opted-in read-write state.
    private func writableFixture(writeLimit: Int = 30) async throws -> MCPProductionFixture {
        let fixture = try await MCPProductionFixture.make(writeLimitPerWindow: writeLimit)
        fixture.gates.mcpAccess = .readWrite
        fixture.gates.cliAccess = .readWrite
        return fixture
    }

    /// The DURABLE record for the reconciled seed contact, read straight from
    /// the substituted OS boundary (`RecordingContactStore`). This is the
    /// source of truth every structured-entry write must reach — not the
    /// repository cache, not a fake array.
    private func storedAda(_ fixture: MCPProductionFixture) async throws -> Contact {
        let fetched = try await fixture.store.fetch(localID: MCPProductionFixture.adaLocalID)
        return try XCTUnwrap(fetched)
    }

    /// Seed the reconciled contact's structured lists onto the boundary record
    /// and reload the repository so dispatch sees them — the same full refresh
    /// the app runs after an external change. Starts from the canonical `ada()`
    /// seed so her identity URL and the Apple-note sentinel are preserved.
    private func seedAda(
        _ fixture: MCPProductionFixture,
        _ configure: (inout Contact) -> Void
    ) async throws {
        var ada = MCPProductionFixture.ada()
        configure(&ada)
        try await fixture.seedContacts([ada])
    }

    // MARK: - Wire ⇄ model converters (seed builders / durable comparisons)

    private func postal(_ wire: WirePostalAddress) -> LabeledPostalAddress {
        LabeledPostalAddress(
            label: wire.label ?? "",
            value: PostalAddress(
                street: wire.street, subLocality: wire.subLocality ?? "",
                city: wire.city,
                subAdministrativeArea: wire.subAdministrativeArea ?? "",
                state: wire.state, postalCode: wire.postalCode,
                country: wire.country, isoCountryCode: wire.isoCountryCode ?? ""))
    }

    private func social(
        _ wire: WireSocialProfile, userIdentifier: String = ""
    ) -> LabeledSocialProfile {
        LabeledSocialProfile(
            label: wire.label ?? "",
            value: SocialProfile(
                urlString: wire.url ?? "", username: wire.username ?? "",
                userIdentifier: userIdentifier, service: wire.service ?? ""))
    }

    private func instant(_ wire: WireInstantMessage) -> LabeledInstantMessageAddress {
        LabeledInstantMessageAddress(
            label: wire.label ?? "",
            value: InstantMessageAddress(
                username: wire.username, service: wire.service ?? ""))
    }

    // MARK: - Fixture (fake) helpers for the pure gate / malformed cases

    private func janeID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.name == "Jane Doe" })?.id
    }

    private func storedJane(_ fixture: Fixture) -> Contact? {
        fixture.contacts.contacts.first { $0.displayName == "Jane Doe" }
    }

    // MARK: - Response matchers

    private func expectCard(
        _ response: WireResponse?, file: StaticString = #filePath, line: UInt = #line
    ) -> WireContact? {
        guard case .contact(_, _, let card) = response else {
            XCTFail("expected contact response, got \(String(describing: response))",
                    file: file, line: line)
            return nil
        }
        return card
    }

    private func expectError(
        _ response: WireResponse?, code: WireErrorCode, message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let payload = response?.errorPayload else {
            return XCTFail("expected error, got \(String(describing: response))",
                           file: file, line: line)
        }
        XCTAssertEqual(payload.code, code, file: file, line: line)
        XCTAssertEqual(payload.message, message, file: file, line: line)
    }

    // MARK: - Add / edit / delete preservation (production stack)

    func testPostalAddressAddEditDeletePreservesLabelAndUnrelatedData() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        let before = try await storedAda(fixture)

        let added = await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, address: home, idempotencyToken: nil))
        XCTAssertEqual(expectCard(added)?.postalAddresses, [home])
        // Durable: the boundary record now carries the added address.
        let storedAfterAdd = try await storedAda(fixture)
        XCTAssertEqual(storedAfterAdd.postalAddresses, [postal(home)])

        let replacement = WirePostalAddress(
            label: nil, street: "9 New St", subLocality: "Clarksville",
            city: "Austin", subAdministrativeArea: "Travis", state: "TX",
            postalCode: "78703", country: "United States", isoCountryCode: "US")
        let edited = await fixture.dispatcher.handle(.contactsEditPostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            currentAddress: home, newAddress: replacement, idempotencyToken: nil))
        guard let editedCard = expectCard(edited) else { return }
        XCTAssertEqual(editedCard.postalAddresses.first?.label, "home")
        XCTAssertEqual(editedCard.postalAddresses.first?.street, "9 New St")
        // Durable: the label survived the labelless replacement on disk.
        let storedAfterEdit = try await storedAda(fixture)
        XCTAssertEqual(storedAfterEdit.postalAddresses.first?.label, "home")
        XCTAssertEqual(storedAfterEdit.postalAddresses.first?.value.street, "9 New St")

        var currentReplacement = replacement
        currentReplacement = WirePostalAddress(
            label: "home", street: currentReplacement.street,
            subLocality: currentReplacement.subLocality, city: currentReplacement.city,
            subAdministrativeArea: currentReplacement.subAdministrativeArea,
            state: currentReplacement.state, postalCode: currentReplacement.postalCode,
            country: currentReplacement.country,
            isoCountryCode: currentReplacement.isoCountryCode)
        let deleted = await fixture.dispatcher.handle(.contactsDeletePostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, address: currentReplacement, idempotencyToken: nil))
        XCTAssertEqual(expectCard(deleted)?.postalAddresses, [])

        let after = try await storedAda(fixture)
        XCTAssertEqual(after.postalAddresses, [])
        XCTAssertEqual(after.note, Sentinels.appleNote)
        XCTAssertEqual(after.urlAddresses, before.urlAddresses)
        XCTAssertEqual(after.phoneNumbers, before.phoneNumbers)
        XCTAssertEqual(after.jobTitle, before.jobTitle)
    }

    func testSocialProfileAddEditDeletePreservesLabelAndHiddenUserIdentifier() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        try await seedAda(fixture) {
            $0.socialProfiles = [self.social(self.linkedIn, userIdentifier: "hidden-system-id")]
            $0.instantMessageAddresses = [self.instant(self.signal)]
        }

        let added = await fixture.dispatcher.handle(.contactsAddSocialProfile(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, profile: mastodon, idempotencyToken: nil))
        XCTAssertEqual(expectCard(added)?.socialProfiles, [linkedIn, mastodon])

        let replacement = WireSocialProfile(
            label: nil, service: "LinkedIn", username: "jane-doe-new",
            url: "https://www.linkedin.com/in/jane-doe-new")
        let edited = await fixture.dispatcher.handle(.contactsEditSocialProfile(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            currentProfile: linkedIn, newProfile: replacement, idempotencyToken: nil))
        guard let editedCard = expectCard(edited) else { return }
        XCTAssertEqual(editedCard.socialProfiles.first?.label, "work")
        XCTAssertEqual(editedCard.socialProfiles.first?.username, "jane-doe-new")
        // Durable: the hidden system identifier (never on the wire) survived the
        // labelless edit, and the untouched instant-message list is intact.
        let stored = try await storedAda(fixture)
        XCTAssertEqual(stored.socialProfiles.first?.value.userIdentifier, "hidden-system-id")
        XCTAssertEqual(stored.instantMessageAddresses, [instant(signal)])

        let current = WireSocialProfile(
            label: "work", service: replacement.service,
            username: replacement.username, url: replacement.url)
        let deleted = await fixture.dispatcher.handle(.contactsDeleteSocialProfile(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, profile: current, idempotencyToken: nil))
        XCTAssertEqual(expectCard(deleted)?.socialProfiles, [mastodon])
        // Durable: only Mastodon remains on the boundary record.
        let storedAfterDelete = try await storedAda(fixture)
        XCTAssertEqual(storedAfterDelete.socialProfiles, [social(mastodon)])
    }

    func testInstantMessageAddEditDeletePreservesLabelAndOtherLists() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        try await seedAda(fixture) { $0.postalAddresses = [self.postal(self.home)] }

        let added = await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, instantMessage: signal, idempotencyToken: nil))
        XCTAssertEqual(expectCard(added)?.instantMessages, [signal])
        let storedAfterAdd = try await storedAda(fixture)
        XCTAssertEqual(storedAfterAdd.instantMessageAddresses, [instant(signal)])

        let replacement = WireInstantMessage(
            label: nil, service: "Signal", username: "+15550109999")
        let edited = await fixture.dispatcher.handle(.contactsEditInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            currentInstantMessage: signal, newInstantMessage: replacement,
            idempotencyToken: nil))
        guard let card = expectCard(edited) else { return }
        XCTAssertEqual(card.instantMessages.first?.label, "mobile")
        XCTAssertEqual(card.postalAddresses, [home])
        // Durable: the label survived and the untouched postal list is intact.
        let storedAfterEdit = try await storedAda(fixture)
        XCTAssertEqual(storedAfterEdit.instantMessageAddresses.first?.label, "mobile")
        XCTAssertEqual(storedAfterEdit.postalAddresses, [postal(home)])

        let deleted = await fixture.dispatcher.handle(.contactsDeleteInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            instantMessage: WireInstantMessage(
                label: "mobile", service: "Signal", username: "+15550109999"),
            idempotencyToken: nil))
        XCTAssertEqual(expectCard(deleted)?.instantMessages, [])
        let storedAfterDelete = try await storedAda(fixture)
        XCTAssertEqual(storedAfterDelete.instantMessageAddresses, [])
    }

    // MARK: - Matching / zero-match / ambiguous (matching in the dispatcher,
    // mutations reach the real fetch / edit / save)

    func testMatchingUsesEveryFieldIncludingLabels() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        let otherPostal = WirePostalAddress(
            label: home.label, street: home.street, subLocality: "East Downtown",
            city: home.city, subAdministrativeArea: home.subAdministrativeArea,
            state: home.state, postalCode: home.postalCode, country: home.country,
            isoCountryCode: home.isoCountryCode)
        let otherSocial = WireSocialProfile(
            label: linkedIn.label, service: linkedIn.service,
            username: linkedIn.username, url: "https://mirror.example/jane")
        let otherInstant = WireInstantMessage(
            label: "personal", service: signal.service, username: signal.username)
        try await seedAda(fixture) {
            $0.postalAddresses = [self.postal(self.home), self.postal(otherPostal)]
            $0.socialProfiles = [self.social(self.linkedIn), self.social(otherSocial)]
            $0.instantMessageAddresses = [self.instant(self.signal), self.instant(otherInstant)]
        }

        _ = await fixture.dispatcher.handle(.contactsDeletePostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, address: home, idempotencyToken: nil))
        _ = await fixture.dispatcher.handle(.contactsDeleteSocialProfile(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, profile: linkedIn, idempotencyToken: nil))
        _ = await fixture.dispatcher.handle(.contactsDeleteInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, instantMessage: signal, idempotencyToken: nil))

        // Durable: the exact-match delete removed only the fully matching entry
        // on the boundary record; the near-duplicates survive untouched.
        let stored = try await storedAda(fixture)
        XCTAssertEqual(stored.postalAddresses, [postal(otherPostal)])
        XCTAssertEqual(stored.socialProfiles, [social(otherSocial)])
        XCTAssertEqual(stored.instantMessageAddresses, [instant(otherInstant)])
    }

    func testZeroMatchesReturnNotFoundAndChangeNothing() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        try await seedAda(fixture) {
            $0.postalAddresses = [self.postal(self.home)]
            $0.socialProfiles = [self.social(self.linkedIn)]
            $0.instantMessageAddresses = [self.instant(self.signal)]
        }
        let before = try await storedAda(fixture)

        expectError(await fixture.dispatcher.handle(.contactsDeletePostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, address: office, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noMatchingPostalAddress)
        expectError(await fixture.dispatcher.handle(.contactsDeleteSocialProfile(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, profile: mastodon, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noMatchingSocialProfile)
        expectError(await fixture.dispatcher.handle(.contactsDeleteInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, instantMessage: matrix, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noMatchingInstantMessage)

        // Durable: nothing changed on the boundary AND no save ever reached it.
        let after = try await storedAda(fixture)
        XCTAssertEqual(after, before)
        let saveCount = await fixture.store.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    func testExactDuplicatesReturnAmbiguousAndChangeNothing() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        try await seedAda(fixture) {
            $0.postalAddresses = [self.postal(self.home), self.postal(self.home)]
            // The system-only user identifier is deliberately different.
            // It is excluded from the wire and must never be used to guess
            // between otherwise identical visible entries.
            $0.socialProfiles = [
                self.social(self.linkedIn, userIdentifier: "hidden-a"),
                self.social(self.linkedIn, userIdentifier: "hidden-b"),
            ]
            $0.instantMessageAddresses = [self.instant(self.signal), self.instant(self.signal)]
        }
        let before = try await storedAda(fixture)

        expectError(await fixture.dispatcher.handle(.contactsEditPostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            currentAddress: home, newAddress: office, idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousPostalAddress)
        expectError(await fixture.dispatcher.handle(.contactsEditSocialProfile(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            currentProfile: linkedIn, newProfile: mastodon, idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousSocialProfile)
        expectError(await fixture.dispatcher.handle(.contactsEditInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: adaID,
            currentInstantMessage: signal, newInstantMessage: matrix,
            idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousInstantMessage)

        // Durable: the ambiguous edits changed nothing and never saved.
        let after = try await storedAda(fixture)
        XCTAssertEqual(after, before)
        let saveCount = await fixture.store.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    // MARK: - Idempotency + budget + audit (real write path)

    func testIdempotencyBudgetAndAuditApply() async throws {
        let fixture = try await writableFixture(writeLimit: 1)
        defer { fixture.cleanUp() }
        let first = await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: "structured-first",
            contactId: adaID, instantMessage: signal, idempotencyToken: "structured-token"))
        let replay = await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: MCPProductionFixture.helper, messageId: "structured-retry",
            contactId: adaID, instantMessage: signal, idempotencyToken: "structured-token"))
        XCTAssertNotNil(expectCard(first))
        XCTAssertNotNil(expectCard(replay))
        // Durable: the token replay did not double-write — one entry on the
        // boundary, committed by exactly one save.
        let storedAfterReplay = try await storedAda(fixture)
        XCTAssertEqual(storedAfterReplay.instantMessageAddresses.count, 1)
        let committed = await fixture.store.committedSaveLocalIDs
        XCTAssertEqual(committed, [MCPProductionFixture.adaLocalID])

        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, address: home, idempotencyToken: nil)),
            code: .busy, message: WireErrorMessage.writeBusy)
        let entries = await fixture.audit.entries()
        XCTAssertTrue(entries.contains {
            $0.action == .editContact && $0.subjectName == "Ada Lovelace"
                && $0.newValue == "instantMessages"
        })
    }

    // MARK: - Save failure at the real boundary

    func testSaveFailureIsTypedAndLeavesStoredCardUnchanged() async throws {
        let fixture = try await writableFixture()
        defer { fixture.cleanUp() }
        let before = try await storedAda(fixture)
        // Fault the FIRST boundary save (seeds/reloads never save, so the add's
        // own `saveContact` is ordinal 1) with the Cocoa 134092 store-rejection
        // family the real Contacts store raises.
        await fixture.store.failSave(atOrdinal: 1, with: NSError(
            domain: "NSCocoaErrorDomain", code: 134092,
            userInfo: [NSLocalizedDescriptionKey: Sentinels.appleNote]))
        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: adaID, address: home, idempotencyToken: nil)),
            code: .writeFailed, message: WireErrorMessage.writeFailed)

        // Durable: the boundary counted the rejected attempt but committed
        // nothing, and the stored card is unchanged.
        let after = try await storedAda(fixture)
        XCTAssertEqual(after, before)
        let saveCount = await fixture.store.saveCount
        let committed = await fixture.store.committedSaveLocalIDs
        XCTAssertEqual(saveCount, 1)
        XCTAssertTrue(committed.isEmpty)
    }

    // MARK: - Per-contact single-flight (real serialized read-modify-write)

    func testConcurrentStructuredAddsArePerContactSingleFlight() async throws {
        let fixture = try await writableFixture(writeLimit: 50)
        defer { fixture.cleanUp() }
        // Hoist the Sendable pieces the off-main tasks need so the closures
        // never capture the `@MainActor` fixture value itself.
        let dispatcher = fixture.dispatcher
        let contactId = adaID
        let helper = MCPProductionFixture.helper
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = await dispatcher.handle(.contactsAddInstantMessage(
                        helperId: helper,
                        messageId: "structured-concurrent-\(index)",
                        contactId: contactId,
                        instantMessage: WireInstantMessage(
                            label: "work", service: "Matrix",
                            username: "@ada-\(index):example.org"),
                        idempotencyToken: nil))
                }
            }
        }
        // Durable: the per-contact single-flight serialized every read-modify-
        // write, so all 20 distinct usernames land on the boundary record with
        // no lost or duplicated updates.
        let stored = try await storedAda(fixture)
        let usernames = stored.instantMessageAddresses.map(\.value.username)
        XCTAssertEqual(usernames.count, 20)
        XCTAssertEqual(Set(usernames).count, 20)
    }

    // MARK: - Pure gate / malformed cases (rejected before any store touch)

    func testDirectMalformedPayloadsAreRejectedBeforeAnyChange() async {
        let fixture = Fixture.make()
        fixture.gates.mcpAccess = .readWrite
        fixture.gates.cliAccess = .readWrite
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = storedJane(fixture)
        let emptyPostal = WirePostalAddress(
            label: "label-only", street: "", city: "", state: "",
            postalCode: "", country: "")
        let emptySocial = WireSocialProfile(
            label: "label-only", service: nil, username: nil, url: nil)
        let emptyInstant = WireInstantMessage(label: nil, service: "Signal", username: " ")

        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: emptyPostal, idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.emptyPostalAddress)
        expectError(await fixture.dispatcher.handle(.contactsAddSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: emptySocial, idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.emptySocialProfile)
        expectError(await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, instantMessage: emptyInstant, idempotencyToken: nil)),
            code: .invalidParams, message: WireErrorMessage.emptyInstantMessage)
        let after = storedJane(fixture)
        XCTAssertEqual(after, before)
    }

    func testReadOnlyAndContactsPermissionGatesApply() async {
        let fixture = Fixture.make()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: home, idempotencyToken: nil)),
            code: .readOnly, message: WireErrorMessage.readOnly)

        fixture.gates.mcpAccess = .readWrite
        fixture.gates.contactsAuthorized = false
        expectError(await fixture.dispatcher.handle(.contactsAddSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: linkedIn, idempotencyToken: nil)),
            code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        let stored = storedJane(fixture)
        XCTAssertEqual(stored?.postalAddresses, [])
        XCTAssertEqual(stored?.socialProfiles, [])
    }

    func testAllStructuredToolsAreContactWritesAndListedOnlyWhenWritable() async {
        let tools: [MCPTool] = [
            .contactsAddPostalAddress, .contactsEditPostalAddress,
            .contactsDeletePostalAddress, .contactsAddSocialProfile,
            .contactsEditSocialProfile, .contactsDeleteSocialProfile,
            .contactsAddInstantMessage, .contactsEditInstantMessage,
            .contactsDeleteInstantMessage,
        ]
        for tool in tools {
            XCTAssertTrue(tool.isWrite)
            if case .contacts = tool.permissionDomain {} else {
                XCTFail("\(tool.rawValue) must require Contacts permission")
            }
        }

        let fixture = Fixture.make()
        let readOnly = await fixture.dispatcher.handle(.listTools(
            helperId: Fixture.helper, messageId: TestMessageID.next()))
        guard case .toolList(_, _, let readOnlyMetadata, _) = readOnly else {
            return XCTFail("expected tool list")
        }
        let readOnlyNames = Set(readOnlyMetadata.map(\.name))
        XCTAssertTrue(tools.allSatisfy { !readOnlyNames.contains($0.rawValue) })

        fixture.gates.mcpAccess = .readWrite
        let writable = await fixture.dispatcher.handle(.listTools(
            helperId: Fixture.helper, messageId: TestMessageID.next()))
        guard case .toolList(_, _, let writableMetadata, _) = writable else {
            return XCTFail("expected tool list")
        }
        let writableNames = Set(writableMetadata.map(\.name))
        XCTAssertTrue(tools.allSatisfy { writableNames.contains($0.rawValue) })
    }
}
