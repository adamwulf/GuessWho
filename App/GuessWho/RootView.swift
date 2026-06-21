import SwiftUI
import Contacts
import GuessWhoSync

struct RootView: View {
    @Environment(SyncService.self) private var service

    @State private var contactsRepository: ContactsRepository?
    @State private var eventsRepository = EventsRepository()

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
                if let contactsRepository {
                    mainTabs(contactsRepository: contactsRepository)
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            await service.requestContactsAccessIfNeeded()
            if service.contactsAuthorization == .authorized {
                ensureContactsRepositoryAndLoad()
            }
        }
        .onChange(of: service.contactsAuthorization) { _, new in
            if new == .authorized {
                ensureContactsRepositoryAndLoad()
            }
        }
        // CNContactStore posts CNContactStoreDidChange across the address-book
        // boundary; reload both lists when it fires so an external edit
        // (e.g. via the Contacts app) shows up here without an app restart.
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            Task {
                await contactsRepository?.reload()
                await eventsRepository.reload()
            }
        }
    }

    @ViewBuilder
    private func mainTabs(contactsRepository: ContactsRepository) -> some View {
        let tabs = TabView {
            NavigationStack {
                PeopleListView(repository: contactsRepository)
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
        }

        // .sidebarAdaptable lands the same TabView as a bottom tab bar on
        // iPhone (compact) and a left-rail sidebar on iPad/Mac (regular).
        // Falls back to the plain bottom tab bar on iOS 17.
        if #available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *) {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }

    private func ensureContactsRepositoryAndLoad() {
        if contactsRepository == nil {
            contactsRepository = ContactsRepository(service: service)
        }
        Task { await contactsRepository?.reload() }
    }
}

