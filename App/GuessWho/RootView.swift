import SwiftUI
import GuessWhoSync

struct RootView: View {
    @Environment(SyncService.self) private var service

    var body: some View {
        NavigationStack {
            ContactListView()
                .navigationTitle("GuessWho")
        }
        .task {
            await service.requestContactsAccessIfNeeded()
        }
    }
}
