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
/// Main-actor bound, as MailKit declares `MEComposeSessionHandler`.
final class ComposeSessionHandler: NSObject, MEComposeSessionHandler {

    static let shared = ComposeSessionHandler(contactCache: MailExtensionStorage.contactCache)

    private let contactCache: MailContactCacheStore?
    private var models: [UUID: RecipientsModel] = [:]

    init(contactCache: MailContactCacheStore?) {
        self.contactCache = contactCache
        super.init()
    }

    func mailComposeSessionDidBegin(_ session: MEComposeSession) {}

    func mailComposeSessionDidEnd(_ session: MEComposeSession) {
        models[session.sessionID] = nil
    }

    func viewController(for session: MEComposeSession) -> MEExtensionViewController {
        let model = models[session.sessionID] ?? RecipientsModel(contactCache: contactCache)
        models[session.sessionID] = model
        model.show(recipients: session.mailMessage.allRecipientAddresses)
        // MailKit's documented reload path: Mail answers by calling
        // annotateAddressesForSession for every To/Cc/Bcc address, which
        // re-runs show(recipients:) with Mail's current list — a defensive
        // refresh in case the session copy handed to this call is already
        // behind an edit.
        session.reload()
        return RecipientsViewController(model: model)
    }

    func annotateAddressesForSession(
        _ session: MEComposeSession,
        completion completionHandler: @escaping ([MEEmailAddress: MEAddressAnnotation]) -> Void
    ) {
        // Only windows whose popover has been opened carry a model; others
        // skip the cache read on every keystroke.
        models[session.sessionID]?.show(recipients: session.mailMessage.allRecipientAddresses)
        completionHandler([:])
    }
}
