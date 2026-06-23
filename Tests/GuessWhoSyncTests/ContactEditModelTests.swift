import Foundation
import Testing
@testable import GuessWhoSync

@Suite("ContactEditModel")
struct ContactEditModelTests {

    // MARK: - URL partition + re-merge

    @Test("Visible URL bucket hides every guesswho:// entry — well-formed and malformed")
    func testVisibleBucketHidesAllGuessWhoURLs() {
        let wellFormed = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
        )
        let malformed = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/not-a-uuid"
        )
        let userHome = LabeledValue(label: "home", value: "https://home.example.com")
        let userWork = LabeledValue(label: "work", value: "https://work.example.com")

        let contact = Contact(
            localID: "c",
            urlAddresses: [wellFormed, userHome, malformed, userWork]
        )
        var model = ContactEditModel(original: contact)

        // The user-facing binding sees only the two user URLs, in the
        // order they appear in the original — never the guesswho://
        // entries (well-formed or malformed).
        #expect(model.visibleURLAddresses == [userHome, userWork])
    }

    @Test("Editing a visible URL value re-merges with hidden entries on save, preserving original index")
    func testEditingVisibleURLPreservesGuessWhoOrdering() {
        let guessWho = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
        )
        let userHome = LabeledValue(label: "home", value: "https://home.example.com")
        let userWork = LabeledValue(label: "work", value: "https://work.example.com")

        // Order: user, guesswho, user. After the user renames userHome,
        // the saved order must remain [userHome', guesswho, userWork].
        let contact = Contact(localID: "c", urlAddresses: [userHome, guessWho, userWork])
        var model = ContactEditModel(original: contact)

        let renamed = LabeledValue(label: "home", value: "https://home.example.com/new")
        model.visibleURLAddresses = [renamed, userWork]

        #expect(model.edited.urlAddresses == [renamed, guessWho, userWork])
    }

    @Test("Adding a new user URL appends after existing entries; guesswho URL stays put")
    func testAddingUserURLAppendsAfter() {
        let guessWho = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
        )
        let userHome = LabeledValue(label: "home", value: "https://home.example.com")
        let added = LabeledValue(label: "blog", value: "https://blog.example.com")

        let contact = Contact(localID: "c", urlAddresses: [guessWho, userHome])
        var model = ContactEditModel(original: contact)

        model.visibleURLAddresses = [userHome, added]

        #expect(model.edited.urlAddresses == [guessWho, userHome, added])
    }

    @Test("Removing a visible URL drops one user slot from the end; guesswho URL persists")
    func testRemovingUserURLPreservesGuessWho() {
        let guessWho = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
        )
        let userHome = LabeledValue(label: "home", value: "https://home.example.com")
        let userWork = LabeledValue(label: "work", value: "https://work.example.com")

        let contact = Contact(localID: "c", urlAddresses: [userHome, guessWho, userWork])
        var model = ContactEditModel(original: contact)

        // User removes the first visible entry. The merge pairs by
        // visible-bucket position, so slot-0 of the original becomes
        // the first remaining visible (userWork), the guesswho slot
        // carries through, and slot-2 has no visible left to consume
        // and is dropped. Net: visible order wins, GuessWho still
        // present, one user slot lost — what the user asked for.
        model.visibleURLAddresses = [userWork]

        #expect(model.edited.urlAddresses == [userWork, guessWho])
        // The GuessWho URL must still be in the saved list — that's
        // the sidecar-binding-preservation guarantee.
        #expect(model.edited.urlAddresses.contains(guessWho))
    }

    @Test("Malformed guesswho URLs ride through visible-bucket-empty saves untouched")
    func testMalformedGuessWhoURLCarriesThrough() {
        let malformed = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/not-a-uuid"
        )
        let contact = Contact(localID: "c", urlAddresses: [malformed])
        var model = ContactEditModel(original: contact)

        // The user can't see or touch the malformed URL.
        #expect(model.visibleURLAddresses == [])

        // A no-op save (visible bucket re-assigned to the same empty
        // list) still carries the malformed URL through; reconcile
        // strips it later.
        model.visibleURLAddresses = []
        #expect(model.edited.urlAddresses == [malformed])
    }

    // MARK: - Birthday hasYear conversion

    @Test("birthdayHasYear initializes true when the original birthday has a year")
    func testBirthdayHasYearInitFromYearPresent() {
        var dc = DateComponents()
        dc.year = 1984
        dc.month = 6
        dc.day = 22
        let contact = Contact(localID: "c", birthday: dc)
        var model = ContactEditModel(original: contact)
        #expect(model.birthdayHasYear == true)
    }

    @Test("birthdayHasYear initializes false when the original birthday has no year")
    func testBirthdayHasYearInitFromYearMissing() {
        var dc = DateComponents()
        dc.month = 6
        dc.day = 22
        let contact = Contact(localID: "c", birthday: dc)
        var model = ContactEditModel(original: contact)
        #expect(model.birthdayHasYear == false)
    }

    @Test("Birthday no-year roundtrip preserves month/day with no year on save")
    func testBirthdayNoYearRoundtrip() throws {
        var original = DateComponents()
        original.month = 6
        original.day = 22
        let contact = Contact(localID: "c", birthday: original)
        var model = ContactEditModel(original: contact)
        let cal = Calendar(identifier: .gregorian)

        // Convert to Date for the DatePicker; sentinel year is in play
        // but invisible to the consumer.
        let asDate = try #require(model.birthdayAsDate(calendar: cal))

        // User clicks Save without changing anything: round-trip via
        // setBirthday should preserve month/day with no year.
        model.setBirthday(from: asDate, calendar: cal)

        #expect(model.edited.birthday?.year == nil)
        #expect(model.edited.birthday?.month == 6)
        #expect(model.edited.birthday?.day == 22)
        #expect(model.isDirty == true)
    }

    @Test("Birthday with-year roundtrip preserves the year on save")
    func testBirthdayWithYearRoundtrip() throws {
        var original = DateComponents()
        original.year = 1984
        original.month = 6
        original.day = 22
        let contact = Contact(localID: "c", birthday: original)
        var model = ContactEditModel(original: contact)
        let cal = Calendar(identifier: .gregorian)

        let asDate = try #require(model.birthdayAsDate(calendar: cal))
        model.setBirthday(from: asDate, calendar: cal)

        #expect(model.edited.birthday?.year == 1984)
        #expect(model.edited.birthday?.month == 6)
        #expect(model.edited.birthday?.day == 22)
    }

    @Test("Toggling birthdayHasYear false→true on a no-year birthday adds a real year on save")
    func testBirthdayHasYearToggleFalseToTrue() throws {
        // Reviewer-found regression: with the previous birthdayAsDate()
        // implementation, this sequence silently lost the year intent.
        var original = DateComponents()
        original.month = 6
        original.day = 22
        let contact = Contact(localID: "c", birthday: original)
        var model = ContactEditModel(original: contact)
        let cal = Calendar(identifier: .gregorian)
        #expect(model.birthdayHasYear == false)

        // User flips "Include year" on.
        model.birthdayHasYear = true
        // The DatePicker binding now reads birthdayAsDate() and feeds it
        // back through setBirthday — that round trip MUST succeed and
        // result in a real year being written.
        let asDate = try #require(model.birthdayAsDate(calendar: cal))
        model.setBirthday(from: asDate, calendar: cal)

        // The saved birthday should now have a year (the sentinel, since
        // the user didn't pick a new one — what matters is that a year
        // IS present, not that the user lost their month/day).
        #expect(model.edited.birthday?.year != nil)
        #expect(model.edited.birthday?.month == 6)
        #expect(model.edited.birthday?.day == 22)
    }

    @Test("Toggling birthdayHasYear true→false strips the year, preserving month/day")
    func testBirthdayHasYearToggleTrueToFalse() throws {
        var original = DateComponents()
        original.year = 1984
        original.month = 6
        original.day = 22
        let contact = Contact(localID: "c", birthday: original)
        var model = ContactEditModel(original: contact)
        let cal = Calendar(identifier: .gregorian)
        #expect(model.birthdayHasYear == true)

        // User flips "Include year" off; the row's toggle code re-writes
        // the birthday via setBirthday so the stored components reflect
        // the new shape.
        model.birthdayHasYear = false
        let asDate = try #require(model.birthdayAsDate(calendar: cal))
        model.setBirthday(from: asDate, calendar: cal)

        #expect(model.edited.birthday?.year == nil)
        #expect(model.edited.birthday?.month == 6)
        #expect(model.edited.birthday?.day == 22)
    }

    @Test("clearBirthday wipes the birthday and marks dirty")
    func testClearBirthday() {
        var dc = DateComponents()
        dc.year = 1984
        dc.month = 6
        dc.day = 22
        let contact = Contact(localID: "c", birthday: dc)
        var model = ContactEditModel(original: contact)

        model.clearBirthday()

        #expect(model.edited.birthday == nil)
        #expect(model.isDirty == true)
    }

    // MARK: - Save error categorization

    @Test("authorizationDenied CNError maps to .authorizationDenied")
    func testAuthorizationDeniedMapping() {
        let err = NSError(domain: "CNErrorDomain", code: 100, userInfo: [
            NSLocalizedDescriptionKey: "Access denied"
        ])
        #expect(ContactEditModel.saveErrorCategory(err) == .authorizationDenied)
    }

    @Test("recordDoesNotExist CNError maps to .recordDoesNotExist")
    func testRecordDoesNotExistMapping() {
        let err = NSError(domain: "CNErrorDomain", code: 200, userInfo: [
            NSLocalizedDescriptionKey: "Record does not exist"
        ])
        #expect(ContactEditModel.saveErrorCategory(err) == .recordDoesNotExist)
    }

    @Test("Non-CNErrorDomain errors fall through to .unknown with description")
    func testUnknownDomainMapping() {
        let err = NSError(domain: "SomethingElse", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Something else broke"
        ])
        #expect(
            ContactEditModel.saveErrorCategory(err) == .unknown("Something else broke")
        )
    }

    @Test("Unrecognized CNErrorDomain codes fall through to .unknown")
    func testUnrecognizedCNCodeMapping() {
        let err = NSError(domain: "CNErrorDomain", code: 9999, userInfo: [
            NSLocalizedDescriptionKey: "Brand new error"
        ])
        #expect(
            ContactEditModel.saveErrorCategory(err) == .unknown("Brand new error")
        )
    }

    // MARK: - Carry-through of non-edited fields

    @Test("Editing visible fields does not clear non-surfaced Contact fields on the edited struct")
    func testCarryThroughOfNonSurfacedFields() {
        var dc = DateComponents()
        dc.month = 6
        dc.day = 22

        let contact = Contact(
            localID: "c",
            givenName: "Ada",
            familyName: "Lovelace",
            previousFamilyName: "Byron",
            phoneticOrganizationName: "phonetic-org",
            phoneNumbers: [LabeledValue(label: "_$!<Mobile>!$_", value: "555-0123")],
            urlAddresses: [
                LabeledValue(
                    label: "GuessWho",
                    value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
                )
            ],
            nonGregorianBirthday: dc
        )
        var model = ContactEditModel(original: contact)

        // Simulate the user editing the given name.
        model.edited.givenName = "Augusta Ada"
        model.isDirty = true

        // The fields the editor doesn't expose must survive unchanged
        // on the edited struct — that's the carry-through contract.
        #expect(model.edited.previousFamilyName == "Byron")
        #expect(model.edited.phoneticOrganizationName == "phonetic-org")
        #expect(model.edited.nonGregorianBirthday == dc)
        // And the GuessWho URL is still in urlAddresses (it's there
        // because @State holds the whole struct; the URL section
        // binding just hides it from view).
        #expect(model.edited.urlAddresses.contains(where: {
            $0.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
        }))
    }

    // MARK: - New-contact seed initializer

    @Test("newContactSeed initializer starts dirty so Save fires on the prefilled seed immediately")
    func testNewContactSeedStartsDirty() {
        let seed = Contact(
            localID: "",
            givenName: "Jane",
            emailAddresses: [LabeledValue(label: "", value: "jane@example.com")]
        )
        let model = ContactEditModel(newContactSeed: seed)
        #expect(model.isDirty)
        #expect(model.edited.givenName == "Jane")
        #expect(model.edited.emailAddresses.first?.value == "jane@example.com")
    }

    @Test("Standard original initializer starts clean (regression check that newContactSeed didn't bleed)")
    func testOriginalInitializerStartsClean() {
        let contact = Contact(localID: "c1", givenName: "Existing")
        let model = ContactEditModel(original: contact)
        #expect(!model.isDirty)
    }
}
