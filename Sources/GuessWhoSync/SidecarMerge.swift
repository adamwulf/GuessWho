import Foundation

func merge(
    _ a: SidecarEnvelope,
    _ b: SidecarEnvelope
) -> Result<SidecarEnvelope, MergeError> {
    guard a.schemaVersion == 1, b.schemaVersion == 1 else {
        return .failure(.schemaVersionMismatch)
    }
    guard a.entityID == b.entityID else {
        return .failure(.entityIDMismatch)
    }

    var merged = a.fields
    for (key, bCell) in b.fields {
        if let aCell = merged[key] {
            merged[key] = lwwWinner(aCell, bCell)
        } else {
            merged[key] = bCell
        }
    }

    return .success(SidecarEnvelope(schemaVersion: 1, entityID: a.entityID, fields: merged))
}

// Whole-cell LWW per §5.3 — winner brings its `value`, stamps, and
// `deletedAt` together as one atomic unit. Tiebreak by lex on modifiedBy.
private func lwwWinner(_ a: SidecarCell, _ b: SidecarCell) -> SidecarCell {
    if a.modifiedAt != b.modifiedAt {
        return a.modifiedAt > b.modifiedAt ? a : b
    }
    return a.modifiedBy >= b.modifiedBy ? a : b
}
