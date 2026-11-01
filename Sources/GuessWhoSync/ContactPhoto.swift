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
    /// Changes with every explicit write to the `profilePhoto` cell, including one
    /// that picks the same file again.
    package var pointerRevision: String?
    package var usesSystemPhoto = false
    /// These bytes came from Contacts because the stored file couldn't be read
    /// here. Another device may be able to read that file, so it must not be replaced
    /// by a crop edit made from these bytes.
    public package(set) var storedFileUnreadable = false
    /// These bytes came from Contacts because the stored file isn't on this device,
    /// with no placeholder saying it's on its way. It may arrive, or be gone for good.
    package var storedFileMissing = false

    public init(data: Data, kind: ContactPhotoKind, crop: ContactPhotoCrop? = nil) {
        self.data = data
        self.kind = kind
        self.crop = crop
    }
}

/// One photo on a contact: stored, or the photo only Contacts holds.
public struct ContactPhotoItem: Identifiable, Equatable, Sendable {
    /// Opaque. Pass it back to the repository's photo methods.
    public let id: String
    public let isCurrent: Bool
    public let crop: ContactPhotoCrop?
    /// Nil for the photo only Contacts holds.
    public let addedAt: Date?
    /// False once reading the file here has failed because it's an older encrypted
    /// one this device can't open. Another device may still read it.
    public let isAvailable: Bool

    /// The `id` of the photo only Contacts holds.
    package static let contactsPhotoID = "contacts"

    /// True for the photo only Contacts holds.
    package var isContactsOnly: Bool { id == Self.contactsPhotoID }
}

/// The contact's stored photo is an older encrypted file this device can't open.
/// The repository shows the Contacts photo instead, and keeps the pointer so it
/// can tell when the stored photo changes.
struct UnreadableProfilePhotoError: Error {
    let pointer: BlobPointer
    let modifiedAt: Date
}

/// The contact's stored photo has no file on this device and no placeholder for one.
/// The repository shows the Contacts photo instead, and watches for the file.
struct MissingProfilePhotoFileError: Error {
    let pointer: BlobPointer
    let modifiedAt: Date
}

public enum ContactPhotoEditError: LocalizedError, Equatable {
    /// The crop editor's photo is no longer the one showing.
    case photoChanged
    /// A photo chosen in All Photos has changed or gone.
    case photoListChanged
    case saveInProgress
    case storedPhotoUnreadable
    case photoPending
    /// Reading the photo's file failed, for a reason other than it being an older
    /// encrypted one. Foundation's text names the file, so it stops at the log.
    case photoReadFailed
    case restoreFailed(save: String, restore: String)

    public var errorDescription: String? {
        switch self {
        case .photoChanged: return "The photo changed while you were editing. Cancel and open the crop editor again."
        case .photoListChanged: return "This photo changed. Check All Photos and try again."
        case .saveInProgress: return "A photo is being saved. Please try again."
        case .storedPhotoUnreadable:
            return "This photo was saved on another device and can’t be edited here. Choose a new photo to replace it."
        case .photoPending: return "This photo is still downloading. Please try again in a moment."
        case .photoReadFailed: return "A photo on this contact couldn’t be read. Please try again."
        case .restoreFailed(let save, let restore):
            return "The photo could not be saved or restored. Save: \(save) Restore: \(restore)"
        }
    }
}
