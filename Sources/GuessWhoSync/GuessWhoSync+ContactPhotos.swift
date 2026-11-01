import Foundation
import Logging

// The photos on a contact. Each stored photo has one add-only `contactPhoto` cell,
// keyed by its blobId, and the `profilePhoto` cell holds a copy of the current
// one's pointer. Merge is whole-cell last-writer-wins, so moving pointers between
// cells could lose a photo in a race. docs/profile-photos.md says what races do.

/// What a photo write does to the crop of a photo it finds already stored.
enum ContactPhotoCropChoice: Sendable {
    /// A new photo has no crop, and a stored one keeps its own.
    case existingOrNone
    case exactly(ContactPhotoCrop?)
}

/// One stored photo, from its cells alone.
struct StoredContactPhoto: Sendable {
    let pointer: BlobPointer
    let addedAt: Date
}

struct StoredContactPhotos: Sendable {
    let photos: [StoredContactPhoto]
    /// What the `profilePhoto` cell points at.
    let current: BlobPointer?
}

struct ContactPhotoMatch: Sendable {
    let pointer: BlobPointer
    let isCurrent: Bool
}

struct ContactPhotoWrite: Sendable {
    let pointer: BlobPointer
    /// False when the bytes matched a photo already on the contact.
    let isNew: Bool
}

/// The cell-level rules, shared by every write.
enum ContactPhotoCells {
    /// A fixed cell, so simultaneous first photos on two devices converge.
    static let profileCellID = "B473DB08-4B5B-42D2-991E-64C487E67C63"

    static let fieldNames: Set<String> = [
        ContactsRepository.profilePhotoFieldName,
        ContactsRepository.contactPhotoFieldName,
        ContactsRepository.previousPhotoFieldName,
    ]

    struct Cell {
        let id: String
        let name: String
        let cell: SidecarCell
        let blobID: String
        let value: JSONValue

        var createdAt: Date? {
            guard case .object(let inner) = cell.value,
                  case .string(let raw) = inner[SidecarField.innerCreatedAtKey] ?? .null else { return nil }
            return SidecarISO8601.date(from: raw)
        }
    }

    /// A tombstone at a photo's `contactPhoto` key means it was deleted, whatever else
    /// still names it. A device that hadn't seen the delete can still repoint
    /// `profilePhoto` at it, with a later stamp than the delete.
    static func isDeleted(blobID: String, in fields: [String: SidecarCell]) -> Bool {
        fields[blobID.uppercased()]?.deletedAt != nil
    }

    /// Every live cell of a photo that hasn't been deleted. The blobId is read
    /// leniently, so a partly malformed pointer still counts as naming its file.
    static func live(in fields: [String: SidecarCell]) -> [Cell] {
        fields.compactMap { id, cell in
            guard cell.deletedAt == nil, SidecarField.type(of: cell) == .blob,
                  case .object(let inner) = cell.value,
                  case .string(let name) = inner[SidecarField.innerFieldKey] ?? .null,
                  fieldNames.contains(name),
                  let value = inner[SidecarField.innerValueKey],
                  let blobID = BlobPointer.referencedBlobId(from: value),
                  !isDeleted(blobID: blobID, in: fields) else { return nil }
            return Cell(id: id, name: name, cell: cell, blobID: blobID, value: value)
        }
    }

    /// The cell whose pointer speaks for a photo: `profilePhoto` is what's showing,
    /// and `previousPhoto` is never written, so it never holds a newer crop.
    static func preferred(_ cells: [Cell]) -> Cell? {
        func rank(_ cell: Cell) -> Int {
            switch cell.name {
            case ContactsRepository.profilePhotoFieldName: return 0
            case ContactsRepository.contactPhotoFieldName: return 1
            default: return 2
            }
        }
        return cells.min { (rank($0), $0.id) < (rank($1), $1.id) }
    }

    static func addedAt(_ cells: [Cell]) -> Date {
        // The `profilePhoto` cell keeps the createdAt of the contact's first photo
        // across repoints, so its modifiedAt is when this photo became current.
        if let added = cells.first(where: { $0.name == ContactsRepository.contactPhotoFieldName }) {
            return added.createdAt ?? added.cell.modifiedAt
        }
        if let previous = cells.first(where: { $0.name == ContactsRepository.previousPhotoFieldName }) {
            return previous.createdAt ?? previous.cell.modifiedAt
        }
        return cells.first?.cell.modifiedAt ?? Date()
    }

    /// Adds the photo's `contactPhoto` cell unless the key is taken. A tombstone
    /// counts as taken: that photo was deleted on another device, and stays deleted.
    ///
    /// A photo already on the contact gets a stamp from before this write, its
    /// pointer's own, so a delete this device hasn't seen still beats the new cell.
    static func addLibraryCell(blobID: String, value: JSONValue, createdAt: Date, stamp: Date,
                               deviceID: String, to fields: inout [String: SidecarCell]) {
        let id = blobID.uppercased()
        guard fields[id] == nil else { return }
        let inner = SidecarField.makeInnerValue(field: ContactsRepository.contactPhotoFieldName, type: .blob,
                                                value: value, createdAt: createdAt)
        fields[id] = SidecarCell(value: inner, modifiedAt: stamp, modifiedBy: deviceID)
    }

    /// Gives each `profilePhoto` pointer its own cell. Two identities being merged both
    /// use the fixed `profilePhoto` cell, so one pointer loses, and with older data
    /// nothing else would name that photo's file.
    static func keepingCurrentPhotos(of envelope: SidecarEnvelope, deviceID: String) -> SidecarEnvelope {
        var fields = envelope.fields
        for slot in live(in: fields) where slot.name == ContactsRepository.profilePhotoFieldName {
            addLibraryCell(blobID: slot.blobID, value: slot.value, createdAt: slot.cell.modifiedAt,
                           stamp: slot.cell.modifiedAt, deviceID: deviceID, to: &fields)
        }
        return SidecarEnvelope(schemaVersion: envelope.schemaVersion, entityID: envelope.entityID, fields: fields)
    }

    /// Points `profilePhoto` at `pointer`. The photo it stops showing keeps a cell
    /// of its own, so it stays on the contact.
    static func setCurrent(_ pointer: BlobPointer, now: Date, deviceID: String,
                           in fields: inout [String: SidecarCell]) {
        let slots = live(in: fields).filter { $0.name == ContactsRepository.profilePhotoFieldName }
        for slot in slots where slot.blobID != pointer.blobId {
            addLibraryCell(blobID: slot.blobID, value: slot.value, createdAt: slot.cell.modifiedAt,
                           stamp: slot.cell.modifiedAt, deviceID: deviceID, to: &fields)
        }
        if let slot = slots.first,
           let inner = SidecarField.makeInnerValueForEdit(existingCell: slot.cell,
                                                          newField: ContactsRepository.profilePhotoFieldName,
                                                          newValue: pointer.jsonValue) {
            fields[slot.id] = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
        } else {
            let inner = SidecarField.makeInnerValue(field: ContactsRepository.profilePhotoFieldName, type: .blob,
                                                    value: pointer.jsonValue, createdAt: now)
            fields[profileCellID] = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
        }
    }

    /// Rewrites the pointer in the photo's `contactPhoto` cell, and in `profilePhoto`
    /// when that names it. `previousPhoto` isn't touched, and loses to both on reads.
    static func updatePointer(_ pointer: BlobPointer, now: Date, deviceID: String,
                              in fields: inout [String: SidecarCell]) {
        let cells = live(in: fields).filter { $0.blobID == pointer.blobId }
        for cell in cells where cell.name != ContactsRepository.previousPhotoFieldName {
            guard let inner = SidecarField.makeInnerValueForEdit(existingCell: cell.cell, newField: cell.name,
                                                                 newValue: pointer.jsonValue) else { continue }
            fields[cell.id] = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
        }
        addLibraryCell(blobID: pointer.blobId, value: pointer.jsonValue, createdAt: addedAt(cells),
                       stamp: cells.first?.cell.modifiedAt ?? now, deviceID: deviceID, to: &fields)
    }

    /// Tombstones every cell naming the photo, and its `contactPhoto` key even when
    /// there's no cell there yet. Older data has none, and without a tombstone a device
    /// that replaces this photo would add a cell naming a file that's gone.
    static func tombstone(blobID: String, now: Date, deviceID: String, in fields: inout [String: SidecarCell]) -> Bool {
        var changed = false
        let cells = live(in: fields).filter { $0.blobID == blobID }
        for cell in cells {
            fields[cell.id] = SidecarCell(value: cell.cell.value, modifiedAt: now, modifiedBy: deviceID, deletedAt: now)
            changed = true
        }
        let libraryKey = blobID.uppercased()
        if fields[libraryKey] == nil {
            let value = cells.first?.value ?? .object([BlobPointer.blobIdKey: .string(blobID)])
            let inner = SidecarField.makeInnerValue(field: ContactsRepository.contactPhotoFieldName, type: .blob,
                                                    value: value, createdAt: now)
            fields[libraryKey] = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID, deletedAt: now)
            changed = true
        }
        return changed
    }
}

extension GuessWhoSync {
    private static let photoLog = Logger(label: "sync.contact-photo")

    /// The photos on a contact, from their pointers. Reads no photo file.
    func storedContactPhotos(at key: SidecarKey) throws -> StoredContactPhotos {
        try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read() else { return StoredContactPhotos(photos: [], current: nil) }
            let cells = ContactPhotoCells.live(in: envelope.fields)
            let photos: [StoredContactPhoto] = Dictionary(grouping: cells, by: \.blobID).values.compactMap { group in
                guard let preferred = ContactPhotoCells.preferred(group),
                      let pointer = BlobPointer(from: preferred.value) else { return nil }
                return StoredContactPhoto(pointer: pointer, addedAt: ContactPhotoCells.addedAt(group))
            }
            let current = cells
                .filter { $0.name == ContactsRepository.profilePhotoFieldName }
                .max { $0.cell.modifiedAt < $1.cell.modifiedAt }
                .flatMap { BlobPointer(from: $0.value) }
            return StoredContactPhotos(photos: photos, current: current)
        }
    }

    /// What the `profilePhoto` cell says now, for telling when a cached photo went
    /// stale. One read is atomic, so this takes no lock.
    func currentContactPhotoCell(at key: SidecarKey) throws -> (pointer: BlobPointer, modifiedAt: Date)? {
        guard let envelope = try sidecars.read(key) else { return nil }
        let cell = ContactPhotoCells.live(in: envelope.fields)
            .filter { $0.name == ContactsRepository.profilePhotoFieldName }
            .max { $0.cell.modifiedAt < $1.cell.modifiedAt }
        guard let cell, let pointer = BlobPointer(from: cell.value) else { return nil }
        return (pointer, cell.cell.modifiedAt)
    }

    /// Whether this photo's file, or a placeholder for it, has reached this device.
    func hasContactPhotoFile(at key: SidecarKey, blobID: String) throws -> Bool {
        try sidecars.blobIds(for: key).contains(blobID)
    }

    /// The photo's bytes and crop under one lock, or nil when it isn't on the contact
    /// or its file hasn't downloaded yet. Asking starts the download.
    func storedContactPhoto(at key: SidecarKey, blobID: String) throws -> ContactPhoto? {
        try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read(),
                  let preferred = ContactPhotoCells.preferred(
                    ContactPhotoCells.live(in: envelope.fields).filter { $0.blobID == blobID }),
                  let pointer = BlobPointer(from: preferred.value),
                  let data = try ctx.readBlob(blobId: blobID) else { return nil }
            var photo = ContactPhoto(data: data, kind: .fullSize, crop: pointer.photoCrop)
            photo.blobID = blobID
            return photo
        }
    }

    /// The readable photo on this contact with the same bytes, if any.
    func contactPhotoMatching(_ data: Data, at key: SidecarKey) throws -> ContactPhotoMatch? {
        try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read(),
                  let cell = matchingCell(for: data, in: envelope.fields, ctx: ctx),
                  let pointer = BlobPointer(from: cell.value) else { return nil }
            let isCurrent = ContactPhotoCells.live(in: envelope.fields).contains {
                $0.name == ContactsRepository.profilePhotoFieldName && $0.blobID == pointer.blobId
            }
            return ContactPhotoMatch(pointer: pointer, isCurrent: isCurrent)
        }
    }

    /// Only a photo the same size can match, so most photos on a contact are never read.
    /// Older data can hold the same bytes twice, so the current photo is checked first:
    /// matching its uncropped duplicate would move current off it.
    private func matchingCell(for data: Data, in fields: [String: SidecarCell],
                              ctx: KeyLockedContext) -> ContactPhotoCells.Cell? {
        var incoming: String?
        let groups = Dictionary(grouping: ContactPhotoCells.live(in: fields), by: \.blobID).values.sorted { first, second in
            let firstIsCurrent = first.contains { $0.name == ContactsRepository.profilePhotoFieldName }
            let secondIsCurrent = second.contains { $0.name == ContactsRepository.profilePhotoFieldName }
            if firstIsCurrent != secondIsCurrent { return firstIsCurrent }
            return first[0].blobID < second[0].blobID
        }
        for group in groups {
            guard let preferred = ContactPhotoCells.preferred(group),
                  BlobPointer(from: preferred.value)?.byteCount == data.count else { continue }
            do {
                guard let stored = try ctx.readBlob(blobId: preferred.blobID) else { continue }
                let digest = incoming ?? ContactPhotoSourceTracker.digest(data)
                incoming = digest
                if ContactPhotoSourceTracker.digest(stored) == digest { return preferred }
            } catch SidecarBlobCryptoError.cannotDecrypt {
                continue
            } catch {
                // Treated as no match: the worst case is one more photo.
                Self.photoLog.error("contact photo read failed during match", metadata: error.logMetadata([
                    "id": .string(ctx.key.id), "blobId": .string(preferred.blobID),
                ]))
            }
        }
        return nil
    }

    /// Stores `data` on the contact, reusing a photo with the same bytes. A new
    /// photo's cell and any `profilePhoto` update land in one envelope write, after
    /// its file, so a racing device can't lose it.
    @discardableResult
    func storeContactPhoto(
        at key: SidecarKey,
        data: Data,
        crop: ContactPhotoCropChoice,
        makeCurrent: Bool,
        systemPhotoDigest: String?,
        expectation: BlobFieldExpectation? = nil
    ) throws -> ContactPhotoWrite {
        try withKeyLocked(key) { ctx in
            let existing = try ctx.read()
            var fields = existing?.fields ?? [:]
            try checkExpectation(expectation, field: ContactsRepository.profilePhotoFieldName, in: fields)
            let now = Date()

            var pointer: BlobPointer
            let isNew: Bool
            var cropChanged = false
            if let matched = matchingCell(for: data, in: fields, ctx: ctx),
               let found = BlobPointer(from: matched.value) {
                isNew = false
                let newCrop: ContactPhotoCrop?
                switch crop {
                case .existingOrNone: newCrop = found.photoCrop
                case .exactly(let chosen): newCrop = chosen
                }
                pointer = found.with(photoCrop: newCrop, systemPhotoDigest: found.systemPhotoDigest)
                if newCrop != found.photoCrop {
                    cropChanged = true
                    ContactPhotoCells.updatePointer(pointer, now: now, deviceID: deviceID, in: &fields)
                }
            } else {
                isNew = true
                var newCrop: ContactPhotoCrop?
                if case .exactly(let chosen) = crop { newCrop = chosen }
                pointer = BlobPointer(blobId: UUID().uuidString.lowercased(),
                                      contentType: ContactsRepository.imageContentType(of: data),
                                      byteCount: data.count, photoCrop: newCrop, systemPhotoDigest: systemPhotoDigest)
                try ctx.writeBlob(data, blobId: pointer.blobId)
                ContactPhotoCells.addLibraryCell(blobID: pointer.blobId, value: pointer.jsonValue, createdAt: now,
                                                 stamp: now, deviceID: deviceID, to: &fields)
            }
            if makeCurrent {
                pointer = pointer.with(photoCrop: pointer.photoCrop, systemPhotoDigest: systemPhotoDigest)
                ContactPhotoCells.setCurrent(pointer, now: now, deviceID: deviceID, in: &fields)
            }
            guard isNew || makeCurrent || cropChanged else {
                return ContactPhotoWrite(pointer: pointer, isNew: false)
            }
            do {
                try ctx.write(SidecarEnvelope(schemaVersion: 1, entityID: existing?.entityID ?? key.id, fields: fields))
            } catch {
                // After a timeout the envelope can still land, naming this file. If
                // it never does, the file is an orphan, which is harmless.
                if isNew, !error.isSidecarTimeout { removeFile(blobID: pointer.blobId, ctx: ctx) }
                throw error
            }
            return ContactPhotoWrite(pointer: pointer, isNew: isNew)
        }
    }

    /// Makes a photo already on the contact current, with its own crop.
    func setCurrentContactPhoto(at key: SidecarKey, blobID: String, systemPhotoDigest: String?) throws {
        try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read(),
                  let preferred = ContactPhotoCells.preferred(
                    ContactPhotoCells.live(in: envelope.fields).filter { $0.blobID == blobID }),
                  let pointer = BlobPointer(from: preferred.value) else {
                throw ContactPhotoEditError.photoListChanged
            }
            var fields = envelope.fields
            ContactPhotoCells.setCurrent(pointer.with(photoCrop: pointer.photoCrop, systemPhotoDigest: systemPhotoDigest),
                                         now: Date(), deviceID: deviceID, in: &fields)
            try ctx.write(SidecarEnvelope(schemaVersion: envelope.schemaVersion, entityID: envelope.entityID, fields: fields))
        }
    }

    /// Reframes the current photo without touching its file. Refuses if another
    /// photo became current after the editor read this one.
    func setCurrentContactPhotoCrop(at key: SidecarKey, blobID: String, crop: ContactPhotoCrop?,
                                    systemPhotoDigest: String?) throws {
        try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read() else { throw ContactPhotoEditError.photoChanged }
            var fields = envelope.fields
            try checkExpectation(.matching(blobID), field: ContactsRepository.profilePhotoFieldName, in: fields)
            let cells = ContactPhotoCells.live(in: fields).filter { $0.blobID == blobID }
            guard let preferred = ContactPhotoCells.preferred(cells),
                  let pointer = BlobPointer(from: preferred.value) else { throw ContactPhotoEditError.photoChanged }
            ContactPhotoCells.updatePointer(pointer.with(photoCrop: crop, systemPhotoDigest: systemPhotoDigest),
                                            now: Date(), deviceID: deviceID, in: &fields)
            try ctx.write(SidecarEnvelope(schemaVersion: envelope.schemaVersion, entityID: envelope.entityID, fields: fields))
        }
    }

    /// Whether this photo's file exists only as an iCloud placeholder here. Asking
    /// starts its download. A file truly missing has no placeholder, so this is false.
    func isContactPhotoFilePending(at key: SidecarKey, blobID: String) throws -> Bool {
        try withKeyLocked(key) { ctx in try ctx.pendingBlobIds().contains(blobID) }
    }

    /// Removes a photo for good: every cell naming it, then its file. Throws
    /// `.photoPending` and changes nothing while the file is only a placeholder here,
    /// because a placeholder can't be removed, and the file would stay in iCloud.
    func deleteContactPhoto(at key: SidecarKey, blobID: String) throws {
        try withKeyLocked(key) { ctx in
            guard try !ctx.pendingBlobIds().contains(blobID) else { throw ContactPhotoEditError.photoPending }
            if let envelope = try ctx.read() {
                var fields = envelope.fields
                if ContactPhotoCells.tombstone(blobID: blobID, now: Date(), deviceID: deviceID, in: &fields) {
                    try ctx.write(SidecarEnvelope(schemaVersion: envelope.schemaVersion, entityID: envelope.entityID, fields: fields))
                }
            }
            removeFile(blobID: blobID, ctx: ctx)
        }
    }

    /// For a file nothing names: its cells are tombstoned, or a write that named it
    /// failed outright. A failure here only leaves that file behind, which isn't worth
    /// failing the change over.
    private func removeFile(blobID: String, ctx: KeyLockedContext) {
        do {
            try ctx.deleteBlob(blobId: blobID)
        } catch {
            Self.photoLog.error("photo file could not be removed", metadata: error.logMetadata([
                "id": .string(ctx.key.id), "blobId": .string(blobID),
            ]))
        }
    }
}

extension BlobPointer {
    func with(photoCrop: ContactPhotoCrop?, systemPhotoDigest: String?) -> BlobPointer {
        BlobPointer(blobId: blobId, contentType: contentType, byteCount: byteCount,
                    photoCrop: photoCrop, systemPhotoDigest: systemPhotoDigest)
    }
}
