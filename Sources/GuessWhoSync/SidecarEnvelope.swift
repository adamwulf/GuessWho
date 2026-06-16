import Foundation

public struct SidecarEnvelope: Sendable, Codable {
    public let schemaVersion: Int
    public let entityID: String
    public let fields: [String: SidecarCell]

    /// Diagnostic counter: how many cells were dropped during decode because
    /// they were malformed (bad modifiedAt/deletedAt, missing value key,
    /// malformed inner-value object, etc.). Per PLAN §5.3 malformed cells are
    /// treated as absent and the merge proceeds with the rest — but a
    /// non-zero count is a hint that a peer device is shipping broken
    /// envelopes. The orchestrator surfaces this in
    /// `SidecarReconcileReport.FileOutcome.skippedReasons` so the silent-skip
    /// discipline doesn't hide systematic data loss.
    ///
    /// Always 0 on envelopes constructed in-process via `init(...)`.
    public let cellsDroppedOnDecode: Int

    public init(schemaVersion: Int = 1, entityID: String, fields: [String: SidecarCell]) {
        self.schemaVersion = schemaVersion
        self.entityID = entityID
        self.fields = fields
        self.cellsDroppedOnDecode = 0
    }

    // §5.3 malformed-input handling: a malformed cell (bad modifiedAt, bad
    // deletedAt, missing value, missing inner field/type, etc.) is treated as
    // absent — the other side's cell wins the merge. To make that property
    // hold across the wire, individual bad cells must NOT poison the whole
    // envelope. Decode each cell independently; drop the ones that throw.

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entityID
        case fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let entityID = try container.decode(String.self, forKey: .entityID)

        // Decode `fields` as a [String: JSON-blob] first, then attempt each
        // cell individually. Cells that fail to decode are dropped (§5.3).
        var fields: [String: SidecarCell] = [:]
        var dropped = 0
        if let fieldsContainer = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: .fields) {
            for key in fieldsContainer.allKeys {
                if let cell = try? fieldsContainer.decode(SidecarCell.self, forKey: key) {
                    fields[key.stringValue] = cell
                } else {
                    dropped += 1
                }
            }
        }

        self.schemaVersion = schemaVersion
        self.entityID = entityID
        self.fields = fields
        self.cellsDroppedOnDecode = dropped
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(fields, forKey: .fields)
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
