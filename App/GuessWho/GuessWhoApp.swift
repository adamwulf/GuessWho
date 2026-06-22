import SwiftUI

@main
struct GuessWhoApp: App {
    @State private var service: SyncService
    /// Hoisted here (not per-view) so every star button and the Favorites
    /// tab observe the same `@Observable` instance. A toggle on a detail
    /// screen updates the Favorites tab live, and there's exactly one
    /// in-memory copy + one disk read.
    @State private var favoritesStore: FavoritesListStore

    init() {
        // Register defaults so non-@AppStorage readers and the iOS Settings
        // pane both see the canonical default before the user toggles it.
        UserDefaults.standard.register(defaults: [
            AppSettings.Key.debugModeEnabled: AppSettings.Default.debugModeEnabled
        ])
        let service = SyncService()
        _service = State(initialValue: service)
        _favoritesStore = State(initialValue: FavoritesListStore(service: service))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(service)
                .environment(favoritesStore)
        }
    }
}
