import Foundation

public enum ContactPhotoKind: Hashable, Sendable {
    case thumbnail
    case fullSize
}

public struct ContactPhoto: Sendable {
    public let data: Data
    public let kind: ContactPhotoKind
    public let crop: ContactPhotoCrop?
    package var systemPhotoDigest: String?
    package var blobID: String?
    package var usesSystemPhoto = false

    public init(data: Data, kind: ContactPhotoKind, crop: ContactPhotoCrop? = nil) {
        self.data = data
        self.kind = kind
        self.crop = crop
    }
}

public enum ContactPhotoEditError: LocalizedError {
    case photoChanged
    case saveInProgress
    case restoreFailed(save: String, restore: String)

    public var errorDescription: String? {
        switch self {
        case .photoChanged: return "The photo changed while you were editing. Cancel and open the crop editor again."
        case .saveInProgress: return "A photo is being saved. Please try again."
        case .restoreFailed(let save, let restore):
            return "The photo could not be saved or restored. Save: \(save) Restore: \(restore)"
        }
    }
}
