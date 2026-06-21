import SwiftUI
import GuessWhoSync

struct OrganizationsListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: ContactsRepository

    var body: some View {
        let orgs = repository.organizations
        List {
            if service.sidecarLocation.needsBanner {
                SidecarLocationBanner(location: service.sidecarLocation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(orgs, id: \.localID) { contact in
                NavigationLink(value: contact.localID) {
                    ContactRow(contact: contact, hasGuessWhoUUID: service.guessWhoUUID(in: contact) != nil)
                }
            }
        }
        .overlay {
            if repository.isLoading && orgs.isEmpty {
                ProgressView()
            } else if orgs.isEmpty && !repository.organizationsSearch.isEmpty {
                ContentUnavailableView.search(text: repository.organizationsSearch)
            } else if orgs.isEmpty {
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
