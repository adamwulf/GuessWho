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

/// What the Mail extension may show about one contact. Deliberately small:
/// the snapshot is read on every incoming message, so it carries only what
/// the highlight decision and the compose popover need.
struct MailContactSummary: Codable, Sendable, Equatable {
    var displayName: String
    var organization: String?
    var jobTitle: String?
    /// Small image data (JPEG or PNG) for the compose popover. The app-side
    /// publisher enforces a 256 KiB per-image and 8 MiB total budget, charging
    /// these bytes once per address because the encoded summary repeats there.
    var thumbnail: Data?
    var highlightReasons: Set<MailHighlightReason>

    init(
        displayName: String,
        organization: String? = nil,
        jobTitle: String? = nil,
        thumbnail: Data? = nil,
        highlightReasons: Set<MailHighlightReason> = []
    ) {
        self.displayName = displayName
        self.organization = organization
        self.jobTitle = jobTitle
        self.thumbnail = thumbnail
        self.highlightReasons = highlightReasons
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
