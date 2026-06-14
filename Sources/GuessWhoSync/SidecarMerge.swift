import Foundation

public func merge(
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

private func lwwWinner(_ a: SidecarCell, _ b: SidecarCell) -> SidecarCell {
    let (aAt, aBy) = stamp(a)
    let (bAt, bBy) = stamp(b)
    if aAt != bAt {
        return aAt > bAt ? a : b
    }
    return aBy >= bBy ? a : b
}

private func stamp(_ cell: SidecarCell) -> (Date, String) {
    switch cell {
    case .value(_, let modifiedAt, let modifiedBy):
        return (modifiedAt, modifiedBy)
    case .tombstone(let modifiedAt, let modifiedBy):
        return (modifiedAt, modifiedBy)
    }
}
