import Foundation

/// A group defined in Contacts.app (`CNGroup`). GuessWho treats groups as
/// read-mostly metadata that lives in the Contacts database — the sidecar
/// does not mirror them, and the Contacts-layer handle is the `localID` issued
/// by Contacts at create time.
///
/// That handle is device-local (a different value on each device after sync),
/// so it can't identify a group across devices. A *favorited* group's durable,
/// cross-device identity lives in a separate `GroupIdentity` sidecar record
/// keyed by a minted UUID — see `plans/group-favorite-identity.md`. The
/// `localID` here is only the transient Contacts-framework lookup token.
public struct ContactGroup: Sendable, Hashable, Codable {
    /// Stable-on-this-device identifier issued by Contacts (`CNGroup.identifier`).
    public let localID: String
    public var name: String

    public init(localID: String, name: String) {
        self.localID = localID
        self.name = name
    }
}
