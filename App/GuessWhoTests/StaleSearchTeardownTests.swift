import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

/// A search query must not outlive the list controller that took it.
///
/// The search bar belongs to the list controller; the query it filters on
/// belongs to the shared, long-lived repository. Catalyst builds a brand new
/// list controller for every sidebar section switch, so those two can fall out
/// of step: an empty search bar over a repository that still holds the previous
/// list's query, which reads to the user as rows going missing for no reason.
///
/// These tests pin both halves — that UIKit does not fix this on its own, and
/// that `configureSearch` does.
@MainActor
@Suite("Stale search does not survive a list teardown")
struct StaleSearchTeardownTests {
    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-stale-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeService(root: URL, contacts: [Contact]) -> SyncService {
        SyncService(
            contactsAdapter: StaleSearchContactStore(contacts: contacts),
            eventsAdapter: StaleSearchEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
    }

    /// Mount a list the way the Catalyst supplementary column does — inside a
    /// `UINavigationController`, in a visible window — and lay it out so the
    /// table has real rows to count.
    private func mount(
        _ list: UIViewController,
        in window: UIWindow
    ) {
        window.rootViewController = UINavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    /// Rows across every section — the list sections A–Z, so section 0 alone
    /// would undercount.
    private func rowCount(in list: UIViewController) throws -> Int {
        let table = try #require(
            list.view.subviews.compactMap { $0 as? UITableView }.first,
            "the list controller should own a table view"
        )
        return (0..<table.numberOfSections).reduce(0) { total, section in
            total + table.numberOfRows(inSection: section)
        }
    }

    /// Type into the real search bar and hand the controller to the real
    /// `UISearchResultsUpdating` callback, exactly as UIKit does on a keystroke.
    private func search(_ text: String, in list: UIViewController) throws {
        let searchController = try #require(list.navigationItem.searchController)
        searchController.searchBar.text = text
        let updater = try #require(searchController.searchResultsUpdater)
        updater.updateSearchResults(for: searchController)
    }

    /// `Contact`'s public initializer leaves `localID` empty (it is Apple's
    /// token, minted by the Contacts adapter), so every fixture would otherwise
    /// share one identity and collapse into a single row. Give each a GuessWho
    /// URL instead — that is the app's real identity, and the only one a
    /// non-`@testable` caller can set.
    private func identified(
        uuid: String,
        givenName: String = "",
        familyName: String = "",
        contactType: ContactType = .person,
        organizationName: String = ""
    ) -> Contact {
        Contact(
            contactType: contactType,
            givenName: givenName,
            familyName: familyName,
            organizationName: organizationName,
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)")]
        )
    }

    private func people() -> [Contact] {
        [
            identified(uuid: "11111111-1111-1111-1111-111111111111", givenName: "Ada", familyName: "Lovelace"),
            identified(uuid: "22222222-2222-2222-2222-222222222222", givenName: "Grace", familyName: "Hopper"),
            identified(uuid: "33333333-3333-3333-3333-333333333333", givenName: "Alan", familyName: "Turing"),
        ]
    }

    /// The defect, end to end: search a People list down to one row, throw that
    /// list away, mount a fresh one, and the new list must show everybody.
    @Test
    func aFreshPeopleListShowsEveryoneAfterAnEarlierListSearched() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root, contacts: people())
        let repository = service.makeContactsRepository()
        await repository.reload()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        defer { window.isHidden = true }

        let first = ContactsListViewController(
            repository: repository,
            photoLoader: ContactPhotoLoader(repository: repository),
            favoritesStore: FavoritesListStore(service: service)
        )
        mount(first, in: window)
        #expect(try rowCount(in: first) == 3)

        try search("lovelace", in: first)
        window.layoutIfNeeded()
        #expect(repository.peopleSearch == "lovelace")
        #expect(try rowCount(in: first) == 1)

        // Tear the first list down the way a sidebar section switch does: the
        // window stops holding it, and a brand new controller replaces it.
        window.rootViewController = nil

        let second = ContactsListViewController(
            repository: repository,
            photoLoader: ContactPhotoLoader(repository: repository),
            favoritesStore: FavoritesListStore(service: service)
        )
        mount(second, in: window)

        #expect(repository.peopleSearch == "")
        #expect(second.navigationItem.searchController?.searchBar.text == "")
        #expect(try rowCount(in: second) == 3)
    }

    /// The same contract for the Organizations list, which filters on its own
    /// repository field.
    @Test
    func aFreshOrganizationsListShowsEveryOrganizationAfterAnEarlierListSearched() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let organizations = [
            identified(
                uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                contactType: .organization,
                organizationName: "Analytical Engine"
            ),
            identified(
                uuid: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                contactType: .organization,
                organizationName: "Bletchley Park"
            ),
        ]
        let service = makeService(root: root, contacts: organizations)
        let repository = service.makeContactsRepository()
        await repository.reload()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        defer { window.isHidden = true }

        let first = OrganizationsListViewController(
            repository: repository,
            photoLoader: ContactPhotoLoader(repository: repository),
            favoritesStore: FavoritesListStore(service: service)
        )
        mount(first, in: window)
        #expect(try rowCount(in: first) == 2)

        try search("bletchley", in: first)
        window.layoutIfNeeded()
        #expect(repository.organizationsSearch == "bletchley")
        #expect(try rowCount(in: first) == 1)

        window.rootViewController = nil

        let second = OrganizationsListViewController(
            repository: repository,
            photoLoader: ContactPhotoLoader(repository: repository),
            favoritesStore: FavoritesListStore(service: service)
        )
        mount(second, in: window)

        #expect(repository.organizationsSearch == "")
        #expect(try rowCount(in: second) == 2)
    }

    /// The Events list keeps its query on a third field, on a different
    /// repository.
    ///
    /// Rows are assertable here without any calendar fixtures: the list shows
    /// two paging rows ("load older" / "load later") whose visibility is gated
    /// on an EMPTY `searchText` (`showsPagingRows`), so a stale query suppresses
    /// them. Zero events plus a cleared query means two rows; zero events plus a
    /// stale query means none. The `viewDidLoad` reload runs in a `Task` and
    /// cannot interleave before the assertions — there is no `await` between
    /// mounting and reading.
    @Test
    func aFreshEventsListStartsWithNoQuery() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root, contacts: [])
        let repository = EventsRepository(service: service)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        defer { window.isHidden = true }

        let first = EventsListViewController(
            repository: repository,
            service: service,
            favoritesStore: FavoritesListStore(service: service)
        )
        mount(first, in: window)
        #expect(try rowCount(in: first) == 2)

        try search("standup", in: first)
        window.layoutIfNeeded()
        #expect(repository.searchText == "standup")
        #expect(try rowCount(in: first) == 0)

        window.rootViewController = nil

        let second = EventsListViewController(
            repository: repository,
            service: service,
            favoritesStore: FavoritesListStore(service: service)
        )
        mount(second, in: window)

        #expect(repository.searchText == "")
        #expect(second.navigationItem.searchController?.searchBar.text == "")
        #expect(try rowCount(in: second) == 2)
    }

    /// Why `configureSearch` has to republish at all: a freshly installed
    /// `UISearchController` never calls its updater with its own empty text, so
    /// nothing corrects a stale query on its own. If a future iOS starts
    /// publishing, this test fails and the republish becomes belt-and-braces
    /// rather than load-bearing — worth knowing either way.
    @Test
    func aFreshSearchControllerNeverPublishesItsOwnEmptyText() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        defer { window.isHidden = true }

        let spy = SearchUpdaterSpy()
        let host = UIViewController()
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = spy
        host.navigationItem.searchController = searchController
        host.navigationItem.hidesSearchBarWhenScrolling = false

        mount(host, in: window)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }

        #expect(spy.callCount == 0)
    }
}

// MARK: - Stubs

@MainActor
private final class SearchUpdaterSpy: NSObject, UISearchResultsUpdating {
    private(set) var callCount = 0

    func updateSearchResults(for searchController: UISearchController) {
        callCount += 1
    }
}

private func staleSearchStubUnused(function: String = #function) -> Never {
    fatalError("stale search test stub member unexpectedly reached: \(function)")
}

/// Serves a fixed contact set. Only the read path matters here — these tests
/// never write.
private actor StaleSearchContactStore: ContactStoreProtocol {
    private let contacts: [Contact]

    init(contacts: [Contact]) {
        self.contacts = contacts
    }

    func fetchAll() async throws -> [Contact] { contacts }
    // `Contact.localID` is package-protected, so this bundle cannot match on
    // it — and the list path never asks. Same as the other stubs here.
    func fetch(localID: String) async throws -> Contact? { nil }
    func save(_ contact: Contact) async throws { staleSearchStubUnused() }
    func delete(localID: String) async throws { staleSearchStubUnused() }
    func create(_ contact: Contact) async throws -> Contact { staleSearchStubUnused() }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .authorized }
    func requestContactsAccess() async -> StoreAccessResult { staleSearchStubUnused() }
    func changes(since token: Data?) async throws -> ContactChangeSet { staleSearchStubUnused() }
    func loadImageData(localID: String) async throws -> Data? { nil }
    func loadThumbnailImageData(localID: String) async throws -> Data? { nil }
    func setImageData(localID: String, imageData: Data?) async throws { staleSearchStubUnused() }
    func fetchAllGroups() async throws -> [ContactGroup] { [] }
    func fetchGroup(localID: String) async throws -> ContactGroup? { nil }
    func createGroup(name: String) async throws -> ContactGroup { staleSearchStubUnused() }
    func renameGroup(localID: String, to name: String) async throws { staleSearchStubUnused() }
    func deleteGroup(localID: String) async throws { staleSearchStubUnused() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { [] }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] { [] }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { staleSearchStubUnused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { staleSearchStubUnused() }
}

private final class StaleSearchEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .notDetermined }
    func requestEventsAccess() async -> StoreAccessResult { staleSearchStubUnused() }
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
    ) throws -> Event { staleSearchStubUnused() }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws { staleSearchStubUnused() }
}
