import SwiftUI

/// The deep link to the Contacts privacy pane, shared by the SwiftUI alert
/// button below and the UIKit alerts (`ContactRowDeletion`). Catalyst routes
/// the x-apple.systempreferences:* URL through LaunchServices, landing the
/// user in System Settings → Privacy & Security → Contacts.
/// UIApplication.openSettingsURLString opens the host iOS Settings app on iOS
/// but is a no-op on Catalyst, so the URL must differ per platform.
enum ContactsSettingsLink {
    #if targetEnvironment(macCatalyst)
    static let buttonTitle = "Open System Settings"
    #else
    static let buttonTitle = "Open Settings"
    #endif

    @MainActor
    static func open() {
        #if targetEnvironment(macCatalyst)
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        #else
        let urlString = UIApplication.openSettingsURLString
        #endif
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Alert recovery action that deep-links to the Contacts privacy pane.
struct OpenContactsSettingsButton: View {
    var body: some View {
        Button(ContactsSettingsLink.buttonTitle) {
            ContactsSettingsLink.open()
        }
    }
}
