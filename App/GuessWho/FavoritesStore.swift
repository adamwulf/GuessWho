import Foundation
import GuessWhoSync

extension Notification.Name {
    /// Posted after `FavoritesListStore.reload()` writes new items.
    /// SwiftUI views observe the store directly via @Observable; the
    /// Catalyst UIKit list subscribes to this notification so it
    /// refreshes when ContactDetailView/EventDetailView toggle the
    /// star.
    static let favoritesDidChange = Notification.Name("FavoritesDidChange")
}

/// Thin app-side view model that exposes the ordered favorites list as a
/// SwiftUI-observable property and routes mutations through SyncService.
/// The authoritative store lives in the package
/// (`GuessWhoSync.FavoritesStore`, a single JSON file). We reload after
/// every mutation so the UI mirrors what `loadAll()` returns.
///
/// Naming: the package type is `FavoritesStore`, and the module name
/// (`GuessWhoSync`) is shadowed by the package's orchestrator class of the
/// same name — so `GuessWhoSync.FavoritesStore` resolves to a member of
/// the class, not the module, and the qualification trick used elsewhere
/// (e.g. `ContactLink = Link`) can't disambiguate here. We sidestep the
/// collision by giving the app type a distinct suffix; mutations still
/// route through `SyncService` exactly like `NotesStore` /
/// `ContactLinksStore` do.
///
/// DELIBERATELY does not subscribe to `.guessWhoSidecarsDidChange` (the
/// contacts/events repositories do): `Favorites.json` lives under the same
/// watched root, but this store reloads after every app-side mutation and
/// its list is only visible on demand, so a remote toggle syncing down
/// waits for the next mutation or launch. Accepted v1 scope cut — wiring it
/// up is a one-observer change here if cross-device favorite freshness ever
/// matters.
@MainActor
@Observable
final class FavoritesListStore {
    private let service: SyncService

    private(set) var items: [Favorite] = []

    init(service: SyncService) {
        self.service = service
        // Defer the first read off the synchronous construction path: this
        // store is built inside GuessWhoAppDelegate.init, and
        // `service.favorites()` is a coordinated file read (bounded, but up
        // to ~1s against a busy cloudd) that would stall launch. The list
        // briefly renders empty and fills when the Task lands — the same
        // launch shape as every other list.
        Task { reload() }
    }

    func reload() {
        items = service.favorites()
        NotificationCenter.default.post(name: .favoritesDidChange, object: self)
    }

    func toggle(kind: FavoriteKind, id: String) {
        do {
            try service.toggleFavorite(kind: kind, id: id)
        } catch {
            // Sidecar storage unavailable or write failed — reload below
            // shows what's on disk regardless.
        }
        reload()
    }

    func toggle(_ id: FavoriteListItem.ID) {
        guard let favorite = items.first(where: { $0.matches(id) }) else { return }
        toggle(kind: favorite.kind, id: favorite.id)
    }

    func setOrder(_ items: [Favorite]) {
        do {
            try service.setFavoritesOrder(items)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }

    /// SwiftUI `.onMove` callback. Reorders the local list and persists.
    func move(from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        setOrder(reordered)
    }

    func isFavorite(kind: FavoriteKind, id: String) -> Bool {
        items.contains { $0.kind == kind && $0.id == id.lowercased() }
    }

    /// Whether the contact identified by `id` is favorited. Reads the observable
    /// cache while the package owns the ContactID → GuessWho UUID comparison.
    func isFavorite(_ id: ContactID) -> Bool {
        items.contains { $0.matches(id) }
    }
}
