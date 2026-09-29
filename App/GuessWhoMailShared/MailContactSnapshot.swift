import Foundation

/// Why a contact's incoming mail is highlighted in Apple Mail.
///
/// An open set rather than an enum: a reason this build doesn't recognize
/// still decodes (and round-trips), and — because any reason at all means
/// "highlight" — still counts as highlighted. A newer app can therefore add
/// reasons without a snapshot version bump, and an older extension errs on
/// the side of highlighting.
struct MailHighlightReason: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The contact itself is a favorite.
    static let favoriteContact = MailHighlightReason(rawValue: "favoriteContact")
    /// The contact belongs to a favorite group.
    static let favoriteGroupMember = MailHighlightReason(rawValue: "favoriteGroupMember")
    /// The contact works at a favorite organization.
    static let favoriteOrganizationMember = MailHighlightReason(rawValue: "favoriteOrganizationMember")

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The flag color Mail shows on a message from a highlighted sender.
///
/// Lives here, not in the extension, because MailKit is unavailable to the app
/// and the choice is worth testing: the extension only maps each case to
/// `MEMessageAction.Flag`. A reason wins in this order — the person, then a
/// group, then an organization — so a favorite who is also in a favorite group
/// stays the person's color.
enum MailFlagColor: Equatable, Sendable {
    case blue
    case green
    case orange
    /// Mail's own flag color, for a reason this build doesn't recognize.
    case mailDefault

    /// The color for a message whose sender's summaries carry `reasons`, or
    /// nil when there is no reason to flag it.
    static func color(for reasons: Set<MailHighlightReason>) -> MailFlagColor? {
        guard !reasons.isEmpty else { return nil }
        if reasons.contains(.favoriteContact) { return .blue }
        if reasons.contains(.favoriteGroupMember) { return .green }
        if reasons.contains(.favoriteOrganizationMember) { return .orange }
        return .mailDefault
    }
}

/// One phone number or email address on a contact, with a label the app has
/// already turned into plain text (for example "work"), so the extension needs
/// no Contacts framework to show it.
struct MailLabeledValue: Codable, Sendable, Equatable {
    var label: String
    var value: String
}

/// What the Mail extension may show about one contact. Deliberately small:
/// the snapshot is read on every incoming message, so it carries only what
/// the highlight decision and the compose popover need.
///
/// `contactID` and everything after it are optional or defaulted on decode, so
/// a cache written before those fields existed still reads (see the version
/// rules on `MailContactSnapshot`).
struct MailContactSummary: Codable, Sendable, Equatable {
    var displayName: String
    var organization: String?
    var jobTitle: String?
    /// Small image data (JPEG or PNG) for the compose popover. The app-side
    /// publisher enforces a 256 KiB per-image and 8 MiB total budget, charging
    /// these bytes once per address because the encoded summary repeats there.
    var thumbnail: Data?
    var highlightReasons: Set<MailHighlightReason>
    /// The contact's GuessWho ID (the UUID in its `guesswho://contact/<uuid>`
    /// URL). Nil for a contact the app has not given an ID yet; such a contact
    /// cannot be opened in the app from the popover.
    var contactID: String?
    var emailAddresses: [MailLabeledValue]
    var phoneNumbers: [MailLabeledValue]
    /// The birthday as display text, for example "November 30, 1982".
    var birthday: String?

    init(
        displayName: String,
        organization: String? = nil,
        jobTitle: String? = nil,
        thumbnail: Data? = nil,
        highlightReasons: Set<MailHighlightReason> = [],
        contactID: String? = nil,
        emailAddresses: [MailLabeledValue] = [],
        phoneNumbers: [MailLabeledValue] = [],
        birthday: String? = nil
    ) {
        self.displayName = displayName
        self.organization = organization
        self.jobTitle = jobTitle
        self.thumbnail = thumbnail
        self.highlightReasons = highlightReasons
        self.contactID = contactID
        self.emailAddresses = emailAddresses
        self.phoneNumbers = phoneNumbers
        self.birthday = birthday
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, organization, jobTitle, thumbnail, highlightReasons
        case contactID, emailAddresses, phoneNumbers, birthday
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        jobTitle = try container.decodeIfPresent(String.self, forKey: .jobTitle)
        thumbnail = try container.decodeIfPresent(Data.self, forKey: .thumbnail)
        highlightReasons = try container.decode(Set<MailHighlightReason>.self, forKey: .highlightReasons)
        contactID = try container.decodeIfPresent(String.self, forKey: .contactID)
        emailAddresses = try container.decodeIfPresent([MailLabeledValue].self, forKey: .emailAddresses) ?? []
        phoneNumbers = try container.decodeIfPresent([MailLabeledValue].self, forKey: .phoneNumbers) ?? []
        birthday = try container.decodeIfPresent(String.self, forKey: .birthday)
    }

    /// True for any reason, including ones this build doesn't recognize.
    var isHighlighted: Bool { !highlightReasons.isEmpty }
}

/// The contact cache the app publishes for the Mail extension, keyed by
/// normalized email address (`MailAddressNormalizer`).
///
/// One address can map to several summaries — two contact cards may share an
/// address — so every lookup returns an array and callers treat "any summary
/// is highlighted" as highlighted.
///
/// ## Version rules
/// `currentVersion` changes only for a breaking shape change (a field
/// renamed, retyped, or removed). Adding an optional field or a highlight
/// reason is not breaking: decoders ignore unknown keys, and unknown reasons
/// decode. Every version, breaking or not, keeps a top-level
/// `summariesByAddress` dictionary keyed by normalized address, so an older
/// reader can still tell which senders are known
/// (`MailContactCacheContents.newerFormat`).
struct MailContactSnapshot: Codable, Sendable, Equatable {
    /// The format this build writes and the newest it reads fully.
    static let currentVersion = 1

    var version: Int
    var generatedAt: Date
    /// Normalized address → every summary carrying that address.
    private(set) var summariesByAddress: [String: [MailContactSummary]]

    init(generatedAt: Date) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.summariesByAddress = [:]
    }

    /// Files `summary` under each of `addresses`, normalizing every key.
    /// Addresses that don't normalize are skipped, and a summary already
    /// filed under an address is not filed twice (so `A@x.com` and `a@x.com`
    /// on one card produce one entry).
    mutating func add(_ summary: MailContactSummary, forAddresses addresses: [String]) {
        for address in addresses {
            guard let key = MailAddressNormalizer.normalize(address) else { continue }
            var summaries = summariesByAddress[key, default: []]
            guard !summaries.contains(summary) else { continue }
            summaries.append(summary)
            summariesByAddress[key] = summaries
        }
    }

    /// The summaries filed under `address`, which may be in any shape
    /// `MailAddressNormalizer.normalize(_:)` accepts. Empty when unknown.
    func summaries(forAddress address: String) -> [MailContactSummary] {
        guard let key = MailAddressNormalizer.normalize(address) else { return [] }
        return summariesByAddress[key] ?? []
    }
}

/// The published cache as this build can use it.
enum MailContactCacheContents: Sendable, Equatable {
    /// A snapshot in a format this build reads fully.
    case current(MailContactSnapshot)
    /// A snapshot from a newer build in a breaking format. Only its address
    /// index is readable: which addresses are known, not who they are or
    /// whether they're highlighted.
    case newerFormat(version: Int, knownAddresses: Set<String>)

    /// True when the cache knows `address` (any shape
    /// `MailAddressNormalizer.normalize(_:)` accepts).
    func isKnown(address: String) -> Bool {
        guard let key = MailAddressNormalizer.normalize(address) else { return false }
        switch self {
        case .current(let snapshot):
            return !(snapshot.summariesByAddress[key] ?? []).isEmpty
        case .newerFormat(_, let knownAddresses):
            return knownAddresses.contains(key)
        }
    }

    /// The summaries for `address`; always empty for `.newerFormat`.
    func summaries(forAddress address: String) -> [MailContactSummary] {
        switch self {
        case .current(let snapshot):
            return snapshot.summaries(forAddress: address)
        case .newerFormat:
            return []
        }
    }
}
