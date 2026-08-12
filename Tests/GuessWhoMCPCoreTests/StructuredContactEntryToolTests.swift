import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

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

    private func writableFixture(writeLimit: Int = 30) async -> Fixture {
        let fixture = await Fixture.make(writeLimitPerWindow: writeLimit)
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

    private func mutateJane(
        _ fixture: Fixture, _ mutate: @escaping (inout Contact) -> Void
    ) async {
        await MainActor.run {
            guard let index = fixture.contacts.contacts.firstIndex(where: {
                $0.displayName == "Jane Doe"
            }) else { return }
            mutate(&fixture.contacts.contacts[index])
        }
    }

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

    func testPostalAddressAddEditDeletePreservesLabelAndUnrelatedData() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await storedJane(fixture)

        let added = await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: home, idempotencyToken: nil))
        XCTAssertEqual(expectCard(added)?.postalAddresses, [home])

        let replacement = WirePostalAddress(
            label: nil, street: "9 New St", subLocality: "Clarksville",
            city: "Austin", subAdministrativeArea: "Travis", state: "TX",
            postalCode: "78703", country: "United States", isoCountryCode: "US")
        let edited = await fixture.dispatcher.handle(.contactsEditPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            currentAddress: home, newAddress: replacement, idempotencyToken: nil))
        guard let editedCard = expectCard(edited) else { return }
        XCTAssertEqual(editedCard.postalAddresses.first?.label, "home")
        XCTAssertEqual(editedCard.postalAddresses.first?.street, "9 New St")

        var currentReplacement = replacement
        currentReplacement = WirePostalAddress(
            label: "home", street: currentReplacement.street,
            subLocality: currentReplacement.subLocality, city: currentReplacement.city,
            subAdministrativeArea: currentReplacement.subAdministrativeArea,
            state: currentReplacement.state, postalCode: currentReplacement.postalCode,
            country: currentReplacement.country,
            isoCountryCode: currentReplacement.isoCountryCode)
        let deleted = await fixture.dispatcher.handle(.contactsDeletePostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: currentReplacement, idempotencyToken: nil))
        XCTAssertEqual(expectCard(deleted)?.postalAddresses, [])

        let after = await storedJane(fixture)
        XCTAssertEqual(after?.note, Sentinels.appleNote)
        XCTAssertEqual(after?.urlAddresses, before?.urlAddresses)
        XCTAssertEqual(after?.phoneNumbers, before?.phoneNumbers)
        XCTAssertEqual(after?.jobTitle, before?.jobTitle)
    }

    func testSocialProfileAddEditDeletePreservesLabelAndHiddenUserIdentifier() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) {
            $0.socialProfiles = [self.social(self.linkedIn, userIdentifier: "hidden-system-id")]
            $0.instantMessageAddresses = [self.instant(self.signal)]
        }

        let added = await fixture.dispatcher.handle(.contactsAddSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: mastodon, idempotencyToken: nil))
        XCTAssertEqual(expectCard(added)?.socialProfiles, [linkedIn, mastodon])

        let replacement = WireSocialProfile(
            label: nil, service: "LinkedIn", username: "jane-doe-new",
            url: "https://www.linkedin.com/in/jane-doe-new")
        let edited = await fixture.dispatcher.handle(.contactsEditSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            currentProfile: linkedIn, newProfile: replacement, idempotencyToken: nil))
        guard let editedCard = expectCard(edited) else { return }
        XCTAssertEqual(editedCard.socialProfiles.first?.label, "work")
        XCTAssertEqual(editedCard.socialProfiles.first?.username, "jane-doe-new")
        let stored = await storedJane(fixture)
        XCTAssertEqual(stored?.socialProfiles.first?.value.userIdentifier, "hidden-system-id")
        XCTAssertEqual(stored?.instantMessageAddresses, [instant(signal)])

        let current = WireSocialProfile(
            label: "work", service: replacement.service,
            username: replacement.username, url: replacement.url)
        let deleted = await fixture.dispatcher.handle(.contactsDeleteSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: current, idempotencyToken: nil))
        XCTAssertEqual(expectCard(deleted)?.socialProfiles, [mastodon])
    }

    func testInstantMessageAddEditDeletePreservesLabelAndOtherLists() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) { $0.postalAddresses = [self.postal(self.home)] }

        let added = await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, instantMessage: signal, idempotencyToken: nil))
        XCTAssertEqual(expectCard(added)?.instantMessages, [signal])

        let replacement = WireInstantMessage(
            label: nil, service: "Signal", username: "+15550109999")
        let edited = await fixture.dispatcher.handle(.contactsEditInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            currentInstantMessage: signal, newInstantMessage: replacement,
            idempotencyToken: nil))
        guard let card = expectCard(edited) else { return }
        XCTAssertEqual(card.instantMessages.first?.label, "mobile")
        XCTAssertEqual(card.postalAddresses, [home])

        let deleted = await fixture.dispatcher.handle(.contactsDeleteInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            instantMessage: WireInstantMessage(
                label: "mobile", service: "Signal", username: "+15550109999"),
            idempotencyToken: nil))
        XCTAssertEqual(expectCard(deleted)?.instantMessages, [])
    }

    func testMatchingUsesEveryFieldIncludingLabels() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
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
        await mutateJane(fixture) {
            $0.postalAddresses = [self.postal(self.home), self.postal(otherPostal)]
            $0.socialProfiles = [self.social(self.linkedIn), self.social(otherSocial)]
            $0.instantMessageAddresses = [self.instant(self.signal), self.instant(otherInstant)]
        }

        _ = await fixture.dispatcher.handle(.contactsDeletePostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: home, idempotencyToken: nil))
        _ = await fixture.dispatcher.handle(.contactsDeleteSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: linkedIn, idempotencyToken: nil))
        _ = await fixture.dispatcher.handle(.contactsDeleteInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, instantMessage: signal, idempotencyToken: nil))

        let stored = await storedJane(fixture)
        XCTAssertEqual(stored?.postalAddresses, [postal(otherPostal)])
        XCTAssertEqual(stored?.socialProfiles, [social(otherSocial)])
        XCTAssertEqual(stored?.instantMessageAddresses, [instant(otherInstant)])
    }

    func testZeroMatchesReturnNotFoundAndChangeNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) {
            $0.postalAddresses = [self.postal(self.home)]
            $0.socialProfiles = [self.social(self.linkedIn)]
            $0.instantMessageAddresses = [self.instant(self.signal)]
        }
        let before = await storedJane(fixture)

        expectError(await fixture.dispatcher.handle(.contactsDeletePostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: office, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noMatchingPostalAddress)
        expectError(await fixture.dispatcher.handle(.contactsDeleteSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: mastodon, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noMatchingSocialProfile)
        expectError(await fixture.dispatcher.handle(.contactsDeleteInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, instantMessage: matrix, idempotencyToken: nil)),
            code: .notFound, message: WireErrorMessage.noMatchingInstantMessage)

        let after = await storedJane(fixture)
        XCTAssertEqual(after, before)
    }

    func testExactDuplicatesReturnAmbiguousAndChangeNothing() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await mutateJane(fixture) {
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
        let before = await storedJane(fixture)

        expectError(await fixture.dispatcher.handle(.contactsEditPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            currentAddress: home, newAddress: office, idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousPostalAddress)
        expectError(await fixture.dispatcher.handle(.contactsEditSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            currentProfile: linkedIn, newProfile: mastodon, idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousSocialProfile)
        expectError(await fixture.dispatcher.handle(.contactsEditInstantMessage(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            currentInstantMessage: signal, newInstantMessage: matrix,
            idempotencyToken: nil)),
            code: .ambiguous, message: WireErrorMessage.ambiguousInstantMessage)

        let after = await storedJane(fixture)
        XCTAssertEqual(after, before)
    }

    func testDirectMalformedPayloadsAreRejectedBeforeAnyChange() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await storedJane(fixture)
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
        let after = await storedJane(fixture)
        XCTAssertEqual(after, before)
    }

    func testReadOnlyAndContactsPermissionGatesApply() async {
        let fixture = await Fixture.make()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: home, idempotencyToken: nil)),
            code: .readOnly, message: WireErrorMessage.readOnly)

        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.contactsAuthorized = false
        }
        expectError(await fixture.dispatcher.handle(.contactsAddSocialProfile(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, profile: linkedIn, idempotencyToken: nil)),
            code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        let stored = await storedJane(fixture)
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

        let fixture = await Fixture.make()
        let readOnly = await fixture.dispatcher.handle(.listTools(
            helperId: Fixture.helper, messageId: TestMessageID.next()))
        guard case .toolList(_, _, let readOnlyMetadata, _) = readOnly else {
            return XCTFail("expected tool list")
        }
        let readOnlyNames = Set(readOnlyMetadata.map(\.name))
        XCTAssertTrue(tools.allSatisfy { !readOnlyNames.contains($0.rawValue) })

        await MainActor.run { fixture.gates.mcpAccess = .readWrite }
        let writable = await fixture.dispatcher.handle(.listTools(
            helperId: Fixture.helper, messageId: TestMessageID.next()))
        guard case .toolList(_, _, let writableMetadata, _) = writable else {
            return XCTFail("expected tool list")
        }
        let writableNames = Set(writableMetadata.map(\.name))
        XCTAssertTrue(tools.allSatisfy { writableNames.contains($0.rawValue) })
    }

    func testIdempotencyBudgetAndAuditApply() async {
        let fixture = await writableFixture(writeLimit: 1)
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let first = await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: Fixture.helper, messageId: "structured-first",
            contactId: jane, instantMessage: signal, idempotencyToken: "structured-token"))
        let replay = await fixture.dispatcher.handle(.contactsAddInstantMessage(
            helperId: Fixture.helper, messageId: "structured-retry",
            contactId: jane, instantMessage: signal, idempotencyToken: "structured-token"))
        XCTAssertNotNil(expectCard(first))
        XCTAssertNotNil(expectCard(replay))
        let stored = await storedJane(fixture)
        XCTAssertEqual(stored?.instantMessageAddresses.count, 1)

        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: home, idempotencyToken: nil)),
            code: .busy, message: WireErrorMessage.writeBusy)
        let entries = await fixture.audit.entries()
        XCTAssertTrue(entries.contains {
            $0.action == .editContact && $0.subjectName == "Jane Doe"
                && $0.newValue == "instantMessages"
        })
    }

    func testSaveFailureIsTypedAndLeavesStoredCardUnchanged() async {
        let fixture = await writableFixture()
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        let before = await storedJane(fixture)
        await MainActor.run {
            fixture.contacts.nextSaveContactError = NSError(
                domain: "NSCocoaErrorDomain", code: 134092,
                userInfo: [NSLocalizedDescriptionKey: Sentinels.appleNote])
        }
        expectError(await fixture.dispatcher.handle(.contactsAddPostalAddress(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, address: home, idempotencyToken: nil)),
            code: .writeFailed, message: WireErrorMessage.writeFailed)
        let after = await storedJane(fixture)
        XCTAssertEqual(after, before)
    }

    func testConcurrentStructuredAddsArePerContactSingleFlight() async {
        let fixture = await writableFixture(writeLimit: 50)
        guard let jane = await janeID(fixture) else { return XCTFail("no jane") }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = await fixture.dispatcher.handle(.contactsAddInstantMessage(
                        helperId: Fixture.helper, messageId: "structured-concurrent-\(index)",
                        contactId: jane,
                        instantMessage: WireInstantMessage(
                            label: "work", service: "Matrix",
                            username: "@jane-\(index):example.org"),
                        idempotencyToken: nil))
                }
            }
        }
        let usernames = (await storedJane(fixture))?.instantMessageAddresses
            .map(\.value.username)
        XCTAssertEqual(Set(usernames ?? []).count, 20)
    }
}
