import Foundation

public struct ContactIdentityDebugInfo: Hashable, Sendable {
    public let contactsIdentifier: String
    public let guessWhoID: String?
    public let guessWhoURLs: [LabeledValue]

    public init(contactsIdentifier: String, guessWhoID: String?, guessWhoURLs: [LabeledValue]) {
        self.contactsIdentifier = contactsIdentifier
        self.guessWhoID = guessWhoID
        self.guessWhoURLs = guessWhoURLs
    }
}
