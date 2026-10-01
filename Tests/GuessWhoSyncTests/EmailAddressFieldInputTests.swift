import Foundation
import Testing
@testable import GuessWhoSync

/// What a contact's email field keeps when text is pasted or typed into it.
/// See `EmailAddressFieldInput`.
@Suite("Email address field input")
struct EmailAddressFieldInputTests {
    @Test
    func displayNameFormCollapsesToTheAddress() {
        #expect(EmailAddressFieldInput.normalized("Saira Cooper <saira.cooper@rice.edu>") == "saira.cooper@rice.edu")
    }

    @Test
    func quotedDisplayNameCollapsesToTheAddress() {
        #expect(EmailAddressFieldInput.normalized("\"Cooper, Saira\" <saira.cooper@rice.edu>") == "saira.cooper@rice.edu")
        // Some clients use the address itself as the display name.
        #expect(EmailAddressFieldInput.normalized("\"saira.cooper@rice.edu\" <saira.cooper@rice.edu>") == "saira.cooper@rice.edu")
    }

    @Test
    func bracketsWithoutANameCollapseToTheAddress() {
        #expect(EmailAddressFieldInput.normalized("<saira.cooper@rice.edu>") == "saira.cooper@rice.edu")
    }

    @Test
    func surroundingWhitespaceIsDropped() {
        #expect(EmailAddressFieldInput.normalized("  Saira Cooper < saira.cooper@rice.edu >\n") == "saira.cooper@rice.edu")
    }

    @Test
    func addressCaseIsKept() {
        #expect(EmailAddressFieldInput.normalized("Saira Cooper <Saira.Cooper@Rice.edu>") == "Saira.Cooper@Rice.edu")
    }

    @Test
    func textThatIsNotADisplayNameAddressIsUntouched() {
        let untouched = [
            "",
            " ",
            "saira.cooper@rice.edu",
            // Whitespace a user is typing must survive.
            "saira.cooper@rice.edu ",
            // Still being typed: no closing bracket yet.
            "Saira Cooper <saira.cooper@ri",
            "Saira Cooper",
        ]
        for text in untouched {
            #expect(EmailAddressFieldInput.normalized(text) == text)
        }
    }

    @Test
    func bracketedTextThatIsNotAnAddressIsUntouched() {
        let untouched = [
            "Saira Cooper <>",
            "Saira Cooper <saira>",
            "Saira Cooper <@rice.edu>",
            "Saira Cooper <saira@>",
            "Saira Cooper <saira@@rice.edu>",
            "Saira Cooper <saira cooper@rice.edu>",
            // Text after the closing bracket.
            "Saira Cooper <saira.cooper@rice.edu> (work)",
        ]
        for text in untouched {
            #expect(EmailAddressFieldInput.normalized(text) == text)
        }
    }

    @Test
    func severalAddressesAreLeftForTheUserToFix() {
        let text = "Saira Cooper <saira.cooper@rice.edu>, Ann Lee <ann.lee@rice.edu>"
        #expect(EmailAddressFieldInput.normalized(text) == text)
    }
}
