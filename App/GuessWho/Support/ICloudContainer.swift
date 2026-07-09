import Foundation

/// The iCloud ubiquity container that backs the sidecar document store.
///
/// Resolved from the `GuessWhoiCloudContainer` Info.plist key (fed by
/// `GUESSWHO_ICLOUD_CONTAINER` in the xcconfig) so it matches the container
/// declared in the entitlement, and the runtime lookup can never drift from the
/// signed entitlement. Mirrors how `AppGroup.id` reads `GuessWhoAppGroup`.
///
/// The Release id is the fallback so a build that somehow lacks the Info.plist
/// key still resolves the production container rather than failing outright.
/// An empty string is treated as "missing" too: an unset `GUESSWHO_ICLOUD_CONTAINER`
/// would expand to "" in the plist, which we must not feed to
/// `url(forUbiquityContainerIdentifier:)`.
enum ICloudContainer {
    static let id: String =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoiCloudContainer") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "iCloud.com.milestonemade.guesswho"
}
