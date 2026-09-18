import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Folder members with uncertain hierarchy", .serialized)
@MainActor
struct GroupHierarchyMemberTests {
    enum Damage: CaseIterable, Sendable { case unreadable, placement, identity, missingIdentity }

    @Test(arguments: Damage.allCases, [true, false])
    func unknownPlacementMakesFolderMembersPartial(damage: Damage, hasKnownMembers: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contacts = InMemoryContactStore(contacts: [Contact(localID: "ann", givenName: "Ann")])
        let backing = InMemorySidecarStore()
        let sidecars = UnreadableKeySidecarStore(wrapping: backing)
        let sync = GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "A")
        let folder = try sync.createGroupFolder(name: "Folder", parentFolderID: nil)
        let hidden = try await contacts.createGroup(name: "Hidden")
        let identity = try sync.mintGroupIdentity(name: hidden.name, memberCount: 0,
            memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
            hashedMemberCount: 0, localID: hidden.localID)
        try sync.setGroupPlacement(identityID: identity.id, parentFolderID: folder.id)
        let key = SidecarKey(kind: .group, id: identity.id)
        let original = try #require(try backing.read(key))
        if damage == .unreadable {
            sidecars.unreadable = [key]
        } else {
            var fields = original.fields
            switch damage {
            case .placement:
                fields["parentFolder"] = SidecarCell(value: .string("future format"), modifiedAt: Date(), modifiedBy: "B")
            case .identity:
                let cell = try #require(fields[GuessWhoSync.groupIdentityCellKey])
                guard case .object(var inner) = cell.value else { return }
                inner["value"] = .string("{invalid JSON")
                fields[GuessWhoSync.groupIdentityCellKey] = SidecarCell(
                    value: .object(inner), modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy)
            case .missingIdentity:
                fields.removeValue(forKey: GuessWhoSync.groupIdentityCellKey)
            case .unreadable: break
            }
            try backing.write(SidecarEnvelope(entityID: key.id, fields: fields), at: key)
        }
        if hasKnownMembers {
            let known = try await contacts.createGroup(name: "Known")
            try await contacts.addMember(contactLocalID: "ann", toGroup: known.localID)
            let knownIdentity = try sync.mintGroupIdentity(name: known.name, memberCount: 1,
                memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
                hashedMemberCount: 0, localID: known.localID)
            try sync.setGroupPlacement(identityID: knownIdentity.id, parentFolderID: folder.id)
        }
        // First load on this device: there is no last-good placement to retain.
        let repo = ContactsRepository(contacts: contacts, sync: sync, favorites: FavoritesStore(root: root),
                                      notificationCenter: NotificationCenter())
        await repo.loadGroups()
        let snapshot = await repo.memberSnapshot(for: .folder(id: folder.id))
        #expect(snapshot.hierarchyIsComplete == false)
        #expect(snapshot.isPartial)
        #expect(snapshot.failedGroups.isEmpty)
        // A first-load identity scan also fails when a group record is unreadable.
        // Malformed placement alone still permits resolving the other group.
        let showsKnownMembers = hasKnownMembers && damage != .unreadable
        #expect(snapshot.contacts.map(\.localID) == (showsKnownMembers ? ["ann"] : []))
        #expect(snapshot.emptiness == (showsKnownMembers ? .notEmpty : .unavailable))
        // A direct group read does not depend on folder placements.
        #expect(await repo.memberSnapshot(for: .group(hidden)).hierarchyIsComplete)

        sidecars.unreadable = []
        try backing.write(original, at: key)
        await repo.loadGroups()
        let recovered = await repo.memberSnapshot(for: .folder(id: folder.id))
        #expect(recovered.hierarchyIsComplete)
        #expect(recovered.isPartial == false)
    }
}
