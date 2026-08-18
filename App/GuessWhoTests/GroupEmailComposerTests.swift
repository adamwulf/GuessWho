import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

/// The pure logic behind "Email All Members": which addresses a group resolves
/// to, and the `mailto:` URLs that address them. Decided without UIKit or a
/// repository, so it is testable here — the same split as `AddToGroupMenuTests`.
@Suite("Group email composer")
struct GroupEmailComposerTests {
    private func member(_ given: String, emails: [String]) -> Contact {
        Contact(
            givenName: given,
            familyName: "Member",
            emailAddresses: emails.map { LabeledValue(label: "home", value: $0) }
        )
    }

    // MARK: - Recipients

    @Test
    func onlyTheFirstEmailOfEachMemberIsUsed() {
        let members = [
            member("Ada", emails: ["ada@x.com", "ada@work.com"]),
            member("Alan", emails: ["alan@x.com"]),
        ]
        #expect(GroupEmailComposer.recipients(for: members) == ["ada@x.com", "alan@x.com"])
    }

    @Test
    func membersWithoutAnEmailAreSkipped() {
        let members = [
            member("Ada", emails: ["ada@x.com"]),
            member("Grace", emails: []),
            member("Alan", emails: ["alan@x.com"]),
        ]
        #expect(GroupEmailComposer.recipients(for: members) == ["ada@x.com", "alan@x.com"])
    }

    @Test
    func duplicateAddressesAreCollapsedCaseInsensitivelyKeepingTheFirstSpelling() {
        let members = [
            member("Ada", emails: ["Ada@x.com"]),
            member("Ada again", emails: ["ada@x.com"]),
        ]
        #expect(GroupEmailComposer.recipients(for: members) == ["Ada@x.com"])
    }

    @Test
    func surroundingWhitespaceIsTrimmedAndBlankAddressesAreDropped() {
        let members = [
            member("Ada", emails: ["  ada@x.com  "]),
            member("Blank", emails: ["   "]),
        ]
        #expect(GroupEmailComposer.recipients(for: members) == ["ada@x.com"])
    }

    @Test
    func aGroupWithNoAddressesResolvesToNoRecipients() {
        #expect(GroupEmailComposer.recipients(for: [member("Grace", emails: [])]).isEmpty)
    }

    // MARK: - Combined URL

    @Test
    func theCombinedURLAddressesEveryRecipientWithCommas() {
        let url = GroupEmailComposer.combinedMailtoURL(recipients: ["ada@x.com", "alan@x.com"])
        #expect(url?.absoluteString == "mailto:ada@x.com,alan@x.com")
    }

    @Test
    func theCombinedURLIsNilWithNoRecipients() {
        #expect(GroupEmailComposer.combinedMailtoURL(recipients: []) == nil)
    }

    // MARK: - Individual URLs

    @Test
    func individualURLsAreOnePerRecipientInOrder() {
        let urls = GroupEmailComposer.individualMailtoURLs(recipients: ["ada@x.com", "alan@x.com"])
        #expect(urls.map(\.absoluteString) == ["mailto:ada@x.com", "mailto:alan@x.com"])
    }

    @Test
    func individualURLsAreEmptyWithNoRecipients() {
        #expect(GroupEmailComposer.individualMailtoURLs(recipients: []).isEmpty)
    }

    // MARK: - Encoding

    /// A `?` in an address would otherwise start the `mailto:` header section and
    /// truncate the recipient, so it must be percent-encoded rather than passed
    /// through raw.
    @Test
    func urlSignificantCharactersInAnAddressArePercentEncoded() {
        let url = GroupEmailComposer.combinedMailtoURL(recipients: ["od?d@x.com"])
        #expect(url?.absoluteString == "mailto:od%3Fd@x.com")
    }
}
