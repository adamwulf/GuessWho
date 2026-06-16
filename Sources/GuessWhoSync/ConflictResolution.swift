import Foundation

public enum ConflictResolution: Sendable {
    /// Write `merged` as the current version; mark every conflict version
    /// `isResolved = true` and `remove()` it. Versions whose bytes appear in
    /// `skip` are left in conflict (used for unparseable / schemaVersion ≠ 1
    /// versions the closure could not fold).
    case write(merged: SidecarEnvelope, skip: [Data])
    /// Write `merged` to a sibling file `<originalName>.<suffix>`; leave the
    /// original current version and every conflict version intact. Used when
    /// the current version is unparseable but at least one conflict version
    /// parsed (§6 step 4) — never silently destroy bytes we can't read.
    case writeRecoverySibling(merged: SidecarEnvelope, suffix: String)
    /// Leave everything in conflict (no version parsed, or merge failed).
    case leave
}
