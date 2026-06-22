import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Key.debugModeEnabled) private var debugModeEnabled = AppSettings.Default.debugModeEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Debug Mode", isOn: $debugModeEnabled)
            } footer: {
                Text("Shows developer diagnostics like the GuessWho reconcile indicator on contact rows and the Debug section on contact details.")
            }
        }
        .navigationTitle("Settings")
    }
}
