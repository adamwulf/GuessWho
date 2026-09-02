import Foundation

/// The resolved payload for a `FavoriteKind.department` favorite: the live
/// organization record it hangs under, plus the department name in its current
/// display form (as read back from `departments(in:)`, so the user's
/// capitalization is restored after the lowercased key). Present only when the
/// organization resolves AND at least one associated person still carries the
/// department; otherwise the favorite row reads as "Unavailable" so the user can
/// still remove it.
public struct DepartmentFavorite: Hashable, Sendable {
    public let organization: Contact
    public let department: String

    public init(organization: Contact, department: String) {
        self.organization = organization
        self.department = department
    }
}

public struct FavoriteListItem: Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let id: ID
    public let kind: FavoriteKind
    /// The resolved payload for this row's `kind`. Exactly one is non-nil for a
    /// row whose referent still exists; ALL are nil when the referent is gone
    /// (deleted record, guide not yet synced), which the list renders as the
    /// "unavailable" state rather than dropping the row — the user needs the row
    /// to un-favorite it.
    public let contact: Contact?
    public let event: Event?
    public let group: ContactGroup?
    public let guide: MapsGuide?
    public let place: MapsPlace?
    public let department: DepartmentFavorite?

    public init(
        id: ID,
        kind: FavoriteKind,
        contact: Contact? = nil,
        event: Event? = nil,
        group: ContactGroup? = nil,
        guide: MapsGuide? = nil,
        place: MapsPlace? = nil,
        department: DepartmentFavorite? = nil
    ) {
        self.id = id
        self.kind = kind
        self.contact = contact
        self.event = event
        self.group = group
        self.guide = guide
        self.place = place
        self.department = department
    }
}
