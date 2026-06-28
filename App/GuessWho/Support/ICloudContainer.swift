import Foundation

/// The iCloud ubiquity container that backs the sidecar document store.
///
/// Resolved from the `GuessWhoiCloudContainer` Info.plist key (fed by
/// `GUESSWHO_ICLOUD_CONTAINER` in the xcconfig) so it matches the container
/// declared in the entitlement — `iCloud.com.milestonemade.guesswho` for
/// Release, `iCloud.com.milestonemade.guesswho.debug` for Debug — and the
/// runtime lookup can never drift from the signed entitlement. Mirrors how
/// `AppGroup.id` reads `GuessWhoAppGroup`.
///
/// The Release id is the fallback so a build that somehow lacks the Info.plist
/// key still resolves the production container rather than failing outright.
enum ICloudContainer {
    static let id: String =
        Bundle.main.object(forInfoDictionaryKey: "GuessWhoiCloudContainer") as? String
            ?? "iCloud.com.milestonemade.guesswho"
}
