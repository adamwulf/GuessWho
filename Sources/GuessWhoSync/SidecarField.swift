import Foundation

/// A decoded view of one field-instance cell from a contact or event
/// SidecarEnvelope. Returned by the orchestrator's field-instance accessors
/// (§7.3). Not used for link sidecars (§13 — those have their own shape).
/// `modifiedAt` / `modifiedBy` / `deletedAt` come from the cell stamps;
/// `field` / `type` / `value` / `createdAt` come from the cell's inner
/// `value` object (§5.2).
public struct SidecarField: Sendable, Equatable {
    public let id: UUID
    public let field: String
    public let type: SidecarFieldType
    public let value: JSONValue
    public let createdAt: Date?
    public let modifiedAt: Date
    public let modifiedBy: String
    public let deletedAt: Date?

    public init(
        id: UUID,
        field: String,
        type: SidecarFieldType,
        value: JSONValue,
        createdAt: Date?,
        modifiedAt: Date,
        modifiedBy: String,
        deletedAt: Date?
    ) {
        self.id = id
        self.field = field
        self.type = type
        self.value = value
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
        self.deletedAt = deletedAt
    }
}

extension SidecarField {
    // Keys inside the cell's inner `value` object per §5.2.
    static let innerFieldKey = "field"
    static let innerTypeKey = "type"
    static let innerValueKey = "value"
    static let innerCreatedAtKey = "createdAt"

    /// Decode a cell into a SidecarField. Returns nil if the inner-value
    /// object is malformed (missing `field`/`type`, unknown `type`, etc.)
    /// per §5.3.
    ///
    /// Returning nil is a DISPLAY-layer decision only — it hides the field, it
    /// is NOT permission to delete the cell, which round-trips verbatim. Never
    /// persist only the fields that decode — see the contract [^1].
    /// [^1]: [Sidecar forward-compatibility contract](../../docs/sidecar-compatibility.md)
    static func decode(id: UUID, from cell: SidecarCell) -> SidecarField? {
        guard case .object(let inner) = cell.value else { return nil }
        guard case .string(let fieldName) = inner[innerFieldKey] ?? .null else { return nil }
        guard case .string(let typeRaw) = inner[innerTypeKey] ?? .null else { return nil }
        guard let type = SidecarFieldType(rawValue: typeRaw) else { return nil }
        let payload = inner[innerValueKey] ?? .null
        var createdAt: Date? = nil
        if case .string(let raw) = inner[innerCreatedAtKey] ?? .null {
            createdAt = SidecarISO8601.date(from: raw)
        }
        return SidecarField(
            id: id,
            field: fieldName,
            type: type,
            value: payload,
            createdAt: createdAt,
            modifiedAt: cell.modifiedAt,
            modifiedBy: cell.modifiedBy,
            deletedAt: cell.deletedAt
        )
    }

    /// Validate and canonicalize a web-address string for a `.url` field.
    /// Returns the trimmed string when it is an absolute http/https URL with a
    /// non-empty host and NO embedded userinfo; nil otherwise.
    ///
    /// The canonical stored form is this trimmed string — surrounding
    /// whitespace removed, no scheme rewriting, no percent re-encoding. Every
    /// write path stores exactly this form: the wire path
    /// (`ToolDispatcher.fieldPayload`) and the engine's own `addField` /
    /// `setField` both run the stored value through `storableValue`, and
    /// `validate` accepts only strings this canonicalizer approves.
    ///
    /// Rejections beyond scheme/host guard against a spoofed link label:
    ///  - interior whitespace or control characters (a real address has none,
    ///    and they let a value be dressed up to read as another site);
    ///  - userinfo before the host — "https://apple.com@evil.example" resolves
    ///    to host "evil.example" but reads as apple.com, so it is refused.
    public static func canonicalWebURL(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: urlForbiddenCharacters) == nil,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            return nil
        }
        return trimmed
    }

    /// Whitespace and control characters a `.url` value must not contain
    /// (after trimming the ends). Kept as one set so the intent is named.
    private static let urlForbiddenCharacters: CharacterSet =
        CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// The value to STORE for `type`, applied AFTER `validate` accepts it. For
    /// `.url` this is the canonical (trimmed, clean) address, so every write
    /// path — the wire tools and the app's direct `upsertField` — persists the
    /// same form; all other types store the value unchanged. Keeping this next
    /// to `canonicalWebURL` is why the "canonical stored form" promise holds
    /// regardless of which entry point wrote the field.
    static func storableValue(_ value: JSONValue, for type: SidecarFieldType) -> JSONValue {
        guard type == .url, case .string(let raw) = value,
              let canonical = canonicalWebURL(from: raw) else { return value }
        return .string(canonical)
    }

    /// Validate that `value`'s JSON shape matches `type`'s required shape
    /// per the §7.3 table. Throws `typeValueMismatch` on shape failure.
    /// For `.date`, the value must additionally be ISO8601-parseable; for
    /// `.url`, it must additionally be an absolute http/https web address.
    static func validate(value: JSONValue, against type: SidecarFieldType) throws {
        switch type {
        case .note, .multilineNote:
            guard case .string = value else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        case .date:
            guard case .string(let raw) = value, SidecarISO8601.date(from: raw) != nil else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        case .url:
            // The value is a JSON string holding an absolute http/https web
            // address with a non-empty host. Mirrors how `.date` additionally
            // requires an ISO8601-parseable string.
            guard case .string(let raw) = value, canonicalWebURL(from: raw) != nil else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        case .checkbox:
            guard case .bool = value else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        case .blob:
            // The value is a pointer OBJECT, not bytes:
            //   { "blobId": <non-empty string>, "contentType": <string>,
            //     "byteCount": <integer >= 0> }
            // Anything else (non-object, empty/missing blobId, missing or
            // non-string contentType, missing/negative/fractional byteCount)
            // is a shape failure. Mirrors how `.date` rejects non-ISO8601.
            guard case .object(let pointer) = value else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
            guard case .string(let blobId) = pointer[BlobPointer.blobIdKey] ?? .null,
                  !blobId.isEmpty else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
            guard case .string = pointer[BlobPointer.contentTypeKey] ?? .null else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
            // JSONValue has no integer case; byteCount arrives as `.number`.
            // Require a whole, non-negative value.
            guard case .number(let count) = pointer[BlobPointer.byteCountKey] ?? .null,
                  count >= 0, count.rounded() == count else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        }
    }

    /// Build the inner-value JSON object for a new cell.
    static func makeInnerValue(
        field: String,
        type: SidecarFieldType,
        value: JSONValue,
        createdAt: Date
    ) -> JSONValue {
        .object([
            innerFieldKey: .string(field),
            innerTypeKey: .string(type.rawValue),
            innerValueKey: value,
            innerCreatedAtKey: .string(SidecarISO8601.string(from: createdAt)),
        ])
    }

    /// Build the inner-value object for an edit, preserving the existing
    /// `type` (immutable per §5.2 + §7.3). `createdAt` is preserved by
    /// default; a non-nil `newCreatedAt` rewrites it — notes surface
    /// `createdAt` as the user-visible, user-editable note date, so an edit
    /// may deliberately re-stamp it.
    static func makeInnerValueForEdit(
        existingCell: SidecarCell,
        newField: String,
        newValue: JSONValue,
        newCreatedAt: Date? = nil
    ) -> JSONValue? {
        guard case .object(var inner) = existingCell.value else { return nil }
        // Preserve type (immutable) by leaving it untouched; update field
        // name and value, and createdAt only when the caller re-stamps it.
        inner[innerFieldKey] = .string(newField)
        inner[innerValueKey] = newValue
        if let newCreatedAt {
            inner[innerCreatedAtKey] = .string(SidecarISO8601.string(from: newCreatedAt))
        }
        return .object(inner)
    }

    /// Recover the immutable `type` from an existing cell. Returns nil if
    /// the cell's inner-value object is malformed.
    static func type(of cell: SidecarCell) -> SidecarFieldType? {
        guard case .object(let inner) = cell.value else { return nil }
        guard case .string(let typeRaw) = inner[innerTypeKey] ?? .null else { return nil }
        return SidecarFieldType(rawValue: typeRaw)
    }
}
