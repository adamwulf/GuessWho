import SwiftUI

@main
struct GuessWhoApp: App {
    @State private var service = SyncService()

    init() {
        // Register defaults so non-@AppStorage readers and the iOS Settings
        // pane both see the canonical default before the user toggles it.
        UserDefaults.standard.register(defaults: [
            AppSettings.Key.debugModeEnabled: AppSettings.Default.debugModeEnabled
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(service)
        }
    }
}
