import SwiftUI
import GuessWhoSync

struct PeopleListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: ContactsRepository

    var body: some View {
        let sections = repository.peopleSections
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
            } else if isEmpty && !repository.peopleSearch.isEmpty {
                ContentUnavailableView.search(text: repository.peopleSearch)
            } else if isEmpty {
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
                .environment(repository)
        }
        .searchable(
            text: $repository.peopleSearch,
            prompt: "Search people"
        )
        .refreshable { await repository.reload() }
    }
}
