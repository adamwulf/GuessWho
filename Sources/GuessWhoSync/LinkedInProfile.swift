import Foundation

/// A profile parsed from a LinkedIn page by the Safari Web Extension and handed
/// to the app. This is the package-vended shape the extension's content script
/// produces (see `App/GuessWhoLinkedIn/Resources/parse-profile.js`) — the app
/// decodes the handoff JSON into this, then asks the package to match it.
///
/// All fields are optional/best-effort: the parser returns `null` per field on
/// failure, and a field below the fold may be absent (lazy rendering).
public struct LinkedInProfile: Codable, Sendable, Equatable {
    /// Contact-info block (behind the "Contact info" overlay on the page).
    public struct ContactInfo: Codable, Sendable, Equatable {
        public var profileUrl: String?
        public var emails: [String]
        public var websites: [String]

        public init(profileUrl: String? = nil, emails: [String] = [], websites: [String] = []) {
            self.profileUrl = profileUrl
            self.emails = emails
            self.websites = websites
        }
    }

    /// The fetched profile photo bytes, as a base64 `data:` URL.
    public struct Photo: Codable, Sendable, Equatable {
        public var dataURL: String
        public var contentType: String?
        public var byteLength: Int?

        public init(dataURL: String, contentType: String? = nil, byteLength: Int? = nil) {
            self.dataURL = dataURL
            self.contentType = contentType
            self.byteLength = byteLength
        }
    }

    public var sourceUrl: String?
    public var slug: String?
    public var fullName: String?
    public var headline: String?
    public var title: String?
    public var org: String?
    public var location: String?
    public var about: String?
    public var contactInfo: ContactInfo?
    public var photo: Photo?

    public init(
        sourceUrl: String? = nil,
        slug: String? = nil,
        fullName: String? = nil,
        headline: String? = nil,
        title: String? = nil,
        org: String? = nil,
        location: String? = nil,
        about: String? = nil,
        contactInfo: ContactInfo? = nil,
        photo: Photo? = nil
    ) {
        self.sourceUrl = sourceUrl
        self.slug = slug
        self.fullName = fullName
        self.headline = headline
        self.title = title
        self.org = org
        self.location = location
        self.about = about
        self.contactInfo = contactInfo
        self.photo = photo
    }

    // Only decode the keys we use; the payload also carries debug fields
    // (_topCardLines, photoSrcset, photoError) that we ignore.
    private enum CodingKeys: String, CodingKey {
        case sourceUrl, slug, fullName, headline, title, org, location, about
        case contactInfo, photo
    }
}

/// The fields a LinkedIn import can apply to a contact. The app maps the user's
/// per-row checkbox selections to this set and passes it to
/// `ContactsRepository.applyLinkedIn(profile:to:fields:)`, which is the single
/// package-side entry point that owns the merge + save rules.
///
/// `photo` is included for completeness but the contact-image write path is a
/// separate (net-new) step; applying it is wired in later.
public enum LinkedInField: String, Sendable, CaseIterable {
    case name, jobTitle, organization
    case emails, websites, linkedInURL
    case headline, location, about   // sidecar (stored as "LinkedIn …"-prefixed notes)
    case photo
}
