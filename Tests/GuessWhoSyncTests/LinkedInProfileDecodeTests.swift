import Foundation
import Testing
@testable import GuessWhoSync

@Suite("LinkedInProfile decode")
struct LinkedInProfileDecodeTests {

    private func decode(_ json: String) throws -> LinkedInProfile {
        try JSONDecoder().decode(LinkedInProfile.self, from: Data(json.utf8))
    }

    // Extension builds before the parse-profile.js fix forwarded the raw
    // mailto: href query along with the address. The Chrome extension updates
    // independently of the app, so decode must strip it defensively.
    @Test func emails_trackingQueryStripped() throws {
        let profile = try decode(#"""
        {"contactInfo": {"emails": [
            "me@example.com?trk=contact-info",
            "other@example.com?trk='contact-info'",
            "clean@example.com"
        ]}}
        """#)
        #expect(profile.contactInfo?.emails == [
            "me@example.com", "other@example.com", "clean@example.com",
        ])
    }

    @Test func emails_fragmentStripped_andWhitespaceTrimmed() throws {
        let profile = try decode(#"""
        {"contactInfo": {"emails": ["  me@example.com#frag  "]}}
        """#)
        #expect(profile.contactInfo?.emails == ["me@example.com"])
    }

    @Test func emails_queryOnlyValueDropsToNothing() throws {
        let profile = try decode(#"""
        {"contactInfo": {"emails": ["?trk=contact-info"]}}
        """#)
        #expect(profile.contactInfo?.emails == [])
    }
}
