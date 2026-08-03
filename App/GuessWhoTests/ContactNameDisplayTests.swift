import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

/// How a contact's name reads wherever the app shows it: the detail header's
/// plain string and the list rows' attributed string are the same name, built
/// from the same parts, so a nickname shows up identically in both.
@Suite("Contact name display")
struct ContactNameDisplayTests {
    /// The runs of an attributed string as `(text, isBold)` pairs — enough to
    /// assert both the wording and which part carries the heavier weight.
    private func runs(_ attributed: NSAttributedString) -> [(text: String, isBold: Bool)] {
        var result: [(String, Bool)] = []
        attributed.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            let font = value as? UIFont
            let isBold = font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
            result.append((attributed.attributedSubstring(from: range).string, isBold))
        }
        return result
    }

    @Test
    func aNicknameSitsQuotedBetweenTheGivenAndFamilyNames() {
        let contact = Contact(givenName: "Kejing", familyName: "Zhang", nickname: "Kathy")
        #expect(contact.displayNameWithNickname == "Kejing \"Kathy\" Zhang")
    }

    @Test
    func withoutANicknameTheNameIsUnchanged() {
        let contact = Contact(givenName: "Kejing", familyName: "Zhang")
        #expect(contact.displayNameWithNickname == "Kejing Zhang")
        #expect(contact.displayNameWithNickname == contact.displayName)
    }

    @Test
    func aNicknameThatRepeatsANameBesideItIsDropped() {
        // Nobody should read `Kathy "Kathy" Zhang` — a nickname only earns its
        // quotes when it says something the names beside it don't.
        let repeatsGiven = Contact(givenName: "Kathy", familyName: "Zhang", nickname: "kathy")
        #expect(repeatsGiven.displayNameWithNickname == "Kathy Zhang")

        let repeatsFamily = Contact(familyName: "Zhang", nickname: "zhang")
        #expect(repeatsFamily.displayNameWithNickname == "Zhang")
    }

    @Test
    func aWhitespaceOnlyNicknameIsNoNicknameAtAll() {
        // Pins the trim-then-test order: check emptiness first and this renders
        // an empty pair of quotes.
        let contact = Contact(givenName: "Kejing", familyName: "Zhang", nickname: "   ")
        #expect(contact.displayNameWithNickname == "Kejing Zhang")
    }

    @Test
    func aNicknameShowsWithOnlyOneOfTheTwoNames() {
        let noFamily = Contact(givenName: "Kejing", nickname: "Kathy")
        #expect(noFamily.displayNameWithNickname == "Kejing \"Kathy\"")

        let noGiven = Contact(familyName: "Zhang", nickname: "Kathy")
        #expect(noGiven.displayNameWithNickname == "\"Kathy\" Zhang")
    }

    @Test
    func aNicknameOnlyContactIsNotQuoted() {
        // With no given or family name to bracket, the nickname IS the name —
        // quoting it would read as a scare quote, so `displayName` stands.
        let contact = Contact(nickname: "Kathy")
        #expect(contact.displayNameWithNickname == "Kathy")

        let org = Contact(contactType: .organization, nickname: "The Shop", organizationName: "Acme")
        #expect(org.displayNameWithNickname == "Acme")
    }

    @Test
    func surroundingWhitespaceNeverLeaksIntoTheName() {
        let contact = Contact(givenName: " Kejing ", familyName: " Zhang ", nickname: " Kathy ")
        #expect(contact.displayNameWithNickname == "Kejing \"Kathy\" Zhang")
    }

    @Test
    func onlyTheFamilyNameIsBoldInARow() {
        let contact = Contact(givenName: "Kejing", familyName: "Zhang", nickname: "Kathy")
        let parts = runs(contact.nameAttributedString)
        #expect(parts.map(\.text) == ["Kejing \"Kathy\" ", "Zhang"])
        #expect(parts.map(\.isBold) == [false, true])
    }

    @Test
    func aRowWithNoFamilyNameHasNoBoldRun() {
        let contact = Contact(givenName: "Kejing", nickname: "Kathy")
        let parts = runs(contact.nameAttributedString)
        #expect(parts.map(\.text) == ["Kejing \"Kathy\""])
        #expect(parts.allSatisfy { !$0.isBold })
    }

    @Test
    func aRowWithNoGivenNameLeadsWithTheQuotedNickname() {
        // The one branch where the regular-weight run is nothing but the
        // nickname — and so the only place a stray trailing space could hide.
        let contact = Contact(familyName: "Zhang", nickname: "Kathy")
        let parts = runs(contact.nameAttributedString)
        #expect(parts.map(\.text) == ["\"Kathy\" ", "Zhang"])
        #expect(parts.map(\.isBold) == [false, true])
    }

    @Test
    func aRowWithOnlyAFamilyNameIsAllBold() {
        let parts = runs(Contact(familyName: "Zhang").nameAttributedString)
        #expect(parts.map(\.text) == ["Zhang"])
        #expect(parts.map(\.isBold) == [true])
    }

    @Test
    func anOrganizationRowFallsBackToItsDisplayName() {
        let org = Contact(contactType: .organization, organizationName: "Acme")
        let parts = runs(org.nameAttributedString)
        #expect(parts.map(\.text) == ["Acme"])
        #expect(parts.allSatisfy { !$0.isBold })
    }

    /// Every name shape the composition has to handle. The header and the row
    /// build their text with two separate hand-written joins, so the invariant
    /// below is worth checking against all of these, not just the headline case.
    private var everyNameShape: [Contact] {
        [
            Contact(givenName: "Kejing", familyName: "Zhang", nickname: "Kathy"),
            Contact(givenName: "Kejing", familyName: "Zhang"),
            Contact(givenName: "Kejing", nickname: "Kathy"),
            Contact(familyName: "Zhang", nickname: "Kathy"),
            Contact(givenName: "Kathy", familyName: "Zhang", nickname: "kathy"),
            Contact(givenName: " Kejing ", familyName: " Zhang ", nickname: " Kathy "),
            Contact(givenName: "Kejing", familyName: "Zhang", nickname: "   "),
            Contact(nickname: "Kathy"),
            Contact(contactType: .organization, nickname: "The Shop", organizationName: "Acme"),
            Contact(),
        ]
    }

    @Test
    func theRowAndTheHeaderAlwaysShowTheSameName() {
        for contact in everyNameShape {
            #expect(contact.nameAttributedString.string == contact.displayNameWithNickname)
        }
    }
}
