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

    // Image bytes are loaded on demand so bulk fetches don't pay the cost.
    // - Contact does not exist          → throws ContactStoreError.contactNotFound
    // - Contact exists, no image bytes  → returns nil
    // - Contact exists, bytes available → returns the bytes
    func loadImageData(localID: String) async throws -> Data?
    func loadThumbnailImageData(localID: String) async throws -> Data?

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
