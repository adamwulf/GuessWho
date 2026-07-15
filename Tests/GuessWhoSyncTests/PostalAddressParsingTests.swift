import Foundation
import Testing
@testable import GuessWhoSync

/// `PostalAddress.parse(fromFullAddress:)` — the paste-a-full-address
/// splitter behind the street field in the address editor.
@Suite("PostalAddressParsing")
struct PostalAddressParsingTests {

    @Test
    func parsesSingleLineCommaSeparatedAddress() throws {
        let parsed = try #require(
            PostalAddress.parse(fromFullAddress: "1 Infinite Loop, Cupertino, CA 95014")
        )
        #expect(parsed.street == "1 Infinite Loop")
        #expect(parsed.city == "Cupertino")
        #expect(parsed.state == "CA")
        #expect(parsed.postalCode == "95014")
    }

    @Test
    func parsesMultilineAddress() throws {
        let parsed = try #require(
            PostalAddress.parse(fromFullAddress: """
                1600 Pennsylvania Ave NW
                Washington, DC 20500
                """)
        )
        #expect(parsed.street == "1600 Pennsylvania Ave NW")
        #expect(parsed.city == "Washington")
        #expect(parsed.state == "DC")
        #expect(parsed.postalCode == "20500")
    }

    @Test
    func parsesAddressWithCountry() throws {
        let parsed = try #require(
            PostalAddress.parse(fromFullAddress: "1 Infinite Loop, Cupertino, CA 95014, USA")
        )
        #expect(parsed.city == "Cupertino")
        #expect(!parsed.country.isEmpty)
    }

    @Test
    func cityStateWithoutStreetStillParses() throws {
        // No street component, but two components is enough to split.
        let parsed = try #require(
            PostalAddress.parse(fromFullAddress: "Cupertino, CA 95014")
        )
        #expect(parsed.street.isEmpty)
        #expect(parsed.city == "Cupertino")
        #expect(parsed.state == "CA")
    }

    @Test
    func neverEmitsAnISOCountryCode() throws {
        let parsed = try #require(
            PostalAddress.parse(fromFullAddress: "1 Infinite Loop, Cupertino, CA 95014, USA")
        )
        #expect(parsed.isoCountryCode.isEmpty)
    }

    // MARK: - Inputs that must NOT parse (ordinary street-field typing)

    @Test
    func bareStreetDoesNotParse() {
        #expect(PostalAddress.parse(fromFullAddress: "123 Main St") == nil)
    }

    @Test
    func partialTypingWithCommaDoesNotParse() {
        #expect(PostalAddress.parse(fromFullAddress: "Apt 4, 123 Main St") == nil)
    }

    @Test
    func emptyAndWhitespaceDoNotParse() {
        #expect(PostalAddress.parse(fromFullAddress: "") == nil)
        #expect(PostalAddress.parse(fromFullAddress: "  \n ") == nil)
    }

    @Test
    func plainProseDoesNotParse() {
        #expect(PostalAddress.parse(fromFullAddress: "call me tomorrow, maybe thursday") == nil)
    }
}
