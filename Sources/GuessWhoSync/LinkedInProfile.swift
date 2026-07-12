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
        public var phones: [String]
        public var websites: [String]

        public init(profileUrl: String? = nil, emails: [String] = [], phones: [String] = [], websites: [String] = []) {
            self.profileUrl = profileUrl
            self.emails = emails
            self.phones = phones
            self.websites = websites
        }

        private enum CodingKeys: String, CodingKey { case profileUrl, emails, phones, websites }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            profileUrl = try values.decodeIfPresent(String.self, forKey: .profileUrl)
            emails = try values.decodeIfPresent([String].self, forKey: .emails) ?? []
            phones = try values.decodeIfPresent([String].self, forKey: .phones) ?? []
            websites = try values.decodeIfPresent([String].self, forKey: .websites) ?? []
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

        /// The photo bytes decoded out of the base64 `data:` URL, or nil when
        /// the string isn't a recognizable base64 data URL. The single decode
        /// implementation for both the package's photo apply and the app's
        /// preview thumbnail.
        public func decodedData() -> Data? {
            guard let comma = dataURL.range(of: ",") else { return nil }
            return Data(base64Encoded: String(dataURL[comma.upperBound...]))
        }
    }

    /// Source parser. Missing means LinkedIn for backward compatibility with
    /// already-parked payloads and existing tests.
    public var source: String?
    public var sourceUrl: String?
    public var slug: String?
    public var fullName: String?
    public var headline: String?
    public var title: String?
    public var org: String?
    public var location: String?
    public var about: String?
    public var department: String?
    public var contactInfo: ContactInfo?
    public var photo: Photo?

    public init(
        source: String? = nil,
        sourceUrl: String? = nil,
        slug: String? = nil,
        fullName: String? = nil,
        headline: String? = nil,
        title: String? = nil,
        org: String? = nil,
        location: String? = nil,
        about: String? = nil,
        department: String? = nil,
        contactInfo: ContactInfo? = nil,
        photo: Photo? = nil
    ) {
        self.source = source
        self.sourceUrl = sourceUrl
        self.slug = slug
        self.fullName = fullName
        self.headline = headline
        self.title = title
        self.org = org
        self.location = location
        self.about = about
        self.department = department
        self.contactInfo = contactInfo
        self.photo = photo
    }

    // Only decode the keys we use; the payload also carries debug fields
    // (_topCardLines, photoSrcset, photoError) that we ignore, and an
    // `experience` array (structured positions from the Experience section)
    // that the app doesn't consume yet — the parser already folds the current
    // position into `title`/`org`, so nothing app-side needs the raw array.
    private enum CodingKeys: String, CodingKey {
        case source, sourceUrl, slug, fullName, headline, title, org, location, about, department
        case contactInfo, photo
    }

    public var isRiceProfile: Bool { source?.caseInsensitiveCompare("rice") == .orderedSame }

    public var sourceDisplayName: String { isRiceProfile ? "Rice" : "LinkedIn" }
}

/// The fields a LinkedIn import can apply to a contact. The app maps the user's
/// per-row checkbox selections to this set and passes it to
/// `ContactsRepository.applyLinkedIn(profile:to:fields:)`, which is the single
/// package-side entry point that owns the merge + save rules.
///
/// `photo` routes through the contact-image write path (`setContactPhoto`), so
/// replacing an existing photo automatically snapshots the replaced bytes into
/// the single-slot previous-photo sidecar blob.
public enum LinkedInField: String, Sendable, CaseIterable {
    case name, jobTitle, organization
    case emails, phones, websites, linkedInURL
    case headline, location, about   // sidecar (stored as "LinkedIn …"-prefixed notes)
    case department
    case photo
}
