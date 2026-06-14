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
    public static func forContact(_ contact: Contact) -> SidecarKey? {
        let prefix = "guesswho://contact/"
        for url in contact.urlAddresses {
            guard url.value.hasPrefix(prefix) else { continue }
            let suffix = String(url.value.dropFirst(prefix.count))
            guard UUID(uuidString: suffix) != nil else { continue }
            return SidecarKey(kind: .contact, id: suffix)
        }
        return nil
    }

    public static func forEvent(_ event: Event) -> SidecarKey {
        SidecarKey(kind: .event, id: event.externalID)
    }
}
