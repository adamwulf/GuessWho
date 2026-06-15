import Foundation

public struct SidecarKey: Hashable, Sendable {
    public let kind: SidecarKind
    public let id: String

    public init(kind: SidecarKind, id: String) {
        self.kind = kind
        // Contact UUIDs are canonicalized to lowercase so the same identifier
        // can't be stored under two different cases. Event externalIDs are
        // opaque strings owned by another system, so we don't touch their case.
        switch kind {
        case .contact:
            self.id = id.lowercased()
        case .event:
            self.id = id
        }
    }
}

extension SidecarKey {
    public static let guessWhoContactURLPrefix = "guesswho://contact/"

    // Canonicalize UUIDs to lowercase everywhere they cross a boundary
    // (parse, format, compare, on-disk filename). iCloud Drive's default
    // APFS volumes treat filenames as case-insensitive for collisions but
    // case-sensitive when reading back, AND UUID(uuidString:) accepts any
    // case on input — without a single canonical form, two devices can
    // disagree about whose sidecar file is on disk.
    public static func parseGuessWhoContactURL(_ value: String) -> String? {
        guard value.hasPrefix(guessWhoContactURLPrefix) else { return nil }
        let suffix = String(value.dropFirst(guessWhoContactURLPrefix.count))
        guard UUID(uuidString: suffix) != nil else { return nil }
        return suffix.lowercased()
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
