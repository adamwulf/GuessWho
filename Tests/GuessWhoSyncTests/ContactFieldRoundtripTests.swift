import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// PLAN.md §9.1 — Contact field round-trips against the in-memory store.
/// Each test below maps 1:1 to a named test in the spec.
@Suite("ContactFieldRoundtrip")
struct ContactFieldRoundtripTests {

    // MARK: - Identity URL handling

    @Test
    func testAddingAndRemovingURLsPreservesGuessWhoURL() async throws {
        let store = InMemoryContactStore()
        let guessWho = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
        )
        let home = LabeledValue(label: "home", value: "https://home.example.com")
        let work = LabeledValue(label: "work", value: "https://work.example.com")

        // Start with just GuessWho.
        var contact = Contact(localID: "c", urlAddresses: [guessWho])
        try await store.save(contact)

        // Add a non-GuessWho URL — GuessWho still present.
        contact = try #require(try await store.fetch(localID: "c"))
        contact.urlAddresses.append(home)
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "c"))
        #expect(contact.urlAddresses.contains(guessWho))

        // Add a second non-GuessWho URL — GuessWho still present.
        contact.urlAddresses.append(work)
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "c"))
        #expect(contact.urlAddresses.contains(guessWho))

        // Remove both non-GuessWho URLs — GuessWho still present.
        contact.urlAddresses.removeAll { $0 == home || $0 == work }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "c"))
        #expect(contact.urlAddresses == [guessWho])
    }

    // MARK: - Scalar round-trips

    @Test
    func testRoundtripContactTypePersonAndOrganization() async throws {
        let store = InMemoryContactStore()

        let person = Contact(localID: "p", contactType: .person, givenName: "Ada")
        try await store.save(person)
        let fetchedPerson = try #require(try await store.fetch(localID: "p"))
        #expect(fetchedPerson.contactType == .person)

        let org = Contact(localID: "o", contactType: .organization, organizationName: "Acme")
        try await store.save(org)
        let fetchedOrg = try #require(try await store.fetch(localID: "o"))
        #expect(fetchedOrg.contactType == .organization)
    }

    @Test
    func testRoundtripNameFamilyPreservesEveryField() async throws {
        let store = InMemoryContactStore()
        let contact = Contact(
            localID: "n",
            namePrefix: "Dr.",
            givenName: "Augusta",
            middleName: "Ada",
            familyName: "King",
            previousFamilyName: "Byron",
            nameSuffix: "Esq.",
            nickname: "Ada",
            phoneticGivenName: "uh-GUS-tuh",
            phoneticMiddleName: "AY-duh",
            phoneticFamilyName: "king"
        )
        try await store.save(contact)
        let fetched = try #require(try await store.fetch(localID: "n"))
        #expect(fetched.namePrefix == "Dr.")
        #expect(fetched.givenName == "Augusta")
        #expect(fetched.middleName == "Ada")
        #expect(fetched.familyName == "King")
        #expect(fetched.previousFamilyName == "Byron")
        #expect(fetched.nameSuffix == "Esq.")
        #expect(fetched.nickname == "Ada")
        #expect(fetched.phoneticGivenName == "uh-GUS-tuh")
        #expect(fetched.phoneticMiddleName == "AY-duh")
        #expect(fetched.phoneticFamilyName == "king")
    }

    @Test
    func testRoundtripWorkFamilyPreservesEveryField() async throws {
        let store = InMemoryContactStore()
        let contact = Contact(
            localID: "w",
            jobTitle: "Countess of Lovelace",
            departmentName: "Analytical Engines",
            organizationName: "Analytical Engines Ltd.",
            phoneticOrganizationName: "an-uh-LIH-tih-kuhl EN-jinz"
        )
        try await store.save(contact)
        let fetched = try #require(try await store.fetch(localID: "w"))
        #expect(fetched.jobTitle == "Countess of Lovelace")
        #expect(fetched.departmentName == "Analytical Engines")
        #expect(fetched.organizationName == "Analytical Engines Ltd.")
        #expect(fetched.phoneticOrganizationName == "an-uh-LIH-tih-kuhl EN-jinz")
    }

    // MARK: - Date round-trips

    @Test
    func testRoundtripBirthdayPreservesCalendarIdentifier() async throws {
        let store = InMemoryContactStore()
        var birthday = DateComponents()
        birthday.calendar = Calendar(identifier: .gregorian)
        birthday.year = 1815
        birthday.month = 12
        birthday.day = 10

        let contact = Contact(localID: "b", birthday: birthday)
        try await store.save(contact)
        let fetched = try #require(try await store.fetch(localID: "b"))
        let fetchedBirthday = try #require(fetched.birthday)
        #expect(fetchedBirthday.year == 1815)
        #expect(fetchedBirthday.month == 12)
        #expect(fetchedBirthday.day == 10)
        #expect(fetchedBirthday.calendar?.identifier == .gregorian)
    }

    @Test
    func testRoundtripNonGregorianBirthdayPreservesCalendarIdentifier() async throws {
        let store = InMemoryContactStore()
        var hebrew = DateComponents()
        hebrew.calendar = Calendar(identifier: .hebrew)
        hebrew.year = 5576
        hebrew.month = 3
        hebrew.day = 10

        var gregorian = DateComponents()
        gregorian.calendar = Calendar(identifier: .gregorian)
        gregorian.year = 1815
        gregorian.month = 12
        gregorian.day = 10

        let contact = Contact(
            localID: "nb",
            birthday: gregorian,
            nonGregorianBirthday: hebrew
        )
        try await store.save(contact)
        let fetched = try #require(try await store.fetch(localID: "nb"))
        let fetchedHebrew = try #require(fetched.nonGregorianBirthday)
        #expect(fetchedHebrew.calendar?.identifier == .hebrew)
        #expect(fetchedHebrew.year == 5576)

        // The Gregorian birthday survives independently and keeps its identifier.
        let fetchedGregorian = try #require(fetched.birthday)
        #expect(fetchedGregorian.calendar?.identifier == .gregorian)
    }

    @Test
    func testRoundtripLabeledDatesPreserveLabelAndCalendarIdentifier() async throws {
        let store = InMemoryContactStore()
        var anniversary = DateComponents()
        anniversary.calendar = Calendar(identifier: .gregorian)
        anniversary.year = 1835
        anniversary.month = 7
        anniversary.day = 8

        var chineseFestival = DateComponents()
        chineseFestival.calendar = Calendar(identifier: .chinese)
        chineseFestival.year = 32
        chineseFestival.month = 5
        chineseFestival.day = 5

        let contact = Contact(
            localID: "ld",
            dates: [
                LabeledDate(label: "anniversary", value: anniversary),
                LabeledDate(label: "festival", value: chineseFestival),
            ]
        )
        try await store.save(contact)
        let fetched = try #require(try await store.fetch(localID: "ld"))
        #expect(fetched.dates.count == 2)

        let fetchedAnniversary = try #require(fetched.dates.first { $0.label == "anniversary" })
        #expect(fetchedAnniversary.value.calendar?.identifier == .gregorian)
        #expect(fetchedAnniversary.value.year == 1835)

        let fetchedFestival = try #require(fetched.dates.first { $0.label == "festival" })
        #expect(fetchedFestival.value.calendar?.identifier == .chinese)
        #expect(fetchedFestival.value.year == 32)
    }

    // MARK: - Structured-array CRUD

    @Test
    func testCRUDPhoneNumbers() async throws {
        let store = InMemoryContactStore()
        let mobile = LabeledValue(label: "mobile", value: "+15555550101")
        let work = LabeledValue(label: "work", value: "+15555550102")

        // create
        var contact = Contact(localID: "p", phoneNumbers: [mobile])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "p"))
        #expect(contact.phoneNumbers == [mobile])

        // update — add a second entry and mutate the first
        contact.phoneNumbers = [
            LabeledValue(label: "mobile", value: "+15555550199"),
            work,
        ]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "p"))
        #expect(contact.phoneNumbers.first?.value == "+15555550199")
        #expect(contact.phoneNumbers.contains(work))

        // delete
        contact.phoneNumbers.removeAll { $0.label == "work" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "p"))
        #expect(contact.phoneNumbers.count == 1)
        #expect(contact.phoneNumbers.first?.label == "mobile")
    }

    @Test
    func testCRUDEmailAddresses() async throws {
        let store = InMemoryContactStore()
        let home = LabeledValue(label: "home", value: "ada@example.com")
        let work = LabeledValue(label: "work", value: "ada@analyticalengines.example")

        var contact = Contact(localID: "e", emailAddresses: [home])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "e"))
        #expect(contact.emailAddresses == [home])

        contact.emailAddresses = [
            LabeledValue(label: "home", value: "ada+new@example.com"),
            work,
        ]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "e"))
        #expect(contact.emailAddresses.first?.value == "ada+new@example.com")
        #expect(contact.emailAddresses.contains(work))

        contact.emailAddresses.removeAll { $0.label == "work" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "e"))
        #expect(contact.emailAddresses.count == 1)
        #expect(contact.emailAddresses.first?.label == "home")
    }

    @Test
    func testCRUDPostalAddresses() async throws {
        let store = InMemoryContactStore()
        let home = LabeledPostalAddress(
            label: "home",
            value: PostalAddress(
                street: "1 Babbage Way",
                subLocality: "Bloomsbury",
                city: "London",
                subAdministrativeArea: "Greater London",
                state: "England",
                postalCode: "WC1A 1AA",
                country: "United Kingdom",
                isoCountryCode: "GB"
            )
        )
        let work = LabeledPostalAddress(
            label: "work",
            value: PostalAddress(
                street: "1 Infinite Loop",
                subLocality: "Mariani",
                city: "Cupertino",
                subAdministrativeArea: "Santa Clara",
                state: "CA",
                postalCode: "95014",
                country: "United States",
                isoCountryCode: "US"
            )
        )

        var contact = Contact(localID: "pa", postalAddresses: [home])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "pa"))
        #expect(contact.postalAddresses == [home])

        // update — mutate every component on the first entry, add a second
        let mutatedHome = LabeledPostalAddress(
            label: "home-2",
            value: PostalAddress(
                street: "2 Babbage Way",
                subLocality: "Marylebone",
                city: "London",
                subAdministrativeArea: "Greater London",
                state: "England",
                postalCode: "NW1 6XE",
                country: "United Kingdom",
                isoCountryCode: "GB"
            )
        )
        contact.postalAddresses = [mutatedHome, work]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "pa"))
        #expect(contact.postalAddresses[0] == mutatedHome)
        #expect(contact.postalAddresses[1] == work)

        // delete
        contact.postalAddresses.removeAll { $0.label == "work" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "pa"))
        #expect(contact.postalAddresses.count == 1)
        #expect(contact.postalAddresses.first?.label == "home-2")
    }

    @Test
    func testCRUDURLAddresses() async throws {
        let store = InMemoryContactStore()
        let guessWho = LabeledValue(
            label: "GuessWho",
            value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"
        )
        let home = LabeledValue(label: "home", value: "https://home.example.com")
        let work = LabeledValue(label: "work", value: "https://work.example.com")

        // create — GuessWho present from the start.
        var contact = Contact(localID: "u", urlAddresses: [guessWho, home])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "u"))
        #expect(contact.urlAddresses == [guessWho, home])

        // update — mutate the home URL, add a work URL.
        let updatedHome = LabeledValue(label: "home", value: "https://updated.example.com")
        contact.urlAddresses = [guessWho, updatedHome, work]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "u"))
        #expect(contact.urlAddresses == [guessWho, updatedHome, work])

        // delete — drop the work URL. GuessWho stays.
        contact.urlAddresses.removeAll { $0.label == "work" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "u"))
        #expect(contact.urlAddresses.contains(guessWho))
        #expect(!contact.urlAddresses.contains(work))
        #expect(contact.urlAddresses.count == 2)
    }

    @Test
    func testCRUDSocialProfiles() async throws {
        let store = InMemoryContactStore()
        let twitter = LabeledSocialProfile(
            label: "main",
            value: SocialProfile(
                urlString: "https://twitter.example/ada",
                username: "ada",
                userIdentifier: "u-1",
                service: "Twitter"
            )
        )
        let mastodon = LabeledSocialProfile(
            label: "secondary",
            value: SocialProfile(
                urlString: "https://mastodon.example/@ada",
                username: "ada",
                userIdentifier: "u-2",
                service: "Mastodon"
            )
        )

        var contact = Contact(localID: "sp", socialProfiles: [twitter])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "sp"))
        #expect(contact.socialProfiles == [twitter])

        // update — mutate every component of the first, add a second
        let updatedTwitter = LabeledSocialProfile(
            label: "primary",
            value: SocialProfile(
                urlString: "https://twitter.example/ada-new",
                username: "ada-new",
                userIdentifier: "u-99",
                service: "X"
            )
        )
        contact.socialProfiles = [updatedTwitter, mastodon]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "sp"))
        #expect(contact.socialProfiles[0] == updatedTwitter)
        #expect(contact.socialProfiles[1] == mastodon)

        // delete
        contact.socialProfiles.removeAll { $0.label == "secondary" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "sp"))
        #expect(contact.socialProfiles.count == 1)
        #expect(contact.socialProfiles.first?.label == "primary")
    }

    @Test
    func testCRUDInstantMessageAddresses() async throws {
        let store = InMemoryContactStore()
        let skype = LabeledInstantMessageAddress(
            label: "work",
            value: InstantMessageAddress(username: "ada.skype", service: "Skype")
        )
        let jabber = LabeledInstantMessageAddress(
            label: "personal",
            value: InstantMessageAddress(username: "ada@jabber.example", service: "Jabber")
        )

        var contact = Contact(localID: "im", instantMessageAddresses: [skype])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "im"))
        #expect(contact.instantMessageAddresses == [skype])

        // update — mutate every component, add a second
        let updatedSkype = LabeledInstantMessageAddress(
            label: "office",
            value: InstantMessageAddress(username: "ada.skype.new", service: "Teams")
        )
        contact.instantMessageAddresses = [updatedSkype, jabber]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "im"))
        #expect(contact.instantMessageAddresses[0] == updatedSkype)
        #expect(contact.instantMessageAddresses[1] == jabber)

        // delete
        contact.instantMessageAddresses.removeAll { $0.label == "personal" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "im"))
        #expect(contact.instantMessageAddresses.count == 1)
        #expect(contact.instantMessageAddresses.first?.label == "office")
    }

    @Test
    func testCRUDContactRelations() async throws {
        let store = InMemoryContactStore()
        let mother = LabeledContactRelation(
            label: "mother",
            value: ContactRelation(name: "Anne Isabella Milbanke")
        )
        let father = LabeledContactRelation(
            label: "father",
            value: ContactRelation(name: "Lord Byron")
        )

        var contact = Contact(localID: "cr", contactRelations: [mother])
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "cr"))
        #expect(contact.contactRelations == [mother])

        // update — mutate the name and label, add a second
        let updatedMother = LabeledContactRelation(
            label: "parent",
            value: ContactRelation(name: "Lady Byron")
        )
        contact.contactRelations = [updatedMother, father]
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "cr"))
        #expect(contact.contactRelations[0] == updatedMother)
        #expect(contact.contactRelations[1] == father)

        // delete
        contact.contactRelations.removeAll { $0.label == "father" }
        try await store.save(contact)
        contact = try #require(try await store.fetch(localID: "cr"))
        #expect(contact.contactRelations.count == 1)
        #expect(contact.contactRelations.first?.label == "parent")
    }

    // MARK: - Image data invariants (§7.2 / §7.4)

    @Test
    func testFetchAllDoesNotTouchImageBytes() async throws {
        let store = InMemoryContactStore()
        let contact = Contact(localID: "i", givenName: "Ada", imageDataAvailable: true)
        try await store.save(contact)
        await store.setImageData(Data([0xff]), thumbnail: Data([0xee]), for: "i")

        let baselineCount = await store.imageSidebandAccessCount
        let all = try await store.fetchAll()
        #expect(all.count == 1)
        // §7.4 — the bulk path returns the persisted flag unchanged and must
        // not peek at the sideband.
        #expect(await store.imageSidebandAccessCount == baselineCount)
        // The flag returned matches what was persisted (already true here).
        #expect(all.first?.imageDataAvailable == true)
    }

    @Test
    func testLoadImageDataReturnsBytesWhenAttached() async throws {
        let store = InMemoryContactStore()
        try await store.save(Contact(localID: "i", givenName: "Ada"))
        let bytes = Data([0x01, 0x02, 0x03])
        await store.setImageData(bytes, thumbnail: nil, for: "i")

        let fetched = try #require(try await store.fetch(localID: "i"))
        #expect(fetched.imageDataAvailable == true)
        let loaded = try await store.loadImageData(localID: "i")
        #expect(loaded == bytes)
    }

    @Test
    func testLoadThumbnailDataIsIndependentOfImage() async throws {
        let store = InMemoryContactStore()
        try await store.save(Contact(localID: "i", givenName: "Ada"))
        let thumb = Data([0xaa, 0xbb])
        await store.setImageData(nil, thumbnail: thumb, for: "i")

        let image = try await store.loadImageData(localID: "i")
        #expect(image == nil)
        let loadedThumb = try await store.loadThumbnailImageData(localID: "i")
        #expect(loadedThumb == thumb)
    }

    @Test
    func testLoadImageDataReturnsNilWhenNotAvailable() async throws {
        let store = InMemoryContactStore()
        try await store.save(Contact(localID: "i", givenName: "Ada", imageDataAvailable: false))

        let loaded = try await store.loadImageData(localID: "i")
        #expect(loaded == nil)
    }

    @Test
    func testLoadImageDataThrowsContactNotFoundForUnknownLocalID() async throws {
        let store = InMemoryContactStore()
        await #expect {
            try await store.loadImageData(localID: "ghost")
        } throws: { error in
            guard let cse = error as? ContactStoreError else { return false }
            if case .contactNotFound(let id) = cse { return id == "ghost" }
            return false
        }
    }

    @Test
    func testLoadImageDataReturnsNilWhenAvailableFlagIsStaleTrue() async throws {
        let store = InMemoryContactStore()
        // Persist with the flag set TRUE but no sideband bytes — simulates an
        // external mutation that wiped the bytes.
        try await store.save(Contact(localID: "i", givenName: "Ada", imageDataAvailable: true))

        let loaded = try await store.loadImageData(localID: "i")
        #expect(loaded == nil)

        // A follow-up fetch resets the flag to false.
        let refetched = try #require(try await store.fetch(localID: "i"))
        #expect(refetched.imageDataAvailable == false)
    }

    @Test
    func testLoadImageDataReturnsBytesWhenAvailableFlagIsStaleFalse() async throws {
        let store = InMemoryContactStore()
        // Persist with the flag FALSE.
        try await store.save(Contact(localID: "i", givenName: "Ada", imageDataAvailable: false))
        // Then attach bytes via the sideband — an external setter ran after
        // the last save.
        let bytes = Data([0xde, 0xad, 0xbe, 0xef])
        await store.setImageData(bytes, thumbnail: nil, for: "i")

        let loaded = try await store.loadImageData(localID: "i")
        #expect(loaded == bytes)

        // A follow-up fetch updates the stored flag to true.
        let refetched = try #require(try await store.fetch(localID: "i"))
        #expect(refetched.imageDataAvailable == true)
    }

    @Test
    func testSaveOnlyClearsSidebandOnTrueToFalseTransition() async throws {
        let store = InMemoryContactStore()

        // Case 1 — brand-new save with imageDataAvailable=false leaves the
        // sideband untouched.
        let bytes = Data([0xab, 0xcd])
        // Attach bytes BEFORE the first save (an external setter beat us).
        await store.setImageData(bytes, thumbnail: nil, for: "i")
        try await store.save(Contact(localID: "i", givenName: "Ada", imageDataAvailable: false))
        #expect(try await store.loadImageData(localID: "i") == bytes)

        // Case 2 — save with flag=false when the prior stored flag was also
        // false (after fetch auto-correct it is true now; so we need a fresh
        // localID for this case).
        try await store.save(Contact(localID: "j", givenName: "Bea", imageDataAvailable: false))
        await store.setImageData(bytes, thumbnail: nil, for: "j")
        // Persisted flag is still false (setImageData does not flip it).
        // Save again with false — sideband must remain.
        try await store.save(Contact(localID: "j", givenName: "Bea", imageDataAvailable: false))
        #expect(try await store.loadImageData(localID: "j") == bytes)

        // Case 3 — true→false transition DOES clear the sideband.
        var contactK = Contact(localID: "k", givenName: "Cal", imageDataAvailable: true)
        try await store.save(contactK)
        await store.setImageData(bytes, thumbnail: nil, for: "k")
        // Stored flag is currently true. Saving with false now transitions
        // true→false and clears the sideband.
        contactK.imageDataAvailable = false
        try await store.save(contactK)
        #expect(try await store.loadImageData(localID: "k") == nil)
    }
}
