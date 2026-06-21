import SwiftUI

enum AppSettingsKey {
    static let debugModeEnabled = "settings.debugModeEnabled"
}

struct SettingsView: View {
    @AppStorage(AppSettingsKey.debugModeEnabled) private var debugModeEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Debug Mode", isOn: $debugModeEnabled)
            } footer: {
                Text("Shows developer diagnostics like the GuessWho reconcile indicator on contact rows.")
            }
        }
        .navigationTitle("Settings")
    }
}
