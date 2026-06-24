import Foundation

/// Durable package identity for a contact.
///
/// The raw value is the canonical lowercase UUID from a
/// `guesswho://contact/<uuid>` URL, never a Contacts `localID`.
public struct GuessWhoContactID: Hashable, Sendable, Codable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard UUID(uuidString: rawValue) != nil else { return nil }
        self.rawValue = rawValue.lowercased()
    }

    init?(contact: Contact) {
        guard let key = SidecarKey.forContact(contact) else { return nil }
        self.init(rawValue: key.id)
    }
}

/// A contact paired with its durable GuessWho identity.
///
/// This becomes the repository's app-facing read model while `Contact` remains
/// the adapter transport value during the local-ID migration.
public struct GuessWhoContact: Hashable, Sendable {
    public let id: GuessWhoContactID
    public let contact: Contact

    init?(contact: Contact) {
        guard let id = GuessWhoContactID(contact: contact) else { return nil }
        self.id = id
        self.contact = contact
    }
}

/// A best-effort match for a name-only `CNContactRelation`.
///
/// This is deliberately not a durable link: only the source contact has a
/// GuessWho ID; the relationship target is free-form name text.
public struct ContactRelationMatch: Hashable, Sendable {
    public let sourceID: GuessWhoContactID
    public let label: String
    public let matchedName: String

    public init(sourceID: GuessWhoContactID, label: String, matchedName: String) {
        self.sourceID = sourceID
        self.label = label
        self.matchedName = matchedName
    }
}
