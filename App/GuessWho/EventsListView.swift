import SwiftUI
import GuessWhoSync

struct EventsListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: EventsRepository

    var body: some View {
        Group {
            switch service.eventsAuthorization {
            case .notRequested:
                ContentUnavailableView(
                    "Requesting Calendar Access…",
                    systemImage: "calendar.badge.clock",
                    description: Text("Approve the permission prompt to view your events.")
                )
            case .denied:
                ContentUnavailableView(
                    "Calendar Access Needed",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Open Settings and enable Calendar access for GuessWho.")
                )
            case .restricted:
                ContentUnavailableView(
                    "Calendar Restricted",
                    systemImage: "lock",
                    description: Text("Calendar access is restricted on this device.")
                )
            case .authorized:
                eventList
            }
        }
        .navigationTitle("Events")
        .contactAndEventDestinations()
    }

    @ViewBuilder
    private var eventList: some View {
        let events = repository.filtered
        List {
            if service.sidecarLocation.needsBanner {
                SidecarLocationBanner(location: service.sidecarLocation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(events, id: \.externalID) { event in
                NavigationLink(value: EventReference(externalID: event.externalID)) {
                    EventRow(event: event)
                }
            }
        }
        .overlay {
            if events.isEmpty && !repository.searchText.isEmpty {
                ContentUnavailableView.search(text: repository.searchText)
            } else if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "calendar",
                    description: Text("Events from the past 30 days and next 90 days will appear here.")
                )
            }
        }
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
