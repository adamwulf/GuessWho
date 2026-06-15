import Foundation

enum NotesCellCodec {
    static func decode(_ cell: SidecarCell?) -> [ContactNote] {
        guard let cell else { return [] }
        guard case .value(let json, _, _) = cell else { return [] }
        guard case .array(let elements) = json else { return [] }
        return elements.compactMap(decodeNote(_:))
    }

    static func encodeValue(_ notes: [ContactNote]) -> JSONValue {
        .array(notes.map(encodeNote(_:)))
    }

    static func encodeCell(_ notes: [ContactNote]) -> SidecarCell? {
        guard let stamp = outerStamp(for: notes) else { return nil }
        return .value(encodeValue(notes), modifiedAt: stamp.modifiedAt, modifiedBy: stamp.modifiedBy)
    }

    // MARK: - Internals

    private static func decodeNote(_ value: JSONValue) -> ContactNote? {
        guard case .object(let fields) = value else { return nil }

        guard case .string(let idString) = fields["id"] ?? .null,
              let id = UUID(uuidString: idString)
        else { return nil }

        guard case .string(let createdAtString) = fields["createdAt"] ?? .null,
              let createdAt = parsePermissiveISO8601(createdAtString)
        else { return nil }

        guard case .string(let modifiedAtString) = fields["modifiedAt"] ?? .null,
              let modifiedAt = parsePermissiveISO8601(modifiedAtString)
        else { return nil }

        guard case .string(let modifiedBy) = fields["modifiedBy"] ?? .null
        else { return nil }

        guard case .string(let body) = fields["body"] ?? .null
        else { return nil }

        guard case .bool(let deleted) = fields["deleted"] ?? .null
        else { return nil }

        return ContactNote(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            modifiedBy: modifiedBy,
            body: body,
            deleted: deleted
        )
    }

    private static func encodeNote(_ note: ContactNote) -> JSONValue {
        .object([
            "id": .string(note.id.uuidString),
            "createdAt": .string(SidecarISO8601.string(from: note.createdAt)),
            "modifiedAt": .string(SidecarISO8601.string(from: note.modifiedAt)),
            "modifiedBy": .string(note.modifiedBy),
            "body": .string(note.body),
            "deleted": .bool(note.deleted),
        ])
    }

    private static func outerStamp(for notes: [ContactNote]) -> (modifiedAt: Date, modifiedBy: String)? {
        guard let first = notes.first else { return nil }
        var maxAt = first.modifiedAt
        var maxBy = first.modifiedBy
        for note in notes.dropFirst() {
            if note.modifiedAt > maxAt {
                maxAt = note.modifiedAt
                maxBy = note.modifiedBy
            } else if note.modifiedAt == maxAt && note.modifiedBy > maxBy {
                maxBy = note.modifiedBy
            }
        }
        return (maxAt, maxBy)
    }

    // Permissive ISO8601 decoder per §12.2: accept the strict
    // millisecond-precision form (`.withFractionalSeconds`) first, then fall
    // back to the no-fraction form so a note written by a peer with a slightly
    // different encoder isn't silently dropped.
    private static func parsePermissiveISO8601(_ string: String) -> Date? {
        if let date = SidecarISO8601.date(from: string) {
            return date
        }
        return Self.fallbackFormatter.date(from: string)
    }

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
