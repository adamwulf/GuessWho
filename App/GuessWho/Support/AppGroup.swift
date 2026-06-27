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
enum AppGroup {
    static let id: String =
        Bundle.main.object(forInfoDictionaryKey: "GuessWhoAppGroup") as? String
            ?? "group.com.milestonemade.guesswho"
}
