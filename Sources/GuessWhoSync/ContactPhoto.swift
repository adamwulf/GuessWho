import Foundation

public enum ContactPhotoKind: Hashable, Sendable {
    case thumbnail
    case fullSize
}

public struct ContactPhoto: Sendable {
    public let data: Data
    public let kind: ContactPhotoKind

    public init(data: Data, kind: ContactPhotoKind) {
        self.data = data
        self.kind = kind
    }
}
