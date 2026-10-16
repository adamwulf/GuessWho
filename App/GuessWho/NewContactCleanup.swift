import UIKit
import GuessWhoSync
import GuessWhoLogging

/// The blank record the "+" of the People and Organizations lists creates
/// before its editor opens (`createNewContact`), until the user ends the
/// editor with Done. If the card goes away any other way, the record is
/// deleted, so "+" doesn't leave a blank contact behind. The one exception
/// is a quit or a termination with the card open: nothing gets to run, and
/// the blank record stays (it isn't reopened at the next launch).
///
/// The delete happens once, when the card's view controller is gone
/// (`watch(_:)`), whatever took it away:
///
/// * After Cancel, with or without "Discard changes?" (`cancel`, which also
///   closes the card), or the Mac's Discard Changes before another
///   selection replaces it (`discard`): the record goes, with anything the
///   user added to it.
/// * With no question asked — another row clicked with nothing typed, Back,
///   a section switch, a Mail wake, its window closing: the record goes only
///   while it is still blank. A photo or a dated note the user added on the
///   card (`recordDidGetUserData`), or a note draft with text in it
///   (`noteDraftDidChange`), keeps it, and so does anything put on the
///   record elsewhere that `ContactsRepository.isBlankAndUntouched` finds —
///   fields, a photo, a group, a favorite, a link, notes or any other
///   GuessWho data. A check that can't read something keeps it too.
///   Because the card asks "Discard changes?" about its own additions
///   (`hasUnsavedAdditions`), Cancel and Discard never drop them unasked.
///
/// The record is never deleted while another card, in any window, shows it:
/// one the user opened in its place, or a multi-selection that includes
/// it, keeps it (`isShownElsewhere`, asked again right before the delete).
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
        /// Created and never ended with Done.
        case unsaved
        /// A save or the user's Delete Contact is running.
        case writing
        /// Saved with Done, or Done with nothing to save.
        case kept
        /// The card is gone and the delete was decided (or the user deleted
        /// the record).
        case finished
    }

    private static let log = GuessWhoLog.logger("app.new-contact")

    private let isStillBlank: () async -> Bool
    private let deleteRecord: () -> Void
    private var phase = Phase.unsaved
    /// The user chose Cancel or Discard Changes: delete without the blank
    /// check.
    private var discarded = false
    /// The user added a photo or a dated note on the card.
    private var addedUserData = false
    /// The card's new-note draft has text right now. Live, unlike
    /// `addedUserData`: clearing the draft clears it.
    private var noteDraftHasText = false
    /// The card went away while a write ran, so the write's outcome decides.
    private var cardEnded = false
    /// The decision `cardDidEnd` started, for `settled()`.
    private var decision: Task<Void, Never>?

    /// Closes the card after Cancel; set by the shell that shows it. Must
    /// not hold the card's view controller strongly: the controller holds
    /// this cleanup (`watch(_:)`), so a strong capture would keep both alive
    /// and the delete would never run.
    var close: () -> Void = {}
    /// Whether a card other than this one shows the record; set by the shell.
    /// Asked when the card is gone, so only other cards are left to answer.
    var isShownElsewhere: () -> Bool = { false }
    /// Runs once when the record becomes a normal one (Done); set by the shell.
    var didKeep: () -> Void = {}

    /// - Parameters:
    ///   - isStillBlank: whether the record is still exactly as "+" made it;
    ///     asked only for an end with no question asked.
    ///   - deleteRecord: starts the record's delete; called at most once,
    ///     and must not wait for the delete to finish.
    init(isStillBlank: @escaping () async -> Bool, deleteRecord: @escaping () -> Void) {
        self.isStillBlank = isStillBlank
        self.deleteRecord = deleteRecord
    }

    /// A cleanup for the record `id`, which `ContactsRepository.createContact`
    /// just made in `repository`.
    convenience init(id: ContactID, repository: ContactsRepository) {
        self.init(
            isStillBlank: { await Self.recordIsStillBlank(id, in: repository) },
            deleteRecord: { Task { await Self.delete(id, from: repository) } }
        )
    }

    /// The cleanup watching `card`, when `card` is a "+" card.
    static func watching(_ card: UIViewController) -> NewContactCleanup? {
        (objc_getAssociatedObject(card, &cardLifetimeKey) as? CardLifetime)?.cleanup
    }

    /// The user added something that leaving would delete: the card asks
    /// "Discard changes?" before it lets them go, as for typed changes.
    var hasUnsavedAdditions: Bool {
        phase == .unsaved && !discarded && (addedUserData || noteDraftHasText)
    }

    /// The user chose Cancel or Discard Changes and hasn't saved or kept the
    /// record since — whether the card is still there or already gone. The
    /// card then skips committing a half-typed note as it goes, and the next
    /// "+" takes such a card off the column first.
    var isDiscarded: Bool {
        discarded && phase != .kept
    }

    /// Cancel in the card: close it; the record goes with it. Does nothing
    /// once the record has been kept.
    func cancel() {
        guard phase == .unsaved else { return }
        discarded = true
        Self.log.notice("cancel: the never-saved new record goes with its card")
        close()
    }

    /// The Mac's Discard Changes before another selection replaces the card:
    /// the record goes with the card, which the navigation replaces.
    func discard() {
        guard phase == .unsaved else { return }
        discarded = true
        Self.log.notice("discard: the never-saved new record goes with its card")
    }

    /// Done with nothing to save: keep the record as it is.
    func keep() {
        guard phase == .unsaved else { return }
        becomeKept()
    }

    /// The user added a dated note, or a photo write is starting. Such a
    /// record is no longer blank: the card asks before discarding it, and an
    /// end with no question keeps it.
    func recordDidGetUserData() {
        guard phase == .unsaved || phase == .writing else { return }
        addedUserData = true
    }

    /// The card's new-note draft gained or lost its text. While it has text,
    /// the card asks before discarding, and an end with no question keeps
    /// the record for the draft that the card commits as it goes.
    func noteDraftDidChange(hasText: Bool) {
        noteDraftHasText = hasText
    }

    /// A save or Delete Contact started. Until it ends, nothing deletes. The
    /// user is editing again, so an earlier Discard no longer counts.
    func writeDidBegin() {
        guard phase == .unsaved else { return }
        phase = .writing
        discarded = false
    }

    /// The save `writeDidBegin` announced ended. A saved record is kept; a
    /// failed save leaves the record unsaved.
    func saveDidEnd(succeeded: Bool) {
        guard phase == .writing else { return }
        if succeeded {
            becomeKept()
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

    /// The card went away. An unsaved record is decided now; one with a
    /// write running is decided when the write ends.
    func cardDidEnd() {
        switch phase {
        case .unsaved:
            decide()
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

    /// Waits for the decision `cardDidEnd` started, if any.
    func settled() async {
        await decision?.value
    }

    private func becomeKept() {
        phase = .kept
        Self.log.notice("new record kept")
        didKeep()
    }

    private func writeDidFail() {
        phase = .unsaved
        if cardEnded {
            decide()
        }
    }

    /// The single delete decision. It runs on a later turn: the card can go
    /// away in the middle of a column swap, before the scene has stamped the
    /// card that replaces it with the records it shows.
    private func decide() {
        phase = .finished
        decision = Task { [self] in
            if isShownElsewhere() {
                Self.log.notice("new record kept: another card shows it")
            } else if discarded {
                Self.log.notice("deleting the never-saved new record", ["reason": "discarded"])
                deleteRecord()
            } else if addedUserData || noteDraftHasText {
                Self.log.notice("new record kept: the user added to it")
            } else if await isStillBlank() {
                // The check reads for a while; a card can open the record in
                // the meantime (arrow keys through the list, a click back).
                if isShownElsewhere() {
                    Self.log.notice("new record kept: another card opened it")
                } else {
                    Self.log.notice("deleting the never-saved new record", ["reason": "card closed"])
                    deleteRecord()
                }
            } else {
                Self.log.notice("new record kept: not blank, already gone, or not readable")
            }
        }
    }

    /// Whether the record still holds nothing anyone put there, anywhere
    /// (`ContactsRepository.isBlankAndUntouched`, which reads it all fresh).
    /// Unsure is not blank: a read that fails keeps the record.
    private static func recordIsStillBlank(_ id: ContactID, in repository: ContactsRepository) async -> Bool {
        do {
            return try await repository.isBlankAndUntouched(id)
        } catch {
            log.error("couldn't tell whether the new record is still blank — keeping it", [
                "error": error.localizedDescription
            ])
            return false
        }
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
    let cleanup: NewContactCleanup

    init(_ cleanup: NewContactCleanup) {
        self.cleanup = cleanup
    }

    isolated deinit {
        cleanup.cardDidEnd()
    }
}
