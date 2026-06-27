import Foundation
import Testing
@testable import GuessWhoSync

@Suite("LinkedInURL normalization")
struct LinkedInURLTests {
    @Test("slug extraction handles scheme/www/trailing-slash/case/query")
    func slug() {
        #expect(LinkedInURL.slug(from: "https://www.linkedin.com/in/adamwulf/") == "adamwulf")
        #expect(LinkedInURL.slug(from: "https://www.linkedin.com/in/adamwulf") == "adamwulf")
        #expect(LinkedInURL.slug(from: "linkedin.com/in/AdamWulf") == "adamwulf")
        #expect(LinkedInURL.slug(from: "https://m.linkedin.com/in/adamwulf?trk=foo") == "adamwulf")
        #expect(LinkedInURL.slug(from: "https://www.linkedin.com/in/adamwulf/details/experience/") == "adamwulf")
        #expect(LinkedInURL.slug(from: "/in/adamwulf/") == "adamwulf")
    }

    @Test("slug is nil for non-profile URLs")
    func slugNil() {
        #expect(LinkedInURL.slug(from: "https://www.linkedin.com/company/acme") == nil)
        #expect(LinkedInURL.slug(from: "https://example.com") == nil)
        #expect(LinkedInURL.slug(from: "") == nil)
        #expect(LinkedInURL.slug(from: "https://www.linkedin.com/in/") == nil)
    }

    @Test("canonicalKey collapses variants to the same key")
    func canonical() {
        let key = "linkedin.com/in/adamwulf"
        #expect(LinkedInURL.canonicalKey("https://www.linkedin.com/in/adamwulf/") == key)
        #expect(LinkedInURL.canonicalKey("http://linkedin.com/in/AdamWulf") == key)
        #expect(LinkedInURL.canonicalKey("https://m.linkedin.com/in/adamwulf?x=1") == key)
        #expect(LinkedInURL.canonicalKey("https://example.com") == nil)
    }

    @Test("sameProfile matches across formats and rejects different profiles")
    func sameProfile() {
        #expect(LinkedInURL.sameProfile(
            "https://www.linkedin.com/in/adamwulf/",
            "https://www.linkedin.com/in/adamwulf"
        ))
        #expect(LinkedInURL.sameProfile(
            "linkedin.com/in/AdamWulf",
            "https://m.linkedin.com/in/adamwulf?trk=x"
        ))
        #expect(!LinkedInURL.sameProfile(
            "https://www.linkedin.com/in/adamwulf",
            "https://www.linkedin.com/in/someoneelse"
        ))
        #expect(!LinkedInURL.sameProfile("https://example.com", "https://example.com"))
    }

    @Test("isLinkedIn recognizes profile links")
    func isLinkedIn() {
        #expect(LinkedInURL.isLinkedIn("https://www.linkedin.com/in/adamwulf"))
        #expect(!LinkedInURL.isLinkedIn("https://example.com/in/foo"))
        #expect(!LinkedInURL.isLinkedIn("https://twitter.com/adamwulf"))
    }
}
