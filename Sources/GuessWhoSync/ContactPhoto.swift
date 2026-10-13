import Foundation

public enum ContactPhotoKind: Hashable, Sendable {
    case thumbnail
    case fullSize
}

public struct ContactPhoto: Sendable {
    public let data: Data
    public let kind: ContactPhotoKind
    public let crop: ContactPhotoCrop?

    public init(data: Data, kind: ContactPhotoKind, crop: ContactPhotoCrop? = nil) {
        self.data = data
        self.kind = kind
        self.crop = crop
    }
}
