import SwiftUI
import GuessWhoSync

struct PeopleListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: ContactsRepository

    var body: some View {
        let people = repository.people
        List {
            if service.sidecarLocation.needsBanner {
                SidecarLocationBanner(location: service.sidecarLocation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(people, id: \.localID) { contact in
                NavigationLink(value: contact.localID) {
                    ContactRow(contact: contact, hasGuessWhoUUID: service.guessWhoUUID(in: contact) != nil)
                }
            }
        }
        .overlay {
            if repository.isLoading && people.isEmpty {
                ProgressView()
            } else if people.isEmpty && !repository.peopleSearch.isEmpty {
                ContentUnavailableView.search(text: repository.peopleSearch)
            } else if people.isEmpty {
                ContentUnavailableView(
                    "No People",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("There are no individual contacts in this account.")
                )
            }
        }
        .navigationTitle("People")
        .navigationDestination(for: String.self) { localID in
            ContactDetailView(localID: localID)
        }
        .searchable(
            text: $repository.peopleSearch,
            prompt: "Search people"
        )
        .refreshable { await repository.reload() }
    }
}
