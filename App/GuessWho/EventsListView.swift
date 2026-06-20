import SwiftUI
import GuessWhoSync

struct EventsListView: View {
    @Bindable var repository: EventsRepository

    var body: some View {
        Group {
            if repository.events.isEmpty {
                ContentUnavailableView(
                    "Events Coming Soon",
                    systemImage: "calendar",
                    description: Text("Calendar integration isn't wired up yet. Once it is, your upcoming events will appear here.")
                )
            } else {
                List {
                    ForEach(repository.filtered, id: \.externalID) { event in
                        EventRow(event: event)
                    }
                }
                .searchable(text: $repository.searchText, prompt: "Search events")
            }
        }
        .navigationTitle("Events")
        .refreshable { await repository.reload() }
    }
}

private struct EventRow: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title.isEmpty ? "(Untitled event)" : event.title)
                .font(.body)
            Text(event.startDate, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
