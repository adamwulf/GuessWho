import Foundation

public enum ConflictResolution: Sendable {
    case write(merged: SidecarEnvelope, skip: [Data])
    case writeRecoverySibling(merged: SidecarEnvelope, suffix: String)
    case leave
}
