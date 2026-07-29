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

    @Test func tlsFieldsDecode_andIdentifySource() throws {
        let profile = try decode(#"""
        {
          "source": "tls",
          "fullName": "Amanda Roberts",
          "nickname": "Mandy",
          "role": "Faculty, Higher Ed",
          "ama": ["Higher-ed innovation", "Design research"]
        }
        """#)
        #expect(profile.isTLSProfile)
        #expect(!profile.isLinkedInProfile)
        #expect(profile.sourceDisplayName == "TLS")
        #expect(profile.nickname == "Mandy")
        #expect(profile.role == "Faculty, Higher Ed")
        #expect(profile.ama == ["Higher-ed innovation", "Design research"])
    }

    @Test func browserPayloadDecodesSingleProfileBackwardCompatibly() throws {
        let payload = try JSONDecoder().decode(
            BrowserImportPayload.self,
            from: Data(#"{"fullName":"Ada Lovelace"}"#.utf8)
        )
        #expect(payload.profiles.map(\.fullName) == ["Ada Lovelace"])
    }

    @Test func browserPayloadDecodesOrderedBatch_andInheritsSourceMetadata() throws {
        let payload = try JSONDecoder().decode(
            BrowserImportPayload.self,
            from: Data(#"""
            {
              "source": "tls",
              "sourceUrl": "https://tls26-s2-people.netlify.app/",
              "profiles": [
                {"fullName": "First Person"},
                {"fullName": "Second Person", "sourceUrl": "https://example.com/override"}
              ]
            }
            """#.utf8)
        )
        #expect(payload.profiles.map(\.fullName) == ["First Person", "Second Person"])
        #expect(payload.profiles.allSatisfy { $0.isTLSProfile })
        #expect(payload.profiles[0].sourceUrl == "https://tls26-s2-people.netlify.app/")
        #expect(payload.profiles[1].sourceUrl == "https://example.com/override")
    }
}
