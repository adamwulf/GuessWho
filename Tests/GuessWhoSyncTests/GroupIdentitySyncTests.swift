import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Group identity as its own layer, across two devices (`plans/group-folders.md`,
/// "Group identity sync").
///
/// Each test builds TWO real repositories over the REAL engine. They share one
/// sidecar store and one favorites directory — what iCloud converges to — and
/// differ in everything that is device-local: the device ID, the Contacts store,
/// and therefore the local id each one holds for the same-named group. A write
/// made through device A is "synced" to device B the moment it lands in the
/// shared store; device B learns of it either at its next `loadGroups()` or
/// through a `.guessWhoSidecarsDidChange` post, exactly as the file watcher
/// would deliver it.
@Suite("Group identity sync — two devices", .serialized)
@MainActor
struct GroupIdentitySyncTests {
    // MARK: - Golden case 1: a favorite made on one device

    @Test
    func favoriteOnDeviceA_resolvesOnDeviceBAtLoad() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Work")
        await world.a.repository.loadGroups()

        #expect(try await world.a.repository.setGroupFavorite(true, for: groupA))

        await world.b.repository.loadGroups()

        #expect(world.b.repository.isGroupFavorite(groupB))
        let favorite = try #require(world.b.favorites.loadAll().first)
        #expect(world.b.repository.group(forFavoriteID: favorite.id) == groupB)
        let identity = try #require(try world.b.sync.groupIdentity(id: favorite.id))
        #expect(identity.deviceLocalIDs[World.deviceA] == groupA.localID)
        #expect(identity.deviceLocalIDs[World.deviceB] == groupB.localID)
    }

    /// The favorite arrives while device B is already running with its groups
    /// loaded. Every shape the watcher can deliver a `.group` file in must
    /// resolve it: the exact key, the coarse kind-directory item NSMetadataQuery
    /// emits alongside a file write, and a globally unknown batch.
    @Test(arguments: [Delivery.exactKey, .coarseGroupKind, .unknownScope])
    func favoriteArrivingWhileDeviceBRuns_resolvesOnDelivery(_ delivery: Delivery) async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Work")
        await world.a.repository.loadGroups()
        await world.b.repository.loadGroups()

        #expect(try await world.a.repository.setGroupFavorite(true, for: groupA))
        let favorite = try #require(world.b.favorites.loadAll().first)
        // Device B has not heard about the identity yet, and the record carries
        // no pin for it, so the synchronous accessor cannot resolve it.
        #expect(world.b.repository.group(forFavoriteID: favorite.id) == nil)

        let posted = await world.b.deliver(delivery.changeSet(identityID: favorite.id))

        #expect(posted)
        #expect(world.b.repository.group(forFavoriteID: favorite.id) == groupB)
        #expect(world.b.repository.isGroupFavorite(groupB))
    }

    // MARK: - Precondition for golden case 2: an identity with no favorite

    /// An identity that NO favorite refers to must resolve on the other device
    /// too — resolution cannot depend on which consumer minted the record.
    @Test
    func identityWithNoFavorite_resolvesOnDeviceBAtLoad() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Book Club")
        let identity = try world.mintIdentityOnDeviceA(for: groupA)

        await world.b.repository.loadGroups()

        #expect(world.b.repository.group(forFavoriteID: identity.id) == groupB)
        let stored = try #require(try world.b.sync.groupIdentity(id: identity.id))
        #expect(stored.deviceLocalIDs[World.deviceB] == groupB.localID)
        // Resolving an identity never makes its group a favorite.
        #expect(world.b.repository.isGroupFavorite(groupB) == false)
        #expect(try world.b.favorites.loadAll().isEmpty)
    }

    @Test
    func identityWithNoFavorite_resolvesOnDeviceBOnDelivery() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Book Club")
        await world.b.repository.loadGroups()
        let identity = try world.mintIdentityOnDeviceA(for: groupA)

        let posted = await world.b.deliver(Delivery.exactKey.changeSet(identityID: identity.id))

        #expect(posted)
        #expect(world.b.repository.group(forFavoriteID: identity.id) == groupB)
        #expect(world.b.repository.isGroupFavorite(groupB) == false)
    }

    // MARK: - The watcher path's one write settles

    /// Resolution on a watcher delivery writes this device's pin. That write
    /// makes the watcher post again; the echo must write nothing, or the two
    /// would loop forever.
    @Test
    func deliveryWritesOnePin_andItsEchoWritesNothing() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Work")
        await world.b.repository.loadGroups()
        let identity = try world.mintIdentityOnDeviceA(for: groupA)
        let key = SidecarKey(kind: .group, id: identity.id)
        let change = Delivery.exactKey.changeSet(identityID: identity.id)
        let writesBefore = world.sidecars.writeCount(for: key)

        #expect(await world.b.deliver(change))
        #expect(world.sidecars.writeCount(for: key) == writesBefore + 1)
        #expect(try world.b.sync.groupIdentity(id: identity.id)?
            .deviceLocalIDs[World.deviceB] == groupB.localID)

        // The echo of device B's own pin write, then one more for good measure.
        #expect(await world.b.deliver(change))
        #expect(await world.b.deliver(Delivery.coarseGroupKind.changeSet(identityID: identity.id)))
        #expect(world.sidecars.writeCount(for: key) == writesBefore + 1)
    }

    /// A delivery naming only kinds that cannot carry a group identity must not
    /// touch identities at all.
    @Test
    func coarseContactDelivery_resolvesNoIdentity() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Work")
        await world.b.repository.loadGroups()
        let identity = try world.mintIdentityOnDeviceA(for: groupA)
        let key = SidecarKey(kind: .group, id: identity.id)
        let writesBefore = world.sidecars.writeCount(for: key)

        #expect(await world.b.deliver(SidecarChangeSet(changedKeys: nil, changedKinds: [.contact])))

        #expect(world.sidecars.writeCount(for: key) == writesBefore)
        #expect(world.b.repository.group(forFavoriteID: identity.id) == nil)
    }

    // MARK: - Resolution waits for a real group cache

    /// Before `loadGroups()` the group cache is empty, so every pin LOOKS dead.
    /// Neither a watcher delivery nor a contact reload may prune a good pin on
    /// that evidence.
    @Test
    func deliveryAndReloadBeforeGroupsLoad_doNotPruneALivePin() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Work")
        await world.a.repository.loadGroups()
        #expect(try await world.a.repository.setGroupFavorite(true, for: groupA))
        let favorite = try #require(world.b.favorites.loadAll().first)
        let key = SidecarKey(kind: .group, id: favorite.id)

        // A first session on device B adopts the identity and pins it.
        await world.b.repository.loadGroups()
        #expect(try world.b.sync.groupIdentity(id: favorite.id)?
            .deviceLocalIDs[World.deviceB] == groupB.localID)

        // A later launch: a fresh repository whose groups have not loaded yet.
        let relaunched = world.relaunchDeviceB()
        let writesBefore = world.sidecars.writeCount(for: key)

        #expect(await relaunched.deliver(Delivery.exactKey.changeSet(identityID: favorite.id)))
        await relaunched.repository.reload()

        #expect(world.sidecars.writeCount(for: key) == writesBefore)
        #expect(try relaunched.sync.groupIdentity(id: favorite.id)?
            .deviceLocalIDs[World.deviceB] == groupB.localID)

        // Once the cache is real, the pinned identity resolves with no write.
        await relaunched.repository.loadGroups()
        #expect(relaunched.repository.isGroupFavorite(groupB))
        #expect(world.sidecars.writeCount(for: key) == writesBefore)
    }

    // MARK: - One identity per group, chosen deterministically

    /// Two devices that each first-touch the same group before they sync leave
    /// two identities. Every lookup must use the smallest UUID, whichever order
    /// the identities resolved in, and must not mint a third. Resolved together
    /// at load the smaller one resolves FIRST; when it syncs in afterwards it
    /// resolves LAST, and must then take over the group's reverse pointer.
    @Test(arguments: [false, true])
    func duplicateIdentities_useTheSmallestUUID(smallerArrivesLater: Bool) async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Team")
        let smaller = "11111111-0000-4000-8000-000000000001"
        let larger = "ffffffff-0000-4000-8000-000000000002"
        func write(_ id: String) throws {
            try world.a.sync.writeGroupIdentity(GroupIdentity(
                id: id,
                name: GroupIdentity.normalizedName(groupA.name),
                memberCount: 0,
                memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
                hashedMemberCount: 0))
        }

        try write(larger)
        if smallerArrivesLater {
            await world.a.repository.loadGroups()
            try write(smaller)
            #expect(await world.a.deliver(Delivery.exactKey.changeSet(identityID: smaller)))
        } else {
            try write(smaller)
            await world.a.repository.loadGroups()
        }

        #expect(try await world.a.repository.setGroupFavorite(true, for: groupA))

        let groupFavorites = try world.a.favorites.loadAll().filter { $0.kind == .group }
        #expect(groupFavorites.map(\.id) == [smaller])
        #expect(world.a.repository.isGroupFavorite(groupA))
        #expect(try world.a.sync.allGroupIdentities().count == 2)
    }

    // MARK: - Deliveries

    enum Delivery: Sendable, CustomTestStringConvertible {
        case exactKey
        case coarseGroupKind
        case unknownScope

        var testDescription: String {
            switch self {
            case .exactKey: "exact .group key"
            case .coarseGroupKind: "coarse .group kind directory"
            case .unknownScope: "globally unknown scope"
            }
        }

        func changeSet(identityID: String) -> SidecarChangeSet {
            switch self {
            case .exactKey:
                SidecarChangeSet(changedKeys: [SidecarKey(kind: .group, id: identityID)])
            case .coarseGroupKind:
                SidecarChangeSet(changedKeys: nil, changedKinds: [.group])
            case .unknownScope:
                .fullRefresh
            }
        }
    }

    // MARK: - Two-device world

    @MainActor
    final class Device {
        let contacts: InMemoryContactStore
        let sync: GuessWhoSync
        let favorites: FavoritesStore
        let center: NotificationCenter
        let repository: ContactsRepository

        init(deviceID: String, contacts: InMemoryContactStore, sidecars: SidecarStoreProtocol, favoritesRoot: URL) {
            self.contacts = contacts
            self.sync = GuessWhoSync(
                contacts: contacts,
                events: InMemoryEventStore(),
                sidecars: sidecars,
                deviceID: deviceID)
            self.favorites = FavoritesStore(root: favoritesRoot)
            self.center = NotificationCenter()
            self.repository = ContactsRepository(
                contacts: contacts,
                sync: sync,
                favorites: favorites,
                notificationCenter: center)
        }

        /// Post a sidecar change as the file watcher would and wait for the
        /// repository's debounced refresh to finish (its `.contactsRepositoryDidReload`).
        /// Returns whether it arrived, so a dropped refresh fails the test
        /// instead of hanging it.
        func deliver(_ changeSet: SidecarChangeSet, timeout: Duration = .seconds(2)) async -> Bool {
            nonisolated(unsafe) var fired = false
            let token = center.addObserver(
                forName: .contactsRepositoryDidReload, object: repository, queue: nil
            ) { _ in fired = true }
            defer { center.removeObserver(token) }

            center.post(
                name: .guessWhoSidecarsDidChange,
                object: nil,
                userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: changeSet])

            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !fired && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return fired
        }
    }

    @MainActor
    final class World {
        static let deviceA = "device-A"
        static let deviceB = "device-B"

        let root: URL
        let sidecars: WriteCountingSidecarStore
        let a: Device
        private(set) var b: Device

        init(root: URL) {
            self.root = root
            self.sidecars = WriteCountingSidecarStore(wrapping: InMemorySidecarStore())
            self.a = Device(
                deviceID: Self.deviceA, contacts: InMemoryContactStore(),
                sidecars: sidecars, favoritesRoot: root)
            self.b = Device(
                deviceID: Self.deviceB, contacts: InMemoryContactStore(),
                sidecars: sidecars, favoritesRoot: root)
        }

        /// The same Contacts group as each device sees it: one name, two
        /// different device-local ids. The in-memory store numbers its groups
        /// serially, so device B gets a decoy first to keep the ids apart.
        func createSharedGroup(named name: String) async throws -> (a: ContactGroup, b: ContactGroup) {
            _ = try await b.contacts.createGroup(name: "Device B Only")
            let groupA = try await a.contacts.createGroup(name: name)
            let groupB = try await b.contacts.createGroup(name: name)
            try #require(groupA.localID != groupB.localID)
            return (groupA, groupB)
        }

        /// An identity device A holds for `group` that no favorite refers to.
        func mintIdentityOnDeviceA(for group: ContactGroup) throws -> GroupIdentity {
            try a.sync.mintGroupIdentity(
                name: group.name,
                memberCount: 0,
                memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
                hashedMemberCount: 0,
                localID: group.localID)
        }

        /// A new app session on device B: same Contacts store, same synced
        /// data, but a fresh repository that has loaded nothing yet.
        func relaunchDeviceB() -> Device {
            b = Device(
                deviceID: Self.deviceB, contacts: b.contacts,
                sidecars: sidecars, favoritesRoot: root)
            return b
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeWorld() throws -> World {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-group-identity-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return World(root: root)
    }
}

/// Test-only sidecar store that forwards every call to an `InMemorySidecarStore`
/// and counts envelope writes per key, so a test can prove how many times a
/// path wrote rather than infer it from timing.
final class WriteCountingSidecarStore: SidecarStoreProtocol {
    private let inner: InMemorySidecarStore
    private let lock = NSLock()
    private var writeCounts: [SidecarKey: Int] = [:]

    init(wrapping inner: InMemorySidecarStore) { self.inner = inner }

    func writeCount(for key: SidecarKey) -> Int {
        lock.lock(); defer { lock.unlock() }
        return writeCounts[key, default: 0]
    }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? { try inner.read(key) }
    func allKeys() throws -> [SidecarKey] { try inner.allKeys() }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        try inner.write(envelope, at: key)
        lock.lock(); writeCounts[key, default: 0] += 1; lock.unlock()
    }
    func delete(_ key: SidecarKey) throws { try inner.delete(key) }
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus { inner.downloadStatus(key) }
    func requestDownload(_ key: SidecarKey) throws { try inner.requestDownload(key) }
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws {
        try inner.writeBlob(data, blobId: blobId, for: key)
    }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? {
        try inner.readBlob(blobId: blobId, for: key)
    }
    func deleteBlob(blobId: String, for key: SidecarKey) throws {
        try inner.deleteBlob(blobId: blobId, for: key)
    }
    func blobIds(for key: SidecarKey) throws -> [String] { try inner.blobIds(for: key) }
}
