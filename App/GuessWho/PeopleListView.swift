import SwiftUI
import GuessWhoSync

struct PeopleListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: ContactsRepository

    /// Optional binding to a selected contact's `localID`. Provided by
    /// the 3-column NavigationSplitView on macOS/iPad-regular — rows are
    /// tagged with their `localID` and selection lives in the parent,
    /// which drives the detail column. Nil on iPhone (drill-down
    /// NavigationStack), where rows fall back to NavigationLink(value:)
    /// pushes.
    var selection: Binding<String?>? = nil

    var body: some View {
        let sections = repository.peopleSections
        let isEmpty = sections.isEmpty
        Group {
            if let selection {
                List(selection: selection) {
                    listRows(sections: sections, useTags: true)
                }
            } else {
                List {
                    listRows(sections: sections, useTags: false)
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
        .searchable(
            text: $repository.peopleSearch,
            prompt: "Search people"
        )
        .refreshable { await repository.reload() }
    }

    @ViewBuilder
    private func listRows(sections: [(String, [Contact])], useTags: Bool) -> some View {
        if service.sidecarLocation.needsBanner {
            SidecarLocationBanner(location: service.sidecarLocation)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        ForEach(sections, id: \.0) { letter, contacts in
            Section {
                ForEach(contacts, id: \.localID) { contact in
                    if useTags {
                        // Selection-driven (3-column): the row's tag
                        // matches the `String?` selection binding type,
                        // so tapping a row writes the localID into the
                        // parent's @State and the detail column
                        // re-renders against the new selection.
                        ContactRow(contact: contact, hasGuessWhoUUID: service.guessWhoUUID(in: contact) != nil)
                            .tag(contact.localID as String?)
                    } else {
                        // Push-driven (iPhone): tapping pushes a
                        // ContactReference onto the enclosing
                        // NavigationStack via .navigationDestination.
                        NavigationLink(value: ContactReference(localID: contact.localID)) {
                            ContactRow(contact: contact, hasGuessWhoUUID: service.guessWhoUUID(in: contact) != nil)
                        }
                    }
                }
            } header: {
                Text(letter)
            }
        }
    }
}
