import Foundation

public struct SidecarKey: Hashable, Sendable, Codable {
    public let kind: SidecarKind
    public let id: String

    public init(kind: SidecarKind, id: String) {
        self.kind = kind
        // Contact, event, and link UUIDs are canonicalized to lowercase so the
        // same identifier can't be stored under two different cases. Events
        // are now keyed by minted UUID (post-pivot), so the `.event` branch
        // joins the lowercasing path.
        switch kind {
        case .contact, .link, .event:
            self.id = id.lowercased()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SidecarKind.self, forKey: .kind)
        let id = try container.decode(String.self, forKey: .id)
        self.init(kind: kind, id: id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
    }
}

extension SidecarKey {
    public static let guessWhoContactURLPrefix = "guesswho://contact/"

    // Canonicalize UUIDs to lowercase at every boundary (parse, format,
    // compare, on-disk filename).
    public static func parseGuessWhoContactURL(_ value: String) -> String? {
        // NOTE: case-insensitive-but-case-preserving filesystems (e.g. the
        // default APFS volume for iCloud Drive) treat filenames as
        // case-insensitive for collisions but case-sensitive when reading
        // back, AND UUID(uuidString:) accepts any case on input. Without a
        // single canonical form, two devices can disagree about whose
        // sidecar file is on disk.
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
        SidecarKey(kind: .event, id: event.id.uuidString)
    }
}
