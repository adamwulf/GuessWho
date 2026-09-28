import Foundation

/// Why a contact's incoming mail is highlighted in Apple Mail.
///
/// Adding a case is a format change: an older reader cannot decode an
/// unknown raw value, so bump `MailContactSnapshot.currentVersion` with it.
enum MailHighlightReason: String, Codable, Sendable, CaseIterable {
    /// The contact itself is a favorite.
    case favoriteContact
    /// The contact belongs to a favorite group.
    case favoriteGroupMember
    /// The contact works at a favorite organization.
    case favoriteOrganizationMember
}

/// What the Mail extension may show about one contact. Deliberately small:
/// the snapshot is read on every incoming message, so it carries only what
/// the highlight decision and the compose popover need.
struct MailContactSummary: Codable, Sendable, Equatable {
    var displayName: String
    var organization: String?
    var jobTitle: String?
    /// Small image data (JPEG or PNG) for the compose popover. Keep it
    /// thumbnail-sized: the same bytes repeat under every address the
    /// contact has.
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

    var isHighlighted: Bool { !highlightReasons.isEmpty }
}

/// The contact cache the app publishes for the Mail extension, keyed by
/// normalized email address (`MailAddressNormalizer`).
///
/// One address can map to several summaries — two contact cards may share an
/// address — so every lookup returns an array and callers treat "any summary
/// is highlighted" as highlighted.
struct MailContactSnapshot: Codable, Sendable, Equatable {
    /// The format this build writes and the newest it reads. A reader that
    /// meets a newer version treats the cache as unavailable instead of
    /// guessing at its meaning.
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
