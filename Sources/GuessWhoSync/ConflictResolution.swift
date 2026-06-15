import Foundation

public enum ConflictResolution: Sendable {
    case write(merged: SidecarEnvelope, skip: [Data])
    case leave
}
