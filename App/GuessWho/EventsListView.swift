import SwiftUI
import GuessWhoSync

struct EventsListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: EventsRepository

    var body: some View {
        let events = repository.filtered
        List {
            if service.sidecarLocation.needsBanner {
                SidecarLocationBanner(location: service.sidecarLocation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(events, id: \.externalID) { event in
                EventRow(event: event)
            }
        }
        .overlay {
            if events.isEmpty {
                ContentUnavailableView(
                    "Events Coming Soon",
                    systemImage: "calendar",
                    description: Text("Calendar integration isn't wired up yet. Once it is, your upcoming events will appear here.")
                )
            }
        }
        .navigationTitle("Events")
        .searchable(text: $repository.searchText, prompt: "Search events")
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
