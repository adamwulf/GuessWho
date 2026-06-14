import Foundation

public struct SidecarKey: Hashable, Sendable {
    public let kind: SidecarKind
    public let id: String

    public init(kind: SidecarKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

extension SidecarKey {
    public static let guessWhoContactURLPrefix = "guesswho://contact/"

    public static func parseGuessWhoContactURL(_ value: String) -> String? {
        guard value.hasPrefix(guessWhoContactURLPrefix) else { return nil }
        let suffix = String(value.dropFirst(guessWhoContactURLPrefix.count))
        guard UUID(uuidString: suffix) != nil else { return nil }
        return suffix
    }

    public static func forContact(_ contact: Contact) -> SidecarKey? {
        for url in contact.urlAddresses {
            if let uuid = parseGuessWhoContactURL(url.value) {
                return SidecarKey(kind: .contact, id: uuid)
            }
        }
        return nil
    }

    public static func forEvent(_ event: Event) -> SidecarKey {
        SidecarKey(kind: .event, id: event.externalID)
    }
}
