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
    /// These bytes came from Contacts because the stored file couldn't be read
    /// here. Another device may be able to read that file, so it must not be replaced
    /// by a crop edit made from these bytes.
    public package(set) var storedFileUnreadable = false

    public init(data: Data, kind: ContactPhotoKind, crop: ContactPhotoCrop? = nil) {
        self.data = data
        self.kind = kind
        self.crop = crop
    }
}

/// The contact's stored photo is an older encrypted file this device can't open.
/// The repository shows the Contacts photo instead, and keeps the pointer so it
/// can tell when the stored photo changes.
struct UnreadableProfilePhotoError: Error {
    let pointer: BlobPointer
}

public enum ContactPhotoEditError: LocalizedError {
    case photoChanged
    case saveInProgress
    case storedPhotoUnreadable
    case restoreFailed(save: String, restore: String)

    public var errorDescription: String? {
        switch self {
        case .photoChanged: return "The photo changed while you were editing. Cancel and open the crop editor again."
        case .saveInProgress: return "A photo is being saved. Please try again."
        case .storedPhotoUnreadable:
            return "This photo was saved on another device and can’t be edited here. Choose a new photo to replace it."
        case .restoreFailed(let save, let restore):
            return "The photo could not be saved or restored. Save: \(save) Restore: \(restore)"
        }
    }
}
