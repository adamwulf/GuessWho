import SwiftUI

@main
struct GuessWhoApp: App {
    @State private var service = SyncService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(service)
        }
    }
}
