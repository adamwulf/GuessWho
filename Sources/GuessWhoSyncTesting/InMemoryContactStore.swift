import Foundation
import GuessWhoSync

public actor InMemoryContactStore: ContactStoreProtocol {
    private var contactsByID: [String: Contact]
    private var imageSideband: [String: (image: Data?, thumbnail: Data?)] = [:]
    private var groupsByID: [String: ContactGroup] = [:]
    private var groupMembers: [String: Set<String>] = [:]
    private var nextGroupSerial: Int = 1

    /// Internal-only counter used by tests to assert that bulk `fetchAll()`
    /// never peeks into the image sideband. Increments whenever the store
    /// reads or writes `imageSideband` — either via the test-only
    /// `setImageData(...)`, via `loadImageData` / `loadThumbnailImageData`,
    /// or via the auto-correct path inside `fetch(localID:)`.
    public private(set) var imageSidebandAccessCount: Int = 0

    public init(contacts: [Contact] = []) {
        var initial: [String: Contact] = [:]
        for contact in contacts {
            initial[contact.localID] = contact
        }
        self.contactsByID = initial
    }

    public func fetchAll() throws -> [Contact] {
        // §7.4 — bulk path must NOT peek at the sideband. Return whatever the
        // persisted flag says, full stop.
        return Array(contactsByID.values)
    }

    public func fetch(localID: String) throws -> Contact? {
        guard var contact = contactsByID[localID] else { return nil }
        // §7.4 — single-contact path auto-corrects `imageDataAvailable`
        // against the sideband. This peek is allowed; bulk fetchAll is not.
        imageSidebandAccessCount += 1
        let bytes = imageSideband[localID]
        let hasBytes = (bytes?.image != nil) || (bytes?.thumbnail != nil)
        if contact.imageDataAvailable != hasBytes {
            contact.imageDataAvailable = hasBytes
            contactsByID[localID] = contact
        }
        return contact
    }

    public func save(_ contact: Contact) throws {
        let previous = contactsByID[contact.localID]
        contactsByID[contact.localID] = contact
        // §7.4 — clear sideband ONLY on a true→false transition.
        if let previous, previous.imageDataAvailable == true, contact.imageDataAvailable == false {
            imageSidebandAccessCount += 1
            imageSideband.removeValue(forKey: contact.localID)
        }
    }

    public func delete(localID: String) throws {
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        contactsByID.removeValue(forKey: localID)
        // Drop any image sideband bytes for the deleted contact so a
        // fresh contact with the same ID (rare; CN re-issues) doesn't
        // inherit them.
        if imageSideband[localID] != nil {
            imageSidebandAccessCount += 1
            imageSideband.removeValue(forKey: localID)
        }
        for (gid, members) in groupMembers where members.contains(localID) {
            var updated = members
            updated.remove(localID)
            groupMembers[gid] = updated
        }
    }

    // MARK: - Groups

    public func fetchAllGroups() throws -> [ContactGroup] {
        Array(groupsByID.values)
    }

    public func fetchGroup(localID: String) throws -> ContactGroup? {
        groupsByID[localID]
    }

    public func createGroup(name: String) throws -> ContactGroup {
        let id = "in-memory-group-\(nextGroupSerial)"
        nextGroupSerial += 1
        let group = ContactGroup(localID: id, name: name)
        groupsByID[id] = group
        groupMembers[id] = []
        return group
    }

    public func renameGroup(localID: String, to name: String) throws {
        guard var group = groupsByID[localID] else {
            throw ContactStoreError.groupNotFound(localID: localID)
        }
        group.name = name
        groupsByID[localID] = group
    }

    public func deleteGroup(localID: String) throws {
        guard groupsByID[localID] != nil else {
            throw ContactStoreError.groupNotFound(localID: localID)
        }
        groupsByID.removeValue(forKey: localID)
        groupMembers.removeValue(forKey: localID)
    }

    public func fetchMembers(ofGroup groupLocalID: String) throws -> [Contact] {
        guard groupsByID[groupLocalID] != nil else {
            throw ContactStoreError.groupNotFound(localID: groupLocalID)
        }
        let memberIDs = groupMembers[groupLocalID] ?? []
        return memberIDs.compactMap { contactsByID[$0] }
    }

    public func fetchGroupMemberships(contactLocalID: String) throws -> [ContactGroup] {
        guard contactsByID[contactLocalID] != nil else {
            throw ContactStoreError.contactNotFound(localID: contactLocalID)
        }
        return groupMembers
            .filter { $0.value.contains(contactLocalID) }
            .compactMap { groupsByID[$0.key] }
    }

    public func addMember(contactLocalID: String, toGroup groupLocalID: String) throws {
        guard contactsByID[contactLocalID] != nil else {
            throw ContactStoreError.contactNotFound(localID: contactLocalID)
        }
        guard groupsByID[groupLocalID] != nil else {
            throw ContactStoreError.groupNotFound(localID: groupLocalID)
        }
        var members = groupMembers[groupLocalID] ?? []
        members.insert(contactLocalID)
        groupMembers[groupLocalID] = members
    }

    public func removeMember(contactLocalID: String, fromGroup groupLocalID: String) throws {
        guard contactsByID[contactLocalID] != nil else {
            throw ContactStoreError.contactNotFound(localID: contactLocalID)
        }
        guard groupsByID[groupLocalID] != nil else {
            throw ContactStoreError.groupNotFound(localID: groupLocalID)
        }
        var members = groupMembers[groupLocalID] ?? []
        members.remove(contactLocalID)
        groupMembers[groupLocalID] = members
    }

    public func loadImageData(localID: String) throws -> Data? {
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        imageSidebandAccessCount += 1
        return imageSideband[localID]?.image
    }

    public func loadThumbnailImageData(localID: String) throws -> Data? {
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        imageSidebandAccessCount += 1
        return imageSideband[localID]?.thumbnail
    }

    /// Test-only setter for attaching image / thumbnail bytes to a contact.
    /// Does not flip `imageDataAvailable` on the stored `Contact`; the
    /// single-contact `fetch(localID:)` path auto-corrects the flag.
    public func setImageData(_ image: Data?, thumbnail: Data?, for localID: String) {
        imageSidebandAccessCount += 1
        if image == nil && thumbnail == nil {
            imageSideband.removeValue(forKey: localID)
        } else {
            imageSideband[localID] = (image: image, thumbnail: thumbnail)
        }
    }
}
