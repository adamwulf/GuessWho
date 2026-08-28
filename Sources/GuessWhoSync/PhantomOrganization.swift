import Foundation

/// A company NAME that people carry in their Contacts "company" field but that
/// has NO organization record of its own yet — a "phantom" organization. The
/// app shows phantoms in the Organizations list alongside real records, and a
/// person's card taps through to a read-only page from which the user can
/// create a real organization record.
///
/// A phantom has no `ContactID` — there is no record to key on. It is keyed by
/// its NORMALIZED name (`key`, trimmed + lowercased), so two people who spell
/// the same company with different case collapse to ONE phantom. `displayName`
/// is the first-seen spelling, used for the row and the page title.
public struct PhantomOrganization: Hashable, Sendable {
    /// Normalized identity: the company name trimmed + lowercased. Equal keys
    /// are the same phantom. Never blank (a blank company yields no phantom).
    public let key: String

    /// Display spelling of the company name — the row title and the page header.
    /// When people spell one company several ways, this is the spelling that
    /// sorts first, so a capitalized "Acme" wins over an all-lowercase "acme".
    public let displayName: String

    /// How many people name this company (their cards drive the association).
    public let associatedCount: Int

    public init(key: String, displayName: String, associatedCount: Int) {
        self.key = key
        self.displayName = displayName
        self.associatedCount = associatedCount
    }
}

/// One row in the merged Organizations list: either a real organization record
/// (addressed by its opaque `ContactID`) or a phantom organization (addressed
/// by its normalized name `key`). The list's diffable data source keys rows on
/// this. A `.phantom` row is resolved to its content via the repository's
/// phantom projection — it carries the key only, never display content, exactly
/// as `ContactID` carries identity only.
public enum OrganizationRow: Hashable, Sendable {
    case record(ContactID)
    case phantom(key: String)
}
