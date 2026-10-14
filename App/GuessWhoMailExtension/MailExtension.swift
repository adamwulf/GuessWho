import Foundation
import GuessWhoLogging
import Logging
import MailKit

/// The Mail extension's principal class (`NSExtensionPrincipalClass`). Runs in
/// the extension process Mail launches; it holds no Contacts, Calendar, or
/// iCloud access — only the shared App Group container, where the app
/// publishes the contact cache and drains the incoming-message journal, and
/// where this process writes its log.
///
/// Both handlers are process-wide singletons: Mail may ask this factory for a
/// handler more than once, and the compose handler keeps per-window state
/// that has to survive that.
///
/// `nonisolated`, although MailKit declares `MEExtension` `@MainActor`: crash
/// reports show MailKit creating this principal object on its XPC queue (on
/// the way to `decideActionForMessage` and `mailComposeSessionDidEnd`), where
/// a main-actor-isolated `init` fails Swift 6's runtime executor check and
/// traps. The handler factories are `nonisolated` too, as a precaution.
nonisolated final class MailExtension: NSObject, MEExtension {

    /// Mail creates this object in every extension process before it asks for
    /// a handler, so file logging starts here.
    override init() {
        MailLog.bootstrap()
        super.init()
    }

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

/// The extension's loggers. Lines go through GuessWhoLogging (swift-log on
/// FellerBuncher) to this process's own file,
/// `<AppGroup>/Logs/mail-yyyy-MM-dd.log`, next to the app's `app-*.log` and
/// the Safari extension's `extension-*.log`, so the app's Export Debug Logs
/// picks them up. FellerBuncher also echoes each line to the unified log with
/// subsystem `com.milestonemade.guesswho.mail` (this bundle's id) and category
/// `default` (GuessWhoLogging sets no category); the label is only in the line
/// text, e.g. `label=mail.compose`.
///
/// Lines carry fixed messages, counts, states, compose session IDs, and the
/// extension's version, build, process ID, and executable modification date —
/// never an address, name, subject, Message-ID, file path, or error
/// description. Failures log
/// `LoggedError.fingerprint`. Labels: `mail.extension` (process start),
/// `mail.compose`, `mail.message-action`.
enum MailLog {
    /// The compose popover and the app links it opens.
    static let compose = logger("mail.compose")
    /// Decisions about received messages.
    static let messageAction = logger("mail.message-action")

    /// Starts file logging for this process. Safe to call any number of
    /// times, from any thread; only the first call does the work.
    static func bootstrap() {
        _ = bootstrapOnce
    }

    /// Swift runs this initializer once, on first use, thread-safely.
    private static let bootstrapOnce: Void = {
        // The App Group the extension already reads from its GuessWhoAppGroup
        // Info.plist key for the contact cache and the journal. Without it
        // there is no shared container to log into (and no cache or journal
        // either); the embed script fails the build before that can ship.
        guard let appGroupID = MailHandoffContainer.appGroupIdentifier() else { return }
        GuessWhoLog.bootstrap(processName: "mail", appGroupID: appGroupID)
        // Which process and which build Mail is running: a Mail that stays
        // open across an install can keep talking to the old extension
        // process. Every local build reports version 0.1, build 1
        // (SharedVersion.xcconfig; only Xcode Cloud sets real numbers), so
        // the line also carries this process's ID and the modification date
        // of the extension's executable (never its path), which a local app
        // build sets when it embeds and signs the extension. Made here, not
        // as a MailLog logger, whose initializer would re-enter this one.
        let info = Bundle.main.infoDictionary
        let executableModified = (try? Bundle.main.executableURL?
            .resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .formatted(.iso8601) ?? "?"
        GuessWhoLog.logger("mail.extension").notice("mail extension started", [
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "executableModified": executableModified,
        ])
    }()

    /// A swift-log logger made after the bootstrap, so its records reach the
    /// file even when the first use of a logger comes before
    /// `MailExtension.init`. (`Logging.Logger`, not `os.Logger`.)
    private static func logger(_ label: String) -> Logging.Logger {
        bootstrap()
        return GuessWhoLog.logger(label)
    }
}

/// A loggable fingerprint of an error: its Swift type and its `NSError`
/// domain and code — never its description. Descriptions of the errors these
/// paths can throw carry file paths (the App Group container sits under the
/// user's home folder), decoding coding paths (normalized addresses are
/// dictionary keys in the contact cache), and underlying messages, none of
/// which belong in the log.
enum LoggedError {
    static func fingerprint(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(type(of: error)) domain=\(nsError.domain) code=\(nsError.code)"
    }
}
