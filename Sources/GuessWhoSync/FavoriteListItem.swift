import Foundation

public struct FavoriteListItem: Hashable, Sendable {
    public let stableID: String
    public let kind: FavoriteKind
    public let contact: Contact?
    public let event: Event?

    public init(stableID: String, kind: FavoriteKind, contact: Contact? = nil, event: Event? = nil) {
        self.stableID = stableID
        self.kind = kind
        self.contact = contact
        self.event = event
    }
}
