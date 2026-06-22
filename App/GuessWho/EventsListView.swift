import SwiftUI
import GuessWhoSync

struct EventsListView: View {
    @Environment(SyncService.self) private var service
    @Bindable var repository: EventsRepository

    @State private var bannerDismissed: Bool = false
    @State private var pendingDelete: Event?
    @State private var showingLinkSheet: Bool = false
    /// When the link sheet creates an event, this drives the post-dismiss
    /// programmatic push into its detail view via `.navigationDestination(item:)`.
    @State private var navigateToEvent: EventReference?

    var body: some View {
        Group {
            switch service.eventsAuthorization {
            case .notRequested, .denied, .restricted:
                eventList(showPermissionBanner: !bannerDismissed)
            case .authorized:
                eventList(showPermissionBanner: false)
            }
        }
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingLinkSheet = true
                } label: {
                    Label("Add Event", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingLinkSheet) {
            EventLinkSheet(mode: .create(onCreated: { uuid in
                // Defer the navigation push until after the sheet's own
                // dismiss has had a chance to commit. Setting
                // `navigateToEvent` synchronously here (while the sheet is
                // still presented) can coalesce with the dismissal and the
                // push silently drops. The Task hop pushes the state
                // change to the next run-loop tick, after dismiss.
                Task { @MainActor in
                    navigateToEvent = EventReference(eventUUID: uuid)
                    await repository.reload()
                }
            }))
        }
        .navigationDestination(item: $navigateToEvent) { ref in
            EventDetailView(eventUUID: ref.eventUUID)
        }
        .confirmationDialog(
            "Remove from GuessWho? (Won't delete from Calendar.)",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { event in
            Button("Remove", role: .destructive) {
                delete(event)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .contactAndEventDestinations()
    }

    @ViewBuilder
    private func eventList(showPermissionBanner: Bool) -> some View {
        let events = repository.filtered
        List {
            if service.sidecarLocation.needsBanner {
                SidecarLocationBanner(location: service.sidecarLocation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if showPermissionBanner {
                CalendarPermissionBanner {
                    bannerDismissed = true
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(events, id: \.id) { event in
                NavigationLink(value: EventReference(eventUUID: event.id.uuidString)) {
                    EventRow(event: event)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = event
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .overlay {
            // Suppress the full-screen empty-state overlay when the
            // permission banner is visible — otherwise the overlay covers
            // the banner inside the List, and a denied user with no manual
            // events sees a generic "No Events" message with no path to the
            // permission guidance and no way to dismiss the banner.
            if events.isEmpty && !repository.searchText.isEmpty {
                ContentUnavailableView.search(text: repository.searchText)
            } else if events.isEmpty && !showPermissionBanner {
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

    private func delete(_ event: Event) {
        do {
            try service.deleteEvent(uuid: event.id.uuidString)
        } catch {
            service.recordError("delete event failed: \(error.localizedDescription)")
        }
        Task { await repository.reload() }
    }
}

private struct CalendarPermissionBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar access disabled")
                    .font(.subheadline.weight(.semibold))
                Text("Enable Calendar access in Settings to see and link calendar events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct EventRow: View {
    let event: Event

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.isLinked ? "calendar" : "calendar.badge.plus")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title.isEmpty ? "(Untitled event)" : event.title)
                    .font(.body)
                Text(event.startDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
