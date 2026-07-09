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
    func fetchKeysIncludeNoteKeyAndCoverMappedFields() {
        let keys = Set(CNContactStoreAdapter.keys.compactMap { $0 as? String })

        // The app carries com.apple.developer.contacts.notes, so Contacts notes
        // are part of the main fetch/edit contract.
        #expect(keys.contains(CNContactNoteKey))

        // Image BYTES load on demand via separate key sets; the bulk fetch
        // carries only the presence flag.
        #expect(!keys.contains(CNContactImageDataKey))
        #expect(!keys.contains(CNContactThumbnailImageDataKey))
        #expect(keys.contains(CNContactImageDataAvailableKey))

        // Spot-check the fetch covers what `toContact` reads — a key missing
        // here throws CNContactPropertyNotFetchedException at runtime.
        #expect(keys.contains(CNContactIdentifierKey))
        #expect(keys.contains(CNContactTypeKey))
        #expect(keys.contains(CNContactGivenNameKey))
        #expect(keys.contains(CNContactPhoneNumbersKey))
        #expect(keys.contains(CNContactPostalAddressesKey))
        #expect(keys.contains(CNContactSocialProfilesKey))
        #expect(keys.contains(CNContactRelationsKey))
        #expect(keys.contains(CNContactDatesKey))
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
#endif
