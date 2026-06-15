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

    /// Validate that `value`'s JSON shape matches `type`'s required shape
    /// per the §7.3 table. Throws `typeValueMismatch` on shape failure.
    /// For `.date`, the value must additionally be ISO8601-parseable.
    static func validate(value: JSONValue, against type: SidecarFieldType) throws {
        switch type {
        case .note:
            guard case .string = value else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        case .date:
            guard case .string(let raw) = value, SidecarISO8601.date(from: raw) != nil else {
                throw SidecarStoreError.typeValueMismatch(expected: type, got: value)
            }
        case .checkbox:
            guard case .bool = value else {
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
    /// `type` and `createdAt` (immutable / write-once per §5.2 + §7.3).
    static func makeInnerValueForEdit(
        existingCell: SidecarCell,
        newField: String,
        newValue: JSONValue
    ) -> JSONValue? {
        guard case .object(var inner) = existingCell.value else { return nil }
        // Preserve type (immutable) and createdAt (write-once) by leaving them
        // untouched; only update field name and value.
        inner[innerFieldKey] = .string(newField)
        inner[innerValueKey] = newValue
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
