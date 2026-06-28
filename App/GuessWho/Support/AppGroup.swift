import Foundation

/// The App Group shared by the GuessWho app and its Safari Web Extension.
///
/// Resolved from the `GuessWhoAppGroup` Info.plist key (fed by `GUESSWHO_APP_GROUP`
/// in the xcconfig) so it matches the per-platform entitlement —
/// `group.`-prefixed on iOS, `<TeamID>.`-prefixed on Mac Catalyst — with the
/// iOS group as a fallback.
///
/// `GuessWhoSceneDelegate` (handoff file) and the logging bootstrap both read
/// from here so the id is derived in exactly one place on the app side. The
/// extension target is a separate process/target and keeps its own copy
/// (`SafariWebExtensionHandler.appGroupID`).
/// An empty string is treated as "missing" too: an unset `GUESSWHO_APP_GROUP`
/// would expand to "" in the plist, which must fall back to the iOS literal
/// rather than resolve an empty container identifier.
enum AppGroup {
    static let id: String =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoAppGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "group.com.milestonemade.guesswho"
}
