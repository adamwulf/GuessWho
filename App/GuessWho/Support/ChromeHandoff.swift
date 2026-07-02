import Foundation

/// Configuration for the Chrome/Brave-extension handoff listener
/// (`LinkedInLocalhostReceiver`), resolved from Info.plist keys fed by the
/// per-configuration xcconfigs — the same flow `AppGroup.id` and
/// `LinkedInHandoffScheme.scheme` use, so the runtime values can never diverge
/// from the build settings. The Chrome extension's build script
/// (`App/GuessWhoChrome/build.sh`) parses the SAME xcconfig variables, which is
/// what keeps the extension and the app pointed at one another per flavor.
enum ChromeHandoff {
    /// Loopback port the app listens on, from `GuessWhoChromeHandoffPort`
    /// (xcconfig `GUESSWHO_CHROME_HANDOFF_PORT`; Debug and Release differ so a
    /// Debug extension can never reach a Release app). nil — unset, empty, or
    /// unparseable — disables the receiver rather than guessing a port.
    static let port: UInt16? =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoChromeHandoffPort") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap(UInt16.init)

    /// Chrome extension ids allowed to POST a handoff, from
    /// `GuessWhoChromeExtensionIDs` (xcconfig `GUESSWHO_CHROME_EXTENSION_IDS`,
    /// comma-separated). The ids are derived from the manifest "key"s pinned in
    /// `App/GuessWhoChrome/keys/` (build.sh prints them); the Release list also
    /// grows the Web-Store-assigned id once the extension is first uploaded.
    /// An empty list makes the receiver accept any `chrome-extension://`
    /// origin — a diagnosable fallback, not a config goal.
    static let allowedExtensionIDs: [String] =
        ((Bundle.main.object(forInfoDictionaryKey: "GuessWhoChromeExtensionIDs") as? String) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
}
