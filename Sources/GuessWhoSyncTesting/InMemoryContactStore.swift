import Foundation
import GuessWhoSync

public actor InMemoryContactStore: ContactStoreProtocol {
    private var contactsByID: [String: Contact]
    private var imageSideband: [String: (image: Data?, thumbnail: Data?)] = [:]
    private var groupsByID: [String: ContactGroup] = [:]
    private var groupMembers: [String: Set<String>] = [:]
    private var nextGroupSerial: Int = 1

    // MARK: - Change-history op log

    /// One recorded write. `seq` is the monotonic per-op token; `author` is the
    /// transaction author at write time (nil ⇒ no author), used to honor
    /// `excludedTransactionAuthors` in `changes(since:)`.
    private struct LoggedOp {
        let seq: Int64
        let change: ContactChange
        let author: String?
    }

    /// Ordered op log. Real `changes(since:)` deltas are computed against this.
    private var opLog: [LoggedOp] = []

    /// Monotonic counter handed out as each op's token. Starts at 1 so the
    /// "from the beginning" token (0) is always older than any logged op.
    private var nextOpSeq: Int64 = 1

    /// Tokens with `seq <= dropBoundary` are no longer honorable — they force a
    /// full reload. `simulateDropEverything()` advances this past everything
    /// currently logged; it also rises naturally when the log is trimmed.
    private var dropBoundary: Int64 = 0

    /// Author stamped on writes made through `save`/`delete`. Test hook —
    /// defaults to nil. Set via `setTransactionAuthor` or pass per-write with
    /// `save(_:author:)`.
    private var transactionAuthor: String?

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

    // MARK: - Authorization

    /// Simulated authorization state. Defaults to `.authorized` so existing
    /// tests that never opt into a permission flow see a granted store. Tests
    /// that exercise the gate can drive it via `setAuthorizationStatus`.
    private var authorizationStatus: StoreAuthorizationStatus = .authorized

    public func contactsAuthorizationStatus() -> StoreAuthorizationStatus {
        authorizationStatus
    }

    public func requestContactsAccess() async -> StoreAuthorizationStatus {
        // Model the OS: a `.notDetermined` store grants on request; an
        // already-decided store returns its existing verdict unchanged.
        if authorizationStatus == .notDetermined {
            authorizationStatus = .authorized
        }
        return authorizationStatus
    }

    /// Test hook — drive the simulated contacts authorization state.
    public func setAuthorizationStatus(_ status: StoreAuthorizationStatus) {
        authorizationStatus = status
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
        try save(contact, author: transactionAuthor)
    }

    /// Save tagged with a specific transaction author. Test hook so the
    /// change-history op log can exercise `excludedTransactionAuthors`.
    public func save(_ contact: Contact, author: String?) throws {
        let previous = contactsByID[contact.localID]
        contactsByID[contact.localID] = contact
        // §7.4 — clear sideband ONLY on a true→false transition.
        if let previous, previous.imageDataAvailable == true, contact.imageDataAvailable == false {
            imageSidebandAccessCount += 1
            imageSideband.removeValue(forKey: contact.localID)
        }
        recordOp(.updated(localID: contact.localID), author: author)
    }

    public func delete(localID: String) throws {
        try delete(localID: localID, author: transactionAuthor)
    }

    /// Delete tagged with a specific transaction author. Test hook — see
    /// `save(_:author:)`.
    public func delete(localID: String, author: String?) throws {
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
        // Models the Contacts.app behavior: group membership is a relation
        // through the contact's existence (no junction table), so deleting
        // a contact implicitly drops it from every group.
        for (gid, members) in groupMembers where members.contains(localID) {
            var updated = members
            updated.remove(localID)
            groupMembers[gid] = updated
        }
        recordOp(.deleted(localID: localID), author: author)
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

    // MARK: - changes(since:)

    public func changes(since token: Data?) throws -> ContactChangeSet {
        // The cursor that leaves the caller fully caught up: the seq of the
        // newest logged op (0 when nothing has been logged yet).
        let headSeq = nextOpSeq - 1
        let headToken = Self.encodeToken(headSeq)

        // nil token ⇒ first run ⇒ baseline with a full reload (mirrors CN's
        // DropEverything-on-nil-token behavior).
        guard let token, let sinceSeq = Self.decodeToken(token) else {
            return ContactChangeSet(changes: [], newToken: headToken, requiresFullReload: true)
        }

        // A token at or below the drop boundary can no longer be honored — the
        // log no longer covers it (truncation / simulated drop-everything).
        if sinceSeq < dropBoundary {
            return ContactChangeSet(changes: [], newToken: headToken, requiresFullReload: true)
        }

        // Return ops strictly after the given seq, in order, skipping writes
        // made by an excluded author.
        let changes = opLog
            .filter { $0.seq > sinceSeq }
            .filter { op in
                guard let author = op.author else { return true }
                return !excludedTransactionAuthors.contains(author)
            }
            .map { $0.change }
        return ContactChangeSet(changes: changes, newToken: headToken, requiresFullReload: false)
    }

    /// Authors whose writes `changes(since:)` filters out of the delta. Mirrors
    /// `CNChangeHistoryFetchRequest.excludedTransactionAuthors`. The default
    /// excludes our own writes, tagged with the same constant the CN adapter
    /// uses, so a self-write is invisible to the delta exactly as in production.
    private var excludedTransactionAuthors: [String] = [InMemoryContactStore.selfTransactionAuthor]

    /// The transaction author the real adapter stamps on its own writes. Kept
    /// in sync with `CNContactStoreAdapter.transactionAuthor` (the app bundle
    /// id) so the in-memory store models the same self-write exclusion.
    public static let selfTransactionAuthor = "com.milestonemade.guesswho"

    /// Appends one op to the change-history log with the next monotonic seq.
    private func recordOp(_ change: ContactChange, author: String?) {
        opLog.append(LoggedOp(seq: nextOpSeq, change: change, author: author))
        nextOpSeq += 1
    }

    /// Test hook — sets the author stamped on `save`/`delete` (the no-author
    /// overloads). Pass nil to clear.
    public func setTransactionAuthor(_ author: String?) {
        transactionAuthor = author
    }

    /// Test hook — overrides the authors excluded from the delta. Defaults to
    /// `[selfTransactionAuthor]`.
    public func setExcludedTransactionAuthors(_ authors: [String]) {
        excludedTransactionAuthors = authors
    }

    /// Test hook — models a `CNChangeHistoryDropEverythingEvent`: advances the
    /// drop boundary past everything currently logged so any previously issued
    /// token forces a `requiresFullReload`.
    public func simulateDropEverything() {
        dropBoundary = nextOpSeq - 1
    }

    /// Encodes a monotonic seq as an opaque little-endian 8-byte token.
    private static func encodeToken(_ seq: Int64) -> Data {
        var le = seq.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    /// Decodes a token produced by `encodeToken`. Returns nil for a token of
    /// the wrong size (treated as "from the beginning").
    private static func decodeToken(_ token: Data) -> Int64? {
        guard token.count == MemoryLayout<Int64>.size else { return nil }
        let le = token.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        return Int64(littleEndian: le)
    }
}
