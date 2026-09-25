import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

/// A favorite's photo in the sidebar must appear, and Contacts must stop being
/// asked for it, even when the photo cache lets the photo go the moment it
/// stores it.
///
/// `ContactPhotoLoader` keeps photos in an `NSCache`, which may evict at any
/// time. The sidebar used to repaint after a load by reading that cache again,
/// so a cache that dropped the photo first turned every repaint into a miss, a
/// new Contacts fetch, and another repaint: a loop that redrew the sidebar and
/// fetched from Contacts dozens of times a second, without end (build 188 on
/// Mac Catalyst). `dropsStoredImagesForTesting` makes that eviction certain.
///
/// Serialized: both tests reset the sidebar's persisted open/closed sections,
/// which live in shared `UserDefaults`.
@MainActor
@Suite("Sidebar favorite photo repaint", .serialized)
struct SidebarPhotoRepaintTests {
    @Test
    func aLoadedPhotoStaysShownWithoutMoreFetchesWhenTheCacheDropsIt() async throws {
        let fixture = try await SidebarPhotoFixture.make(thumbnail: Self.png(side: 3))
        defer { fixture.tearDown() }

        #expect(try await fixture.rowImageSize(becoming: Self.size(3)) == Self.size(3))
        let settled = await fixture.store.thumbnailFetches
        #expect(settled >= 1)

        // Repaint the unchanged favorite again. The photo the sidebar already
        // has must be reused, not fetched again.
        fixture.favorites.reload()
        try await Task.sleep(for: .milliseconds(500))

        #expect(await fixture.store.thumbnailFetches == settled)
        #expect(fixture.rowImageSize() == Self.size(3))
    }

    @Test
    func aChangedPhotoReplacesTheHeldOneAfterContactDataChanges() async throws {
        let fixture = try await SidebarPhotoFixture.make(thumbnail: Self.png(side: 3))
        defer { fixture.tearDown() }
        #expect(try await fixture.rowImageSize(becoming: Self.size(3)) == Self.size(3))

        // The contact's photo changes in Contacts, and the repository announces
        // changed contact data — the post that drops the loader's cache and
        // rebuilds the sidebar.
        await fixture.store.setThumbnail(Self.png(side: 5))
        NotificationCenter.default.post(
            name: .contactsRepositoryDidReload,
            object: fixture.repository,
            userInfo: [ContactsRepositoryDidReloadKey.contactDataChanged: true]
        )

        #expect(try await fixture.rowImageSize(becoming: Self.size(5)) == Self.size(5))
    }

    private static func size(_ side: CGFloat) -> CGSize {
        CGSize(width: side, height: side)
    }

    /// PNG bytes at scale 1, so the decoded image's point size equals `side` —
    /// distinct from the 20-point initials placeholder the row shows until a
    /// photo lands, and from each other.
    private static func png(side: CGFloat) -> Data {
        let rect = CGRect(origin: .zero, size: size(side))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: rect.size, format: format).pngData { context in
            UIColor.systemRed.setFill()
            context.fill(rect)
        }
    }
}

/// A real sidebar in a visible window, with one favorited contact whose photo
/// comes from a counting stub store.
@MainActor
private struct SidebarPhotoFixture {
    static let contactUUID = "5ad5ad5a-0000-4000-8000-000000000001"
    static let contactName = "Ada Lovelace"

    let root: URL
    let store: SidebarPhotoContactStore
    let repository: ContactsRepository
    let favorites: FavoritesListStore
    let sidebar: SidebarViewController
    let window: UIWindow
    let savedCollapsedSections: Any?

    static func make(thumbnail: Data) async throws -> SidebarPhotoFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-sidebar-photo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/\(contactUUID)")]
        )
        let store = SidebarPhotoContactStore(contacts: [contact], thumbnail: thumbnail)
        let service = SyncService(
            contactsAdapter: store,
            eventsAdapter: SidebarPhotoEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
        let repository = service.makeContactsRepository()
        await repository.reload()

        let favorites = FavoritesListStore(service: service)
        favorites.toggle(kind: .contact, id: contactUUID)

        let photoLoader = ContactPhotoLoader(repository: repository)
        photoLoader.dropsStoredImagesForTesting = true

        // Open every section, so the favorite's row is on screen and painted.
        let savedCollapsedSections = UserDefaults.standard.object(forKey: SidebarExpansionSetting.key)
        UserDefaults.standard.removeObject(forKey: SidebarExpansionSetting.key)

        let sidebar = SidebarViewController(
            store: favorites,
            service: service,
            repository: repository,
            guidesRepository: GuidesRepository(service: service),
            photoLoader: photoLoader
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        window.rootViewController = sidebar
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        return SidebarPhotoFixture(
            root: root,
            store: store,
            repository: repository,
            favorites: favorites,
            sidebar: sidebar,
            window: window,
            savedCollapsedSections: savedCollapsedSections
        )
    }

    func tearDown() {
        window.isHidden = true
        if let savedCollapsedSections {
            UserDefaults.standard.set(savedCollapsedSections, forKey: SidebarExpansionSetting.key)
        } else {
            UserDefaults.standard.removeObject(forKey: SidebarExpansionSetting.key)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The point size of the image the favorite's row shows right now, or nil
    /// while the row is not on screen.
    func rowImageSize() -> CGSize? {
        window.layoutIfNeeded()
        guard let collectionView = sidebar.view.subviews.compactMap({ $0 as? UICollectionView }).first
        else { return nil }
        for cell in collectionView.visibleCells {
            guard let content = (cell as? UICollectionViewListCell)?.contentConfiguration
                    as? UIListContentConfiguration,
                  content.text == Self.contactName
            else { continue }
            return content.image?.size
        }
        return nil
    }

    /// Poll until the row shows an image of `target` size, returning what it
    /// last showed so a failed expectation names the real size. The favorite and
    /// its photo arrive through `Task`s, a few turns after mounting.
    func rowImageSize(becoming target: CGSize) async throws -> CGSize? {
        let deadline = ContinuousClock.now + .seconds(3)
        var observed = rowImageSize()
        while observed != target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            observed = rowImageSize()
        }
        return observed
    }
}

// MARK: - Stubs

private func sidebarPhotoStubUnused(function: String = #function) -> Never {
    fatalError("sidebar photo test stub member unexpectedly reached: \(function)")
}

private struct SidebarPhotoStubError: Error {}

/// Serves one fixed contact and a thumbnail for it, and counts thumbnail
/// fetches so a test can tell a settled row from one that keeps asking.
///
/// `changes(since:)` throws instead of trapping: the hosted app shares
/// `NotificationCenter.default`, and an external Contacts edit on the test Mac
/// must not crash the run.
private actor SidebarPhotoContactStore: ContactStoreProtocol {
    private let contacts: [Contact]
    private var thumbnail: Data
    private(set) var thumbnailFetches = 0

    init(contacts: [Contact], thumbnail: Data) {
        self.contacts = contacts
        self.thumbnail = thumbnail
    }

    func setThumbnail(_ data: Data) {
        thumbnail = data
    }

    func loadThumbnailImageData(localID: String) async throws -> Data? {
        thumbnailFetches += 1
        return thumbnail
    }

    func fetchAll() async throws -> [Contact] { contacts }
    func fetch(localID: String) async throws -> Contact? { nil }
    func save(_ contact: Contact) async throws { sidebarPhotoStubUnused() }
    func delete(localID: String) async throws { sidebarPhotoStubUnused() }
    func create(_ contact: Contact) async throws -> Contact { sidebarPhotoStubUnused() }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .authorized }
    func requestContactsAccess() async -> StoreAccessResult { sidebarPhotoStubUnused() }
    func changes(since token: Data?) async throws -> ContactChangeSet { throw SidebarPhotoStubError() }
    func loadImageData(localID: String) async throws -> Data? { nil }
    func setImageData(localID: String, imageData: Data?) async throws { sidebarPhotoStubUnused() }
    func fetchAllGroups() async throws -> [ContactGroup] { [] }
    func fetchGroup(localID: String) async throws -> ContactGroup? { nil }
    func createGroup(name: String) async throws -> ContactGroup { sidebarPhotoStubUnused() }
    func renameGroup(localID: String, to name: String) async throws { sidebarPhotoStubUnused() }
    func deleteGroup(localID: String) async throws { sidebarPhotoStubUnused() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { [] }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] { [] }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { sidebarPhotoStubUnused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { sidebarPhotoStubUnused() }
}

private final class SidebarPhotoEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .notDetermined }
    func requestEventsAccess() async -> StoreAccessResult { sidebarPhotoStubUnused() }
    func fetchEvents(in interval: DateInterval) throws -> [Event] { [] }
    func fetch(eventKitID: String) throws -> Event? { nil }
    func fetchEvents(on day: Date) throws -> [Event] { [] }
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] { [] }
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] { [] }
    func fetch(legacyEventIdentifier: String) throws -> Event? { nil }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event { sidebarPhotoStubUnused() }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws { sidebarPhotoStubUnused() }
}
