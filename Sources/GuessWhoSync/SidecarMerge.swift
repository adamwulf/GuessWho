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
            if key == notesFieldKey {
                if let resolved = mergeNotesCell(aCell, bCell) {
                    merged[key] = resolved
                } else {
                    merged.removeValue(forKey: key)
                }
            } else {
                merged[key] = lwwWinner(aCell, bCell)
            }
        } else {
            merged[key] = bCell
        }
    }

    return .success(SidecarEnvelope(schemaVersion: 1, entityID: a.entityID, fields: merged))
}

let notesFieldKey = "notes"

// §12.3: per-note LWW for the "notes" field. Called only when BOTH sides
// have the key — the one-sided pass-through is handled by the generic merge
// path above. A malformed side decodes to []; the other side's valid notes
// survive the union. Returns nil when the merged list is empty so the caller
// can omit the key from the result envelope (§12.3 step 4).
func mergeNotesCell(_ a: SidecarCell, _ b: SidecarCell) -> SidecarCell? {
    let aNotes = NotesCellCodec.decode(a)
    let bNotes = NotesCellCodec.decode(b)

    var byID: [UUID: ContactNote] = [:]
    byID.reserveCapacity(aNotes.count + bNotes.count)
    for note in aNotes {
        byID[note.id] = note
    }
    for note in bNotes {
        if let existing = byID[note.id] {
            byID[note.id] = perNoteWinner(existing, note)
        } else {
            byID[note.id] = note
        }
    }

    return NotesCellCodec.encodeCell(Array(byID.values))
}

private func perNoteWinner(_ a: ContactNote, _ b: ContactNote) -> ContactNote {
    if a.modifiedAt != b.modifiedAt {
        return a.modifiedAt > b.modifiedAt ? a : b
    }
    return a.modifiedBy >= b.modifiedBy ? a : b
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
