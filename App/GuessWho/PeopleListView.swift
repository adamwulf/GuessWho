import SwiftUI
import GuessWhoSync

struct PeopleListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: ContactsRepository

    var body: some View {
        let people = repository.people
        List {
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
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search people"
        )
        .refreshable { await repository.reload() }
    }
}
