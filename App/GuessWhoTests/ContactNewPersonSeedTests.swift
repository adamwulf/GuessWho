import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

/// The seed behind every "add this person" editor that starts from an email
/// address and a display name: an event invitee and a Mail recipient.
@Suite("New person seed")
struct ContactNewPersonSeedTests {

    private let email = "jane@example.com"

    @Test
    func splitsAFullNameIntoItsParts() {
        let seed = Contact.newPersonSeed(name: "  Dr. Jane Q. Doe Jr. ", email: email)
        #expect(seed.contactType == .person)
        #expect(seed.namePrefix == "Dr.")
        #expect(seed.givenName == "Jane")
        #expect(seed.middleName == "Q.")
        #expect(seed.familyName == "Doe")
        #expect(seed.nameSuffix == "Jr.")
        #expect(seed.emailAddresses == [LabeledValue(label: "", value: email)])
    }

    @Test
    func splitsGivenAndFamilyName() {
        let seed = Contact.newPersonSeed(name: "Jane Doe", email: email)
        #expect(seed.givenName == "Jane")
        #expect(seed.familyName == "Doe")
        #expect(seed.namePrefix.isEmpty && seed.middleName.isEmpty && seed.nameSuffix.isEmpty)
    }

    @Test(arguments: [nil, "", "   ", "jane@example.com", "JANE@Example.com"] as [String?])
    func leavesTheNameEmptyWhenThereIsNoRealName(_ name: String?) {
        let seed = Contact.newPersonSeed(name: name, email: email)
        #expect(seed.namePrefix.isEmpty)
        #expect(seed.givenName.isEmpty)
        #expect(seed.middleName.isEmpty)
        #expect(seed.familyName.isEmpty)
        #expect(seed.nameSuffix.isEmpty)
        #expect(seed.emailAddresses == [LabeledValue(label: "", value: email)])
    }
}
