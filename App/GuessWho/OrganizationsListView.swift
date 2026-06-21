import SwiftUI
import GuessWhoSync

struct OrganizationsListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: ContactsRepository

    var body: some View {
        let sections = repository.organizationsSections
        let isEmpty = sections.isEmpty
        List {
            if service.sidecarLocation.needsBanner {
                SidecarLocationBanner(location: service.sidecarLocation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(sections, id: \.0) { letter, contacts in
                Section {
                    ForEach(contacts, id: \.localID) { contact in
                        NavigationLink(value: contact.localID) {
                            ContactRow(contact: contact, hasGuessWhoUUID: service.guessWhoUUID(in: contact) != nil)
                        }
                    }
                } header: {
                    Text(letter)
                }
            }
        }
        .overlay {
            if repository.isLoading && isEmpty {
                ProgressView()
            } else if isEmpty && !repository.organizationsSearch.isEmpty {
                ContentUnavailableView.search(text: repository.organizationsSearch)
            } else if isEmpty {
                ContentUnavailableView(
                    "No Organizations",
                    systemImage: "building.2.crop.circle",
                    description: Text("There are no organization contacts in this account.")
                )
            }
        }
        .navigationTitle("Organizations")
        .navigationDestination(for: String.self) { localID in
            ContactDetailView(localID: localID)
        }
        .searchable(
            text: $repository.organizationsSearch,
            prompt: "Search organizations"
        )
        .refreshable { await repository.reload() }
    }
}
