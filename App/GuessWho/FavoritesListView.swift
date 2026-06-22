import SwiftUI
import Contacts
import EventKit
import GuessWhoSync

/// Ordered, user-reorderable list of favorites. One row per `Favorite` —
/// contact rows navigate to `ContactDetailView` via `ContactReference`,
/// event rows navigate to `EventDetailView` via `EventReference`. Rows
/// for missing/deleted referents fall back to "Unavailable" but still
/// support the swipe-to-unfavorite path.
struct FavoritesListView: View {
    @Environment(SyncService.self) private var service

    @State private var store: FavoritesListStore?
    /// Single-shot contacts map built from one `service.fetchAll()` per
    /// appearance — resolving each `.contact` favorite via
    /// `contact(forGuessWhoUUID:)` would be O(N × M) (review C5).
    @State private var uuidToContact: [String: Contact] = [:]

    var body: some View {
        Group {
            if let store {
                listView(store: store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favorites")
        .toolbar {
            #if os(iOS)
            // EditButton is iOS/iPadOS-only — macOS has no .editMode and
            // the symbol is unavailable. On native macOS, `.onMove` already
            // supports drag-to-reorder without an explicit edit toggle.
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            #endif
        }
        .task {
            // Build/refresh the store and contact map on appearance — no
            // NSMetadataQuery anywhere in the app, so this is how cross-
            // device freshness lands here. Same pattern as the rest of
            // the app.
            if store == nil {
                store = FavoritesListStore(service: service)
            } else {
                store?.reload()
            }
            await refreshContactMap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            Task { await refreshContactMap() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            // Events resolve per-row via the sidecar-cheap
            // `service.event(uuid:)` — but bumping the store reload keeps
            // the list consistent if an event UUID newly resolves.
            store?.reload()
        }
        .contactAndEventDestinations()
    }

    @ViewBuilder
    private func listView(store: FavoritesListStore) -> some View {
        List {
            ForEach(store.items, id: \.stableID) { favorite in
                favoriteRow(favorite, store: store)
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }
        }
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView(
                    "No Favorites",
                    systemImage: "star",
                    description: Text("Tap the star on a contact or event to add it here.")
                )
            }
        }
    }

    @ViewBuilder
    private func favoriteRow(_ favorite: Favorite, store: FavoritesListStore) -> some View {
        switch favorite.kind {
        case .contact:
            contactRow(favorite, store: store)
        case .event:
            eventRow(favorite, store: store)
        }
    }

    @ViewBuilder
    private func contactRow(_ favorite: Favorite, store: FavoritesListStore) -> some View {
        let contact = uuidToContact[favorite.id]
        if let contact {
            NavigationLink(value: ContactReference(localID: contact.localID)) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                    Text(contact.displayName)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                unfavoriteButton(favorite, store: store)
            }
        } else {
            unavailableRow(systemImage: "person.crop.circle.badge.questionmark", kindLabel: "Contact")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    unfavoriteButton(favorite, store: store)
                }
        }
    }

    @ViewBuilder
    private func eventRow(_ favorite: Favorite, store: FavoritesListStore) -> some View {
        if let event = service.event(uuid: favorite.id) {
            NavigationLink(value: EventReference(eventUUID: favorite.id, eventKitID: event.eventKitID)) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
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
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                unfavoriteButton(favorite, store: store)
            }
        } else {
            unavailableRow(systemImage: "calendar.badge.exclamationmark", kindLabel: "Event")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    unfavoriteButton(favorite, store: store)
                }
        }
    }

    @ViewBuilder
    private func unavailableRow(systemImage: String, kindLabel: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Unavailable")
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func unfavoriteButton(_ favorite: Favorite, store: FavoritesListStore) -> some View {
        Button(role: .destructive) {
            store.toggle(kind: favorite.kind, id: favorite.id)
        } label: {
            Label("Remove", systemImage: "star.slash")
        }
    }

    private func refreshContactMap() async {
        var map: [String: Contact] = [:]
        for contact in await service.fetchAll() {
            if let uuid = service.guessWhoUUID(in: contact) {
                map[uuid] = contact
            }
        }
        uuidToContact = map
    }
}
