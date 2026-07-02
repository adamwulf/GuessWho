import Foundation

/// The custom URL scheme the app registers to receive the LinkedIn-handoff
/// wake from the Safari Web Extension.
///
/// Resolved from the `GuessWhoLinkedInURLScheme` Info.plist key (fed by
/// `GUESSWHO_LINKEDIN_URL_SCHEME` in the xcconfig) so it matches the scheme
/// registered under `CFBundleURLTypes` for the active configuration —
/// `guesswho-linkedin-debug` in Debug, `guesswho-linkedin` in Release — and the
/// Debug extension always wakes the Debug app, never the Release install.
///
/// The extension target is a separate process/target and keeps its own copy
/// (`SafariWebExtensionHandler.handoffURL`); both must stay fed by the same
/// xcconfig variable. Distinct from the `guesswho://contact/<uuid>` identity
/// URL, which is a CNContact data-storage value, not a launch scheme.
/// An empty string is treated as "missing" too: an unset
/// `GUESSWHO_LINKEDIN_URL_SCHEME` would expand to "" in the plist, which must
/// fall back to the Release literal rather than match an empty scheme.
enum LinkedInHandoffScheme {
    static let scheme: String =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoLinkedInURLScheme") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "guesswho-linkedin"
}
