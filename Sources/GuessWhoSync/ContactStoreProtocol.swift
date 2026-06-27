import Foundation

public protocol ContactStoreProtocol: Actor {
    // Each method is `async throws` so adapter implementations can
    // bridge the underlying synchronous, XPC-blocking Contacts framework
    // calls onto a dedicated `.userInitiated` queue via a continuation
    // without holding the actor's executor thread. A plain `throws`
    // shape would block the actor through the duration of the CN call
    // and reintroduce the priority inversion the bridge is here to fix.
    func fetchAll() async throws -> [Contact]
    func fetch(localID: String) async throws -> Contact?
    func save(_ contact: Contact) async throws
    func delete(localID: String) async throws

    // MARK: - Authorization
    //
    // The store owns the one true backing object (`CNContactStore`), so the
    // permission request runs here rather than in a second store the app
    // constructs. Both surface a neutral `StoreAuthorizationStatus` so the app
    // target never imports `Contacts` just to read permission state.

    /// Current contacts authorization, with `.limited` collapsed to
    /// `.authorized`. A cheap system-state read; does not enumerate the store.
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus

    /// Prompt for contacts access (no-op at the OS level if already decided)
    /// and return the resulting `StoreAccessResult`. Runs the request on this
    /// store. A thrown request surfaces as `.denied` with a non-nil
    /// `failureDescription` so the caller can restore its error-state write.
    func requestContactsAccess() async -> StoreAccessResult

    // Reads the change history since `token` (an opaque cursor previously
    // returned in `ContactChangeSet.newToken`). A `nil` token means "from the
    // beginning" — the result baselines with `requiresFullReload == true`.
    // Our own writes are excluded from the delta (tagged with a transaction
    // author at write time); only external mutations surface. See
    // `ContactChangeSet` for the ordering and full-reload contract.
    func changes(since token: Data?) async throws -> ContactChangeSet

    // Image bytes are loaded on demand so bulk fetches don't pay the cost.
    // - Contact does not exist          → throws ContactStoreError.contactNotFound
    // - Contact exists, no image bytes  → returns nil
    // - Contact exists, bytes available → returns the bytes
    func loadImageData(localID: String) async throws -> Data?
    func loadThumbnailImageData(localID: String) async throws -> Data?

    /// Write (or clear, with `nil`) the contact's photo bytes. Image bytes are
    /// owned on this dedicated path rather than through `save(_:)` — the latter
    /// deliberately preserves whatever bytes already exist so a field
    /// round-trip never disturbs the photo. Setting `imageData` writes the
    /// full-size photo; the OS derives the thumbnail. Throws
    /// `ContactStoreError.contactNotFound` when `localID` does not resolve.
    func setImageData(localID: String, imageData: Data?) async throws

    // Groups — mirror Contacts.app groups. The sidecar does not mirror group
    // metadata; these methods read/write Contacts directly. Group identity
    // is the `localID` issued by Contacts at create time.
    //
    // Lookup-by-id throws `ContactStoreError.groupNotFound` when the id does
    // not exist; `fetchGroup` returns `nil` (mirrors `fetch(localID:)`).
    // Membership mutation throws `contactNotFound` / `groupNotFound` as
    // appropriate. `InMemoryContactStore` treats add-already-member and
    // remove-non-member as no-ops; `CNContactStoreAdapter` forwards directly
    // to `CNSaveRequest.addMember` / `removeMember`, whose Apple-documented
    // behavior on those edges is unspecified — callers that need a strict
    // contract should query membership first.
    func fetchAllGroups() async throws -> [ContactGroup]
    func fetchGroup(localID: String) async throws -> ContactGroup?
    func createGroup(name: String) async throws -> ContactGroup
    func renameGroup(localID: String, to name: String) async throws
    func deleteGroup(localID: String) async throws
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact]
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup]
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws
}
