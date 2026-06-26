import Foundation
import SafariServices
import os.log

/// Step-0 handoff spike — native handler. Runs in the EXTENSION process.
///
/// It does NOT touch Contacts or the iCloud sidecar (the extension intentionally
/// holds neither entitlement). It only:
///   1. receives the parsed payload from the background script,
///   2. parks it in the shared **App Group** container (ephemeral IPC handoff),
///   3. wakes the GuessWho app via the `guesswho-linkedin://handoff` URL,
///   4. acks back to JS.
/// The app process is where match/diff/save will live (it already holds the
/// iCloud + Contacts entitlements).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// The single App Group shared by the app + this extension (iOS + Catalyst).
    /// Used ONLY for ephemeral handoff — NOT for synced data, which lives in the
    /// app's iCloud ubiquity container.
    static let appGroupID = "group.com.milestonemade.guesswho"

    /// Custom scheme the app registers to receive the wake. Distinct from the
    /// existing `guesswho://contact/<uuid>` identity scheme to avoid collision.
    static let handoffURL = URL(string: "guesswho-linkedin://handoff")!

    private static let log = Logger(subsystem: "com.milestonemade.guesswho.safari", category: "handoff")

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]

        var ack: [String: Any] = ["received": false]

        if let dict = message as? [String: Any], let payload = dict["payload"] {
            let parked = parkPayload(payload)
            wakeApp()
            ack = ["received": true, "parked": parked, "wakeURL": Self.handoffURL.absoluteString]
        } else {
            Self.log.error("handoff message missing payload")
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ack]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Writes the handoff payload as a small JSON file in the App Group container.
    /// Returns true on success. The app reads (and clears) it on wake.
    private func parkPayload(_ payload: Any) -> Bool {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            Self.log.error("App Group container unavailable: \(Self.appGroupID, privacy: .public)")
            return false
        }
        let url = container.appendingPathComponent("pending-handoff.json")
        do {
            let envelope: [String: Any] = ["payload": payload, "stampedBy": "extension"]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted])
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            Self.log.error("park failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Wakes the GuessWho app. On macOS/Catalyst an extension can request the
    /// app open a URL via SFSafariApplication; the exact API path is one of the
    /// things this spike validates per platform.
    private func wakeApp() {
        #if os(macOS)
        SFSafariApplication.dispatchMessage(
            withName: "open", toExtensionWithIdentifier: "", userInfo: nil
        )
        #endif
        // NOTE: Catalyst/iOS wake path is validated empirically in the spike —
        // candidates: opening the custom scheme from the app side after it polls
        // the App Group, a universal link, or SFSafariApplication APIs. This stub
        // marks the seam; the worker confirms which mechanism actually fires.
    }
}
