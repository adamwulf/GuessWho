import Foundation
import MailKit
import os

/// The Mail extension's principal class (`NSExtensionPrincipalClass`). Runs in
/// the extension process Mail launches; it holds no Contacts, Calendar, or
/// iCloud access — only the shared App Group container, where the app
/// publishes the contact cache and drains the incoming-message journal.
///
/// Both handlers are process-wide singletons: Mail may ask this factory for a
/// handler more than once, and the compose handler keeps per-window state
/// that has to survive that.
final class MailExtension: NSObject, MEExtension {

    func handlerForMessageActions() -> any MEMessageActionHandler {
        MessageActionHandler.shared
    }

    func handler(for session: MEComposeSession) -> any MEComposeSessionHandler {
        ComposeSessionHandler.shared
    }
}

/// The shared files this process reads and writes, resolved once from the
/// extension's `GuessWhoAppGroup` Info.plist key. Nil only when that key is
/// missing; a container the process can't actually use shows up as an I/O
/// error on first access instead. Either way every caller leaves Mail
/// untouched.
enum MailExtensionStorage {
    static let contactCache = MailContactCacheStore.shared()
    static let journal = MailIncomingJournal.shared()
}

extension Logger {
    /// Extension diagnostics go to the unified log (Console, subsystem
    /// `com.milestonemade.guesswho.mail`). This native macOS target links no
    /// Swift packages — sharing the app's package graph across a Catalyst and
    /// a macOS target in one build collides in archive planning — so it can't
    /// use GuessWhoLogging; `os.Logger` is the Foundation-level equivalent,
    /// as in the share extension.
    static func mailExtension(_ category: String) -> Logger {
        Logger(subsystem: "com.milestonemade.guesswho.mail", category: category)
    }
}
