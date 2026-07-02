import Foundation
import SafariServices
import GuessWhoLogging

/// LinkedIn handoff native handler. Runs in the EXTENSION process.
///
/// It does NOT touch Contacts or the iCloud sidecar (the extension intentionally
/// holds neither entitlement). It only:
///   1. receives the parsed payload from the background script,
///   2. parks it in the shared **App Group** container (ephemeral IPC handoff),
///   3. acks back to JS with the per-configuration wake URL
///      (`guesswho-linkedin[-debug]://handoff`) the popup should then open to
///      wake the app (the handler itself cannot wake it — see below),
///   4. the app's scene delegate drains the parked payload on wake.
/// The app process is where match/diff/save will live (it already holds the
/// iCloud + Contacts entitlements).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// The App Group shared by the app + this extension. Read from the bundle's
    /// `GuessWhoAppGroup` Info.plist key (fed by `GUESSWHO_APP_GROUP` in the
    /// xcconfig) so it is the RIGHT id per platform — `group.`-prefixed on iOS,
    /// `<TeamID>.`-prefixed on Mac Catalyst — and can never diverge from the
    /// entitlement. Used ONLY for ephemeral handoff, NOT synced data. An empty
    /// string is treated as "missing" so an unset `GUESSWHO_APP_GROUP` (which
    /// expands to "" in the plist) falls back to the iOS literal rather than
    /// resolving an empty container identifier.
    static let appGroupID: String = {
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoAppGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "group.com.milestonemade.guesswho"
    }()

    /// Custom scheme the app registers to receive the wake. Read from the
    /// bundle's `GuessWhoLinkedInURLScheme` Info.plist key (fed by
    /// `GUESSWHO_LINKEDIN_URL_SCHEME` in the xcconfig) so it is the RIGHT
    /// scheme per configuration — `guesswho-linkedin-debug` in Debug,
    /// `guesswho-linkedin` in Release — and the Debug extension can never wake
    /// the Release app. Distinct from the `guesswho://contact/<uuid>` identity
    /// scheme to avoid collision. Empty-string fallback mirrors `appGroupID`.
    static let handoffURL: URL = {
        let scheme = (Bundle.main.object(forInfoDictionaryKey: "GuessWhoLinkedInURLScheme") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "guesswho-linkedin"
        return URL(string: "\(scheme)://handoff")!
    }()

    /// Handoff breadcrumbs route through swift-log so they land in
    /// `<AppGroup>/Logs/extension.log` (and still echo to Console via the stderr
    /// handler). Label is developer-facing; see GuessWhoLogging notes.
    private static let log = GuessWhoLog.logger("extension.handoff")

    func beginRequest(with context: NSExtensionContext) {
        // Bootstrap file logging idempotently. beginRequest runs per request, so
        // the once-per-process guard inside bootstrap (lock-protected) makes
        // repeated calls safe. processName "extension" gives this process its own
        // extension.log; appGroupID is the extension's own resolved id.
        GuessWhoLog.bootstrap(processName: "extension", appGroupID: Self.appGroupID)

        let request = context.inputItems.first as? NSExtensionItem
        let rawMessage = request?.userInfo?[SFExtensionMessageKey]

        // Log the raw shape + the App Group id this process resolved, so we can
        // see (in extension.log and Console, label extension.handoff) both what
        // Safari delivered and which container we'll write to.
        Self.log.notice("EXTENSION resolved App Group id=\(Self.appGroupID)")
        Self.log.notice("native message received: \(String(describing: rawMessage))")

        var ack: [String: Any] = ["received": false]

        if let payload = Self.extractPayload(from: rawMessage) {
            let parked = parkPayload(payload)
            // The handler does NOT (and cannot) wake the app here — see `wakeURL`
            // note below. It returns the URL for the popup to open.
            ack = ["received": true, "parked": parked, "wakeURL": Self.handoffURL.absoluteString]
        } else {
            Self.log.error("handoff message missing payload (raw: \(String(describing: rawMessage)))")
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ack]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Pull the `payload` out of whatever shape Safari delivered. Native
    /// messaging payloads can arrive as the object directly
    /// (`{ payload: ... }`) or wrapped under a `"message"` key
    /// (`{ message: { payload: ... } }`) depending on the Safari version, so we
    /// check both. Returns nil if no payload is present (e.g. the JS side sent
    /// `undefined` because the content-script probe didn't respond).
    private static func extractPayload(from raw: Any?) -> Any? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let payload = dict["payload"] { return payload }
        if let inner = dict["message"] as? [String: Any], let payload = inner["payload"] {
            return payload
        }
        return nil
    }

    /// Writes the handoff payload as a small JSON file in the App Group container.
    /// Returns true on success. The app reads (and clears) it on wake.
    private func parkPayload(_ payload: Any) -> Bool {
        Self.log.notice("park: resolving App Group id=\(Self.appGroupID)")
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            Self.log.error("park: App Group container UNAVAILABLE for id=\(Self.appGroupID) — entitlement not granting this group at runtime")
            return false
        }
        let url = container.appendingPathComponent("pending-handoff.json")
        Self.log.notice("park: writing to \(url.path)")
        do {
            let envelope: [String: Any] = ["payload": payload, "stampedBy": "extension"]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted])
            try data.write(to: url, options: [.atomic])
            Self.log.notice("park: wrote OK", ["bytes": data.count, "path": url.path])
            return true
        } catch {
            Self.log.error("park: write FAILED", ["path": url.path, "error": error.localizedDescription])
            return false
        }
    }

    // Why there is no `wakeApp()` here: a Safari Web Extension's native handler
    // runs in an NSExtension process and cannot bring the container app forward.
    //   - `UIApplication.shared` is unavailable in an app-extension process, so
    //     there is no `open(_:)` to call.
    //   - `SFSafariApplication`'s open/messaging APIs are legacy macOS-AppKit
    //     only (absent from the Catalyst SDK), and `dispatchMessage` is the
    //     app→extension-JS direction anyway — not an app-wake on ANY platform.
    // The wake is therefore initiated from the WEB side: the popup opens the
    // `wakeURL` (`handoffURL` above) returned in the ack, which the
    // app's `GuessWhoSceneDelegate` receives and drains. The browser web context
    // CAN navigate to a registered custom scheme; the native side just parks the
    // payload and reports the URL.
}
