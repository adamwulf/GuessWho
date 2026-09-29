import AppKit
import os

/// Opens a contact in the GuessWho app from the compose popover.
///
/// The app registers a wake scheme per configuration (`guesswho-linkedin` in
/// Release, `guesswho-linkedin-debug` in Debug). This target reads it from its
/// own `GuessWhoLinkedInURLScheme` Info.plist key, fed by the same
/// `GUESSWHO_LINKEDIN_URL_SCHEME` value as the app's, so a Debug extension
/// opens the Debug app. An empty expansion falls back to the Release literal.
enum GuessWhoAppLink {
    private static let scheme: String =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoLinkedInURLScheme") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "guesswho-linkedin"

    /// Asks Launch Services to open `contactID` (a GuessWho ID) in the app.
    @MainActor
    static func open(contactID: String) {
        guard let url = MailContactLink.url(scheme: scheme, contactID: contactID) else {
            Logger.mailExtension("compose").error("open contact: not a GuessWho ID")
            return
        }
        if !NSWorkspace.shared.open(url) {
            Logger.mailExtension("compose").error("open contact: Launch Services refused the link")
        }
    }
}
