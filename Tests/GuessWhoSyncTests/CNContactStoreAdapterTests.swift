#if canImport(Contacts)
import Contacts
import Foundation
import Testing
@testable import GuessWhoSync

/// Covers `CNContactStoreAdapter`'s store-free logic: the CN↔Contact mapping
/// pair (`toContact` / `apply`), the fetch-key contract, the save-request
/// author tag, and the authorization collapse table.
///
/// Everything here runs against in-memory `CNMutableContact` fixtures —
/// constructing CN objects requires no Contacts permission (only store
/// fetches/saves trigger TCC), so these tests are safe on any CI host. The
/// store-touching paths (fetchAll/save/create/delete/changes) stay covered by
/// the InMemoryContactStore-driven suites at the repository layer; the seam
/// this file closes is the REAL mapping the app ships, which previously ran
/// only inside the live app.
@Suite("CNContactStoreAdapter mapping")
struct CNContactStoreAdapterTests {
    // MARK: - Fixtures

    /// A Contact exercising EVERY field the adapter maps, with multi-element
    /// labeled lists and both empty and non-empty labels (empty label ↔ nil
    /// CN label is part of the mapping contract).
    private func fullContact() -> Contact {
        var birthday = DateComponents()
        birthday.year = 1815
        birthday.month = 12
        birthday.day = 10

        var lunar = DateComponents()
        lunar.calendar = Calendar(identifier: .chinese)
        lunar.month = 3
        lunar.day = 7

        var anniversary = DateComponents()
        anniversary.year = 2001
        anniversary.month = 6
        anniversary.day = 14

        return Contact(
            contactType: .person,
            namePrefix: "Dr.",
            givenName: "Ada",
            middleName: "King",
            familyName: "Lovelace",
            previousFamilyName: "Byron",
            nameSuffix: "PhD",
            nickname: "The Enchantress",
            phoneticGivenName: "AY-duh",
            phoneticMiddleName: "KING",
            phoneticFamilyName: "LUV-lace",
            jobTitle: "Analyst",
            departmentName: "Engines",
            organizationName: "Analytical Engine Co",
            phoneticOrganizationName: "an-uh-LIT-ik-ul",
            note: "Met at the Royal Society.\nPrefers written follow-up.",
            phoneNumbers: [
                LabeledValue(label: CNLabelPhoneNumberMobile, value: "+1 (555) 010-4477"),
                LabeledValue(label: "", value: "555-0100")
            ],
            emailAddresses: [
                LabeledValue(label: CNLabelHome, value: "ada@example.com"),
                LabeledValue(label: "", value: "lovelace@engine.example")
            ],
            postalAddresses: [
                LabeledPostalAddress(
                    label: CNLabelWork,
                    value: PostalAddress(
                        street: "12 Analytical Way",
                        subLocality: "Marylebone",
                        city: "London",
                        subAdministrativeArea: "Greater London",
                        state: "England",
                        postalCode: "W1U 6TS",
                        country: "United Kingdom",
                        isoCountryCode: "gb"
                    )
                )
            ],
            urlAddresses: [LabeledValue(label: CNLabelURLAddressHomePage, value: "https://example.com/ada")],
            birthday: birthday,
            nonGregorianBirthday: lunar,
            dates: [LabeledDate(label: "anniversary", value: anniversary)],
            socialProfiles: [
                LabeledSocialProfile(
                    label: "",
                    value: SocialProfile(
                        urlString: "https://social.example/ada",
                        username: "ada",
                        userIdentifier: "uid-1815",
                        service: "ExampleNet"
                    )
                )
            ],
            instantMessageAddresses: [
                LabeledInstantMessageAddress(
                    label: CNLabelHome,
                    value: InstantMessageAddress(username: "ada@chat.example", service: "Jabber")
                )
            ],
            contactRelations: [
                LabeledContactRelation(label: CNLabelContactRelationParent, value: ContactRelation(name: "Anne Isabella"))
            ],
            imageDataAvailable: false
        )
    }

    // MARK: - apply (Contact → CNMutableContact)

    @Test
    func applyMapsEveryFieldOntoMutableContact() {
        let contact = fullContact()
        let mutable = CNMutableContact()
        CNContactStoreAdapter.apply(contact, to: mutable)

        #expect(mutable.contactType == .person)
        #expect(mutable.namePrefix == "Dr.")
        #expect(mutable.givenName == "Ada")
        #expect(mutable.middleName == "King")
        #expect(mutable.familyName == "Lovelace")
        #expect(mutable.previousFamilyName == "Byron")
        #expect(mutable.nameSuffix == "PhD")
        #expect(mutable.nickname == "The Enchantress")
        #expect(mutable.phoneticGivenName == "AY-duh")
        #expect(mutable.phoneticMiddleName == "KING")
        #expect(mutable.phoneticFamilyName == "LUV-lace")
        #expect(mutable.jobTitle == "Analyst")
        #expect(mutable.departmentName == "Engines")
        #expect(mutable.organizationName == "Analytical Engine Co")
        #expect(mutable.phoneticOrganizationName == "an-uh-LIT-ik-ul")
        #expect(mutable.note == "Met at the Royal Society.\nPrefers written follow-up.")

        #expect(mutable.phoneNumbers.count == 2)
        #expect(mutable.phoneNumbers[0].label == CNLabelPhoneNumberMobile)
        #expect(mutable.phoneNumbers[0].value.stringValue == "+1 (555) 010-4477")
        // Empty Contact label maps to a NIL CN label, not an empty string —
        // Contacts.app renders an empty-string label as a blank row.
        #expect(mutable.phoneNumbers[1].label == nil)

        #expect(mutable.emailAddresses.count == 2)
        #expect(mutable.emailAddresses[0].value as String == "ada@example.com")
        #expect(mutable.emailAddresses[1].label == nil)

        let postal = mutable.postalAddresses[0]
        #expect(postal.label == CNLabelWork)
        #expect(postal.value.street == "12 Analytical Way")
        #expect(postal.value.subLocality == "Marylebone")
        #expect(postal.value.city == "London")
        #expect(postal.value.subAdministrativeArea == "Greater London")
        #expect(postal.value.state == "England")
        #expect(postal.value.postalCode == "W1U 6TS")
        #expect(postal.value.country == "United Kingdom")
        #expect(postal.value.isoCountryCode == "gb")

        #expect(mutable.urlAddresses[0].value as String == "https://example.com/ada")
        #expect(mutable.birthday?.year == 1815)
        #expect(mutable.nonGregorianBirthday?.calendar?.identifier == .chinese)
        #expect(mutable.dates[0].label == "anniversary")
        #expect((mutable.dates[0].value as DateComponents).year == 2001)

        let social = mutable.socialProfiles[0]
        #expect(social.label == nil)
        #expect(social.value.urlString == "https://social.example/ada")
        #expect(social.value.username == "ada")
        #expect(social.value.userIdentifier == "uid-1815")
        #expect(social.value.service == "ExampleNet")

        let im = mutable.instantMessageAddresses[0]
        #expect(im.value.username == "ada@chat.example")
        #expect(im.value.service == "Jabber")

        let relation = mutable.contactRelations[0]
        #expect(relation.label == CNLabelContactRelationParent)
        #expect(relation.value.name == "Anne Isabella")
    }

    @Test
    func applyMapsOrganizationType() {
        var contact = Contact(organizationName: "Acme Corp")
        contact.contactType = .organization
        let mutable = CNMutableContact()
        CNContactStoreAdapter.apply(contact, to: mutable)
        #expect(mutable.contactType == .organization)
    }

    @Test
    func applyLeavesImageBytesUntouched() {
        // The mapping deliberately never writes imageData: a read-modify-write
        // save must preserve whatever photo bytes exist on the card (the photo
        // path owns them separately). A regression here silently strips
        // photos on every field edit.
        let mutable = CNMutableContact()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        mutable.imageData = bytes

        CNContactStoreAdapter.apply(fullContact(), to: mutable)
        #expect(mutable.imageData == bytes)
    }

    // MARK: - toContact (CNContact → Contact)

    @Test
    func toContactMapsIdentifierTypeAndNilLabels() {
        let mutable = CNMutableContact()
        mutable.contactType = .organization
        mutable.organizationName = "Acme Corp"
        mutable.note = "Vendor relationship owner."
        // A CN label of nil maps to "" (Contact's labels are non-optional).
        mutable.phoneNumbers = [CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "555-0100"))]

        let contact = CNContactStoreAdapter.toContact(mutable)
        #expect(contact.localID == mutable.identifier)
        #expect(contact.contactType == .organization)
        #expect(contact.organizationName == "Acme Corp")
        #expect(contact.note == "Vendor relationship owner.")
        #expect(contact.phoneNumbers == [LabeledValue(label: "", value: "555-0100")])
    }

    // MARK: - Round trip

    @Test
    func roundTripPreservesEveryField() throws {
        // apply → toContact must be lossless for every mapped field. This is
        // the guard that a field added to `Contact` and wired into only ONE
        // direction of the mapping fails loudly. (A field missing from BOTH
        // directions is caught by the per-direction tests above.)
        let original = fullContact()

        let mutable = CNMutableContact()
        CNContactStoreAdapter.apply(original, to: mutable)
        let roundTripped = CNContactStoreAdapter.toContact(mutable)

        // Normalize the two fields the mapping does NOT round-trip by design:
        // localID is minted by CN at CNMutableContact init (the original's
        // empty localID can't survive), and imageDataAvailable is a derived
        // CN read-only flag that `apply` never writes.
        var expected = original
        expected.localID = mutable.identifier
        expected.imageDataAvailable = roundTripped.imageDataAvailable

        #expect(roundTripped == expected)
    }

    // MARK: - Fetch-key contract

    @Test
    func trimmedFetchKeysCoverEveryMappedConsumerField() {
        let keys = Set(CNContactStoreAdapter.keys.compactMap { $0 as? String })

        // Debug and Release use the same app id and entitlements, so Contacts
        // notes are part of the main fetch/edit contract in both configurations.
        #expect(keys.contains(CNContactNoteKey))

        // Contacts documents identifier as ALWAYS fetched. It remains mapped
        // into Contact.localID, but explicitly requesting it is redundant.
        #expect(!keys.contains(CNContactIdentifierKey))

        // Image BYTES load on demand via separate key sets; the bulk fetch
        // carries only the presence flag.
        #expect(!keys.contains(CNContactImageDataKey))
        #expect(!keys.contains(CNContactThumbnailImageDataKey))
        #expect(keys.contains(CNContactImageDataAvailableKey))

        // Exact contract: every OPTIONAL property `toContact` reads is here.
        // A missing entry can throw CNContactPropertyNotFetchedException at
        // runtime; an extra entry silently adds cost to every unified fetch.
        let expected = Set([
            CNContactTypeKey,
            CNContactNamePrefixKey,
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactFamilyNameKey,
            CNContactPreviousFamilyNameKey,
            CNContactNameSuffixKey,
            CNContactNicknameKey,
            CNContactPhoneticGivenNameKey,
            CNContactPhoneticMiddleNameKey,
            CNContactPhoneticFamilyNameKey,
            CNContactJobTitleKey,
            CNContactDepartmentNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneticOrganizationNameKey,
            CNContactNoteKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactPostalAddressesKey,
            CNContactUrlAddressesKey,
            CNContactBirthdayKey,
            CNContactNonGregorianBirthdayKey,
            CNContactDatesKey,
            CNContactSocialProfilesKey,
            CNContactInstantMessageAddressesKey,
            CNContactRelationsKey,
            CNContactImageDataAvailableKey,
        ])
        #expect(keys == expected)
    }

    // MARK: - Full-fetch single-flight

    @Test
    func concurrentFetchAllCallersShareOneUnderlyingUnifiedFetch() async throws {
        let spy = BlockingFetchAllSpy()
        let adapter = CNContactStoreAdapter(fetchAllWork: { _, keys in
            spy.fetch(keys: keys)
        })

        let first = Task { try await adapter.fetchAll() }
        #expect(spy.waitForFetchCount(1))

        let second = Task { try await adapter.fetchAll() }
        var joined = false
        for _ in 0..<1_000 {
            if await adapter.inFlightFetchAllCallerCountForTesting == 2 {
                joined = true
                break
            }
            await Task.yield()
        }
        #expect(joined)

        spy.releaseFirstFetch()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(spy.fetchCount == 1)
        #expect(firstResult == secondResult)
        #expect(firstResult.first?.givenName == "Snapshot 1")
        #expect(spy.requestedKeys == Set(CNContactStoreAdapter.keys.compactMap { $0 as? String }))
    }

    @Test @MainActor
    func concurrentRepositoryReloadsShareOneUnderlyingUnifiedFetch() async {
        let spy = BlockingFetchAllSpy()
        let adapter = CNContactStoreAdapter(fetchAllWork: { _, keys in
            spy.fetch(keys: keys)
        })
        let repository = ContactsRepository(
            contacts: adapter,
            notificationCenter: NotificationCenter()
        )

        let first = Task { @MainActor in await repository.reload() }
        var started = false
        for _ in 0..<1_000 {
            if spy.fetchCount == 1 {
                started = true
                break
            }
            await Task.yield()
        }
        #expect(started)

        // This second reload supersedes the first repository generation, but
        // it must join rather than enqueue another full Contacts enumeration.
        let second = Task { @MainActor in await repository.reload() }
        var joined = false
        for _ in 0..<1_000 {
            if await adapter.inFlightFetchAllCallerCountForTesting == 2 {
                joined = true
                break
            }
            await Task.yield()
        }
        #expect(joined)

        spy.releaseFirstFetch()
        await first.value
        await second.value

        #expect(spy.fetchCount == 1)
        #expect(repository.contacts.first?.givenName == "Snapshot 1")
        #expect(repository.isLoading == false)
    }

    @Test @MainActor
    func contactStoreFullReloadAfterCompletedFetchStartsFreshFlight() async throws {
        let spy = BlockingFetchAllSpy(blockFirstFetch: false)
        let adapter = CNContactStoreAdapter(fetchAllWork: { _, keys in
            spy.fetch(keys: keys)
        })
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: adapter, notificationCenter: center)

        await repository.reload()
        #expect(spy.fetchCount == 1)
        #expect(repository.contacts.first?.givenName == "Snapshot 1")

        // A real ContactChangeWatcher full-reload notification after the first
        // flight completed must not reuse its result. Await the repository's
        // completion post so the assertion observes the settled second reload.
        var token: NSObjectProtocol?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            token = center.addObserver(
                forName: .contactsRepositoryDidReload,
                object: repository,
                queue: nil
            ) { _ in
                continuation.resume()
            }
            center.post(
                name: .guessWhoContactsDidChange,
                object: nil,
                userInfo: [GuessWhoContactsDidChangeKey.requiresFullReload: true]
            )
        }
        if let token { center.removeObserver(token) }

        #expect(spy.fetchCount == 2)
        #expect(repository.contacts.first?.givenName == "Snapshot 2")
    }

    // MARK: - Save-request author tag

    @Test
    func makeSaveRequestTagsTransactionAuthor() {
        // Every write must carry the app's transactionAuthor, or the change
        // watcher's self-exclusion breaks and our own saves come back as
        // phantom external edits.
        let request = CNContactStoreAdapter.makeSaveRequest()
        #expect(request.transactionAuthor == CNContactStoreAdapter.transactionAuthor)
        #expect(CNContactStoreAdapter.transactionAuthor == "com.milestonemade.guesswho")
    }

    // MARK: - Authorization collapse

    @Test
    func mapAuthorizationCollapsesStatusesToNeutralCases() {
        #expect(CNContactStoreAdapter.mapAuthorization(.authorized) == .authorized)
        // Limited access still reads/writes the granted subset — the app
        // treats it as authorized rather than surfacing a fifth state.
        // `.limited` is iOS-only (`@available(macOS, unavailable)`): the
        // adapter may MATCH it in a switch on any platform, but a test can
        // only CONSTRUCT it where it exists, so this assertion runs on iOS
        // test hosts and compiles out under `swift test` on macOS.
        #if os(iOS) || os(visionOS)
        #expect(CNContactStoreAdapter.mapAuthorization(.limited) == .authorized)
        #endif
        #expect(CNContactStoreAdapter.mapAuthorization(.denied) == .denied)
        #expect(CNContactStoreAdapter.mapAuthorization(.restricted) == .restricted)
        #expect(CNContactStoreAdapter.mapAuthorization(.notDetermined) == .notDetermined)
    }
}

/// Thread-safe stand-in for the adapter's blocking CN enumeration. The first
/// call can be parked on the adapter work queue while a second actor caller
/// joins the same flight. Each genuine invocation returns a distinct snapshot,
/// making accidental reuse after completion visible as a value failure as well
/// as a count failure.
private final class BlockingFetchAllSpy: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockFirstFetch: Bool
    private var firstFetchReleased = false
    private var _fetchCount = 0
    private var _requestedKeys: Set<String> = []

    init(blockFirstFetch: Bool = true) {
        self.blockFirstFetch = blockFirstFetch
    }

    func fetch(keys: [CNKeyDescriptor]) -> [Contact] {
        condition.lock()
        _fetchCount += 1
        let invocation = _fetchCount
        _requestedKeys = Set(keys.compactMap { $0 as? String })
        condition.broadcast()
        while blockFirstFetch && invocation == 1 && !firstFetchReleased {
            condition.wait()
        }
        condition.unlock()
        return [Contact(localID: "contact", givenName: "Snapshot \(invocation)")]
    }

    func waitForFetchCount(_ expected: Int) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        condition.lock()
        defer { condition.unlock() }
        while _fetchCount < expected {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseFirstFetch() {
        condition.lock()
        firstFetchReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var fetchCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return _fetchCount
    }

    var requestedKeys: Set<String> {
        condition.lock()
        defer { condition.unlock() }
        return _requestedKeys
    }
}
#endif
