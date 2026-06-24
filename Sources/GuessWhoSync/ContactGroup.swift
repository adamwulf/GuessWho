import Foundation

/// A group defined in Contacts.app (`CNGroup`). GuessWho treats groups as
/// read-mostly metadata that lives in the Contacts database — the sidecar
/// does not mirror them, and identity is the `localID` issued by Contacts
/// at create time.
public struct ContactGroup: Sendable, Hashable, Codable {
    /// Stable identifier issued by Contacts (`CNGroup.identifier`).
    public let localID: String
    public var name: String

    public init(localID: String, name: String) {
        self.localID = localID
        self.name = name
    }
}
