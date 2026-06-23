import SwiftUI
import Contacts
import EventKit
import GuessWhoSync

/// Sidebar entries for the 3-column NavigationSplitView used on
/// macOS and on regular-width iPadOS. Scoped to People for the first
/// pass so we can validate the architecture; the other tabs still
/// ship via the iPhone TabView and will land here as follow-ups.
enum SidebarTab: String, Identifiable, Hashable, CaseIterable {
    case people
    /// Placeholder slot used to verify the sidebar's selection wiring.
    /// Selecting it should immediately swap the content column to the
    /// "Coming soon" view; selecting "People" should restore the list.
    /// Will be replaced by a real Organizations list view once the
    /// content-column selection pattern is proven out.
    case organizationsPlaceholder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .organizationsPlaceholder: return "Organizations"
        }
    }

    var systemImage: String {
        switch self {
        case .people: return "person.2.fill"
        case .organizationsPlaceholder: return "building.2.fill"
        }
    }
}

struct RootView: View {
    @Environment(SyncService.self) private var service
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var contactsRepository: ContactsRepository?
    @State private var eventsRepository: EventsRepository?
    /// Bound to the sidebar List's `selection:`. For a List that
    /// iterates over an Identifiable collection, SwiftUI's selection
    /// type is the element's ID — `SidebarTab.ID == String`. Defaults
    /// to `.people.id` so the app opens directly on the People list.
    @State private var selectedTabID: SidebarTab.ID? = SidebarTab.people.id
    /// Bound to the People list's selection in the content column.
    /// Holds the selected contact's `localID`; nil shows the
    /// "Nothing Selected" placeholder in the detail column.
    @State private var selectedPersonLocalID: String?

    var body: some View {
        Group {
            switch service.contactsAuthorization {
            case .notRequested:
                ContentUnavailableView(
                    "Requesting Contacts Access…",
                    systemImage: "person.2.fill",
                    description: Text("Approve the permission prompt to view your contacts.")
                )
            case .denied:
                ContentUnavailableView(
                    "Contacts Access Needed",
                    systemImage: "person.crop.circle.badge.xmark",
                    description: Text("Open Settings and enable Contacts access for GuessWho.")
                )
            case .restricted:
                ContentUnavailableView(
                    "Contacts Restricted",
                    systemImage: "lock",
                    description: Text("Contacts access is restricted on this device.")
                )
            case .authorized:
                if let contactsRepository, let eventsRepository {
                    mainTabs(contactsRepository: contactsRepository, eventsRepository: eventsRepository)
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            // E5.3: sidecar-only migration; runs BEFORE any permission gate
            // so it executes even when Contacts/Events access is denied.
            service.migrateEventsIfNeeded()
            await service.requestContactsAccessIfNeeded()
            await service.requestEventsAccessIfNeeded()
            if service.contactsAuthorization == .authorized {
                ensureRepositoriesAndLoad()
            }
        }
        .onChange(of: service.contactsAuthorization) { _, new in
            if new == .authorized {
                ensureRepositoriesAndLoad()
            }
        }
        .onChange(of: service.eventsAuthorization) { _, new in
            if new == .authorized {
                Task { await eventsRepository?.reload() }
            }
        }
        // CNContactStore posts CNContactStoreDidChange across the address-book
        // boundary; reload both lists when it fires so an external edit
        // (e.g. via the Contacts app) shows up here without an app restart.
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            Task {
                await contactsRepository?.reload()
                await eventsRepository?.reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await eventsRepository?.reload() }
        }
    }

    @ViewBuilder
    private func mainTabs(contactsRepository: ContactsRepository, eventsRepository: EventsRepository) -> some View {
        #if os(macOS)
        tripleColumn(contactsRepository: contactsRepository)
        #else
        // iPad (regular size class) gets the 3-column NavigationSplitView
        // mirroring macOS; iPhone (compact) keeps its bottom-tab +
        // NavigationStack drill-down. The 3-column flow only ships People
        // for now — Organizations / Events / Favorites / Settings still
        // reach users via the iPhone TabView below until we convert each
        // to the selection-driven content/detail pattern.
        if horizontalSizeClass == .regular {
            tripleColumn(contactsRepository: contactsRepository)
        } else {
            iPhoneTabs(contactsRepository: contactsRepository, eventsRepository: eventsRepository)
        }
        #endif
    }

    /// Canonical 3-column NavigationSplitView per the SwiftUI docs:
    /// the sidebar's selection drives which list shows in the content
    /// column; the content list's selection drives which detail shows
    /// in the detail column. NavigationStack inside the detail column
    /// lets further pushes (back-refs, linked events) layer on top of
    /// the selected contact without disturbing the content list.
    @ViewBuilder
    private func tripleColumn(contactsRepository: ContactsRepository) -> some View {
        NavigationSplitView {
            // Selection type is the element's ID (SidebarTab.ID == String)
            // per Apple's three-column sample
            // (`@State private var departmentId: Department.ID?`).
            List(SidebarTab.allCases, selection: $selectedTabID) { tab in
                Label(tab.title, systemImage: tab.systemImage)
            }
            .navigationTitle("GuessWho")
        } content: {
            contentColumn(contactsRepository: contactsRepository)
        } detail: {
            detailColumn(contactsRepository: contactsRepository)
        }
        .environment(contactsRepository)
    }

    @ViewBuilder
    private func contentColumn(contactsRepository: ContactsRepository) -> some View {
        switch SidebarTab(rawValue: selectedTabID ?? "") {
        case .people:
            PeopleListView(
                repository: contactsRepository,
                selection: $selectedPersonLocalID
            )
        case .organizationsPlaceholder:
            ContentUnavailableView(
                "Organizations Coming Soon",
                systemImage: "building.2.fill",
                description: Text("Verifying sidebar selection wiring.")
            )
        case .none:
            ContentUnavailableView(
                "Pick a Section",
                systemImage: "sidebar.left",
                description: Text("Choose an item from the sidebar.")
            )
        }
    }

    @ViewBuilder
    private func detailColumn(contactsRepository: ContactsRepository) -> some View {
        if let id = selectedPersonLocalID {
            // .id(id) gives the detail view a fresh identity per
            // selection so its @State (the loaded Contact, sidecar,
            // notesStore, etc.) is rebuilt for the newly-selected
            // contact. Without this, SwiftUI keeps the first
            // ContactDetailView mounted because the `localID` prop is
            // not part of its view identity and the `task` modifier's
            // re-run rules don't refire on a value-only change.
            ContactDetailView(localID: id)
                .id(id)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "person.crop.circle",
                description: Text("Choose a person from the list to see details.")
            )
        }
    }

    #if !os(macOS)
    @ViewBuilder
    private func iPhoneTabs(contactsRepository: ContactsRepository, eventsRepository: EventsRepository) -> some View {
        let tabs = TabView {
            NavigationStack {
                PeopleListView(repository: contactsRepository)
                    .contactAndEventDestinations()
            }
            .tabItem {
                Label("People", systemImage: "person.2.fill")
            }

            NavigationStack {
                OrganizationsListView(repository: contactsRepository)
            }
            .tabItem {
                Label("Organizations", systemImage: "building.2.fill")
            }

            NavigationStack {
                EventsListView(repository: eventsRepository)
            }
            .tabItem {
                Label("Events", systemImage: "calendar")
            }

            NavigationStack {
                FavoritesListView()
            }
            .tabItem {
                Label("Favorites", systemImage: "star.fill")
            }
        }

        // ContactDetailView reads ContactsRepository from @Environment;
        // inject it at the TabView root so every NavigationStack inside
        // (People / Organizations / Events / Favorites) can push a
        // contact detail without ad-hoc per-call .environment(...) calls.
        let injected = tabs.environment(contactsRepository)

        // .sidebarAdaptable lands the same TabView as a bottom tab bar
        // on iPhone (compact). Falls back to the plain bottom tab bar
        // on iOS 17.
        if #available(iOS 18.0, *) {
            injected.tabViewStyle(.sidebarAdaptable)
        } else {
            injected
        }
    }
    #endif

    private func ensureRepositoriesAndLoad() {
        if contactsRepository == nil {
            contactsRepository = ContactsRepository(service: service)
        }
        if eventsRepository == nil {
            eventsRepository = EventsRepository(service: service)
        }
        Task { await contactsRepository?.reload() }
        Task { await eventsRepository?.reload() }
    }
}

