import Foundation

/// The composite key behind a `FavoriteKind.department` favorite. A department
/// is not a record — it exists only through the people who carry the department
/// string — so it is identified by the pair `(organization identity, department
/// name)`. The organization side is the durable, cross-device GuessWho UUID
/// (exactly the identity `DepartmentReference` navigates by); the department
/// side is the Apple-synced string as the user typed it.
///
/// The wire form is `"<org guesswho uuid>/<department name>"`. The UUID is
/// always 36 characters in its canonical dashed form, so the key is parsed by
/// that FIXED 36-character prefix and the "/" that follows it — never by
/// searching for a separator — which is what lets a department name that itself
/// contains "/" round-trip losslessly.
///
/// `FavoritesStore` lowercases every stored id, which is harmless here:
/// department matching is trimmed and case-insensitive (see `matches`), and the
/// display form is re-read from live data when the favorite is resolved. Build
/// and parse the key ONLY through this type; no call site should assemble or
/// split the string by hand.
public struct DepartmentFavoriteKey: Hashable, Sendable {
    /// The organization's canonical lowercase GuessWho UUID string.
    public let organizationGuessWhoID: String
    /// The department name, trimmed. Case and internal "/" are preserved.
    public let department: String

    public init(organizationGuessWhoID: String, department: String) {
        self.organizationGuessWhoID = organizationGuessWhoID.lowercased()
        self.department = department.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `"<uuid>/<department>"` — what goes into `Favorite.id`. The store
    /// lowercases the whole string on write; that loss is recovered on resolve.
    public var favoriteID: String {
        "\(organizationGuessWhoID)/\(department)"
    }

    /// Parses a stored/wire id by the fixed 36-character UUID prefix followed by
    /// "/". Returns nil for anything whose prefix is not a valid UUID, that has
    /// no "/" in the separator slot, or whose department part is blank. The
    /// department is everything after that "/", so an internal "/" survives.
    public init?(favoriteID: String) {
        // 36 (uuid) + 1 ("/") + at least one department character.
        guard favoriteID.count > 37 else { return nil }
        let uuidEnd = favoriteID.index(favoriteID.startIndex, offsetBy: 36)
        let uuidPart = String(favoriteID[favoriteID.startIndex..<uuidEnd])
        guard UUID(uuidString: uuidPart) != nil else { return nil }
        guard favoriteID[uuidEnd] == "/" else { return nil }
        // Everything after the "/" is the department — including any internal
        // "/". Trim surrounding whitespace so the stored form matches the
        // `init(organizationGuessWhoID:department:)` contract ("trimmed, as
        // given"); a blank department is not a valid key.
        let departmentPart = String(favoriteID[favoriteID.index(after: uuidEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !departmentPart.isEmpty else { return nil }
        self.organizationGuessWhoID = uuidPart.lowercased()
        self.department = departmentPart
    }

    /// Trimmed, case-insensitive comparison against a live department name —
    /// the same rule the repository uses to match a department string to its
    /// members.
    public func matches(department other: String) -> Bool {
        let lhs = department.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
