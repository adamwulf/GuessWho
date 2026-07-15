import Foundation

public struct FavoriteListItem: Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let id: ID
    public let kind: FavoriteKind
    public let contact: Contact?
    public let event: Event?
    public let group: ContactGroup?

    public init(
        id: ID,
        kind: FavoriteKind,
        contact: Contact? = nil,
        event: Event? = nil,
        group: ContactGroup? = nil
    ) {
        self.id = id
        self.kind = kind
        self.contact = contact
        self.event = event
        self.group = group
    }
}
