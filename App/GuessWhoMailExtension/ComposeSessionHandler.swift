import Foundation
import MailKit

/// Backs the compose-window toolbar button: a popover listing each recipient
/// with what the contact cache knows about them.
///
/// Per-window state lives in one `RecipientsModel` per `sessionID`, created
/// the first time the user opens the popover in that window and dropped when
/// the window closes. The model refreshes on the two supported MailKit
/// signals:
///   * `viewController(for:)` — Mail asks for the view (toolbar click), and
///   * `annotateAddressesForSession` — Mail reports To/Cc/Bcc edits, and
///     re-runs it for every address when we call `MEComposeSession.reload()`.
/// Recipients are never annotated (the completion always gets an empty map):
/// the cache can say who someone is, not whether an address is valid.
///
/// Main-actor bound, as MailKit declares `MEComposeSessionHandler` — but
/// MailKit calls the session lifecycle and annotation methods on its XPC
/// queue (seen in crash reports), so those are `nonisolated` and hop to the
/// main queue for the per-window state. A main-actor-isolated witness would
/// fail Swift 6's runtime executor check on that queue and trap.
/// `viewController(for:)` has been seen on the main thread, and it stays
/// isolated because it builds AppKit views.
final class ComposeSessionHandler: NSObject, MEComposeSessionHandler {

    nonisolated static let shared = ComposeSessionHandler(contactCache: MailExtensionStorage.contactCache)

    private let contactCache: MailContactCacheStore?
    private var models: [UUID: RecipientsModel] = [:]

    nonisolated init(contactCache: MailContactCacheStore?) {
        self.contactCache = contactCache
        super.init()
    }

    nonisolated func mailComposeSessionDidBegin(_ session: MEComposeSession) {
        // Decode the cache now, off the main thread, so the popover's
        // synchronous lookup finds it memoized.
        let contactCache = self.contactCache
        DispatchQueue.global(qos: .utility).async {
            _ = try? contactCache?.read()
        }
    }

    nonisolated func mailComposeSessionDidEnd(_ session: MEComposeSession) {
        let sessionID = session.sessionID
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.models[sessionID] = nil
            }
        }
    }

    func viewController(for session: MEComposeSession) -> MEExtensionViewController {
        let model = models[session.sessionID] ?? RecipientsModel(contactCache: contactCache)
        models[session.sessionID] = model
        // Synchronous, so the rows are in place when Mail first sizes the
        // popover from the view.
        model.showNow(RecipientsModel.recipients(from: session.mailMessage.allRecipientAddresses))
        // MailKit's documented reload path: Mail answers by calling
        // annotateAddressesForSession for every To/Cc/Bcc address, which
        // re-runs show(_:) with Mail's current list — a defensive refresh in
        // case the session copy handed to this call is already behind an edit.
        session.reload()
        return RecipientsViewController(model: model)
    }

    nonisolated func annotateAddressesForSession(
        _ session: MEComposeSession,
        completion completionHandler: @escaping ([MEEmailAddress: MEAddressAnnotation]) -> Void
    ) {
        let sessionID = session.sessionID
        let recipients = RecipientsModel.recipients(from: session.mailMessage.allRecipientAddresses)
        completionHandler([:])
        // The main queue runs these in the order Mail sent them, so the
        // newest recipient list is the one shown. Only windows whose popover
        // has been opened carry a model; others skip the cache read.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.models[sessionID]?.show(recipients)
            }
        }
    }
}
