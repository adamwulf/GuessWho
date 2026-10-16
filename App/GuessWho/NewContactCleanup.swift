import UIKit
import GuessWhoSync
import GuessWhoLogging

/// The blank record the "+" of the People and Organizations lists creates
/// before its editor opens (`createNewContact`), until the user saves it
/// with Done. If the editor ends any other way, the record is deleted, so
/// "+" never leaves a blank contact behind:
///
/// * Cancel in the card, with or without "Discard changes?", deletes it and
///   closes the card (`cancel`).
/// * The Mac's "Discard changes?" before another selection replaces the
///   card deletes it; the navigation then replaces the card (`discard`).
/// * A card that goes away without either — another row clicked with
///   nothing typed, Back, a section switch, a Mail wake, its window
///   closing — deletes it once the card's view controller is gone
///   (`watch(_:)`).
///
/// Done ends it: a saved record is a normal record, so a later Edit and
/// Cancel keeps it. Done with nothing typed keeps the record too, as the
/// user left it. A failed save keeps the record and the editor, for the
/// user to try again. "Never saved" is this state, never read off the
/// record's fields: a user can type, save, and later clear them.
///
/// The delete is the one Delete Contact and a list swipe use
/// (`ContactsRepository.deleteContact(id:)`). It is tried at most once,
/// never while a save or the user's own delete runs (the outcome of that
/// write decides), and never after the user deleted the record. It shows
/// nothing: a failure is logged and the record stays.
@MainActor
final class NewContactCleanup {
    private enum Phase {
        /// Created and never saved: deleted when the editor ends.
        case unsaved
        /// A save or the user's Delete Contact is running.
        case writing
        /// Saved with Done, or Done with nothing to save.
        case kept
        /// Deleted by the user, or this cleanup's delete has started.
        case finished
    }

    private static let log = GuessWhoLog.logger("app.new-contact")

    private let deleteRecord: () -> Void
    private var phase = Phase.unsaved
    /// The card went away while a write ran, so the write's outcome decides.
    private var cardEnded = false

    /// Closes the card after Cancel; set by the shell that shows it. Must
    /// not hold the card's view controller strongly: the controller holds
    /// this cleanup (`watch(_:)`), so a strong capture would keep both alive
    /// and the delete would never run.
    var close: () -> Void = {}

    /// - Parameter deleteRecord: starts the record's delete; called at most
    ///   once, and must not wait for the delete to finish.
    init(deleteRecord: @escaping () -> Void) {
        self.deleteRecord = deleteRecord
    }

    /// A cleanup for the record `id` in `repository`.
    convenience init(id: ContactID, repository: ContactsRepository) {
        self.init {
            Task { await Self.delete(id, from: repository) }
        }
    }

    /// Cancel in the card: delete the record, then close the card. Does
    /// nothing once the record has been saved.
    func cancel() {
        guard phase == .unsaved else { return }
        // Before `close`: closing can release the card at once, and its
        // `cardDidEnd` must find the delete already started.
        deleteNow(reason: "cancel")
        close()
    }

    /// The Mac's Discard Changes before another selection replaces the
    /// card: delete the record and leave the card to the navigation.
    func discard() {
        guard phase == .unsaved else { return }
        deleteNow(reason: "discard")
    }

    /// Done with nothing to save: keep the record as it is.
    func keep() {
        guard phase == .unsaved else { return }
        phase = .kept
    }

    /// A save or Delete Contact started. Until it ends, nothing deletes.
    func writeDidBegin() {
        guard phase == .unsaved else { return }
        phase = .writing
    }

    /// The save `writeDidBegin` announced ended. A saved record is kept; a
    /// failed save leaves the record unsaved.
    func saveDidEnd(succeeded: Bool) {
        guard phase == .writing else { return }
        if succeeded {
            phase = .kept
            Self.log.notice("new record saved — keeping it")
        } else {
            writeDidFail()
        }
    }

    /// The Delete Contact `writeDidBegin` announced ended. A deleted record
    /// needs nothing more.
    func deleteDidEnd(succeeded: Bool) {
        guard phase == .writing else { return }
        if succeeded {
            phase = .finished
        } else {
            writeDidFail()
        }
    }

    /// The card went away. An unsaved record is deleted now; one with a
    /// write running is decided when the write ends.
    func cardDidEnd() {
        switch phase {
        case .unsaved:
            deleteNow(reason: "card closed")
        case .writing:
            cardEnded = true
        case .kept, .finished:
            break
        }
    }

    /// Call `cardDidEnd` when `card` — the view controller hosting the
    /// card — goes away, whatever takes it away.
    func watch(_ card: UIViewController) {
        objc_setAssociatedObject(
            card, &Self.cardLifetimeKey, CardLifetime(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func writeDidFail() {
        phase = .unsaved
        if cardEnded {
            deleteNow(reason: "card closed during a failed write")
        }
    }

    private func deleteNow(reason: String) {
        phase = .finished
        Self.log.notice("deleting the never-saved new record", ["reason": reason])
        deleteRecord()
    }

    /// The repository delete, with the "already gone" outcomes the other
    /// delete paths accept. Logs only: the user never asked for this delete.
    private static func delete(_ id: ContactID, from repository: ContactsRepository) async {
        do {
            if try await repository.deleteContact(id: id) {
                log.notice("deleted the never-saved new record")
            } else {
                log.notice("never-saved new record already gone")
            }
        } catch ContactStoreError.contactNotFound {
            repository.removeContact(id: id)
            log.notice("never-saved new record already gone from Contacts")
        } catch {
            if ContactEditModel.saveErrorCategory(error) == .recordDoesNotExist {
                repository.removeContact(id: id)
                log.notice("never-saved new record already gone from Contacts")
            } else {
                log.error("couldn't delete the never-saved new record — keeping it", [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private static var cardLifetimeKey: UInt8 = 0
}

/// Owned by the card's view controller alone, so it goes when the card goes
/// and tells the cleanup.
@MainActor
private final class CardLifetime {
    private let cleanup: NewContactCleanup

    init(_ cleanup: NewContactCleanup) {
        self.cleanup = cleanup
    }

    isolated deinit {
        cleanup.cardDidEnd()
    }
}
