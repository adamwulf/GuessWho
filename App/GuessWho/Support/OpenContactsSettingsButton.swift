import SwiftUI

/// Alert recovery action that deep-links to the Contacts privacy pane.
/// Catalyst routes the x-apple.systempreferences:* URL through
/// LaunchServices, landing the user in System Settings → Privacy &
/// Security → Contacts. UIApplication.openSettingsURLString opens the
/// host iOS Settings app on iOS but is a no-op on Catalyst, so the URL
/// must differ per platform.
struct OpenContactsSettingsButton: View {
    var body: some View {
        #if targetEnvironment(macCatalyst)
        Button("Open System Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                UIApplication.shared.open(url)
            }
        }
        #else
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        #endif
    }
}
