import Foundation
import GuessWhoSync

/// Thin app-side view model that exposes a contact's notes as a SwiftUI-
/// observable property and routes mutations through the package's
/// `ContactsRepository`, keyed on the opaque `ContactID`. The authoritative
/// store lives in the package: each note is its own sidecar field-instance
/// cell with `type == .note` and `field == "note"`. We just reload the
/// package's typed list after every mutation so the UI sees the canonical
/// sort order (createdAt ASC) and tombstone filtering.
///
/// Writes are `async`: the repository resolves-or-mints the contact's
/// GuessWho UUID first (the first note on a never-touched contact reconciles
/// + mints, transparent to us), then writes the note. Reads stay synchronous —
/// an unreconciled contact has no sidecar yet, so `repository.notes(for:)`
/// returns empty until a write mints the UUID.
@MainActor
@Observable
final class NotesStore {
    private let repository: ContactsRepository
    /// The opaque identity the notes are keyed on. Carries the contact's current
    /// `guessWhoID`, which the repository reads notes off. It can MINT on the
    /// first write to an unreconciled contact: the write resolves-or-mints a
    /// UUID internally, but our captured `id` still has a nil `guessWhoID`, so we
    /// `reresolve()` it post-write to pick up the minted UUID — otherwise the
    /// reload would read off the stale nil-UUID id and miss the just-written note.
    private(set) var id: ContactID

    private(set) var notes: [ContactNote] = []

    init(repository: ContactsRepository, id: ContactID) {
        self.repository = repository
        self.id = id
        reload()
    }

    func reload() {
        notes = repository.notes(for: id)
    }

    /// Re-derive `id` after a write that may have minted the GuessWho UUID.
    /// `contact(id:)` is reconcile-stable (resolves via the captured id's
    /// always-present `localID` even when its `guessWhoID` is still nil), so this
    /// picks up the just-minted UUID. Harmless when nothing minted — it re-derives
    /// the same id. Keeps the old id when the contact is gone (deleted).
    private func reresolve() {
        guard let contact = repository.contact(id: id) else { return }
        id = contact.contactID
    }

    /// `date` is the note's user-visible date; nil means "now" (stamped at
    /// write time by the repository default).
    func addNote(body: String, date: Date? = nil) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await repository.addNote(for: id, body: body, createdAt: date ?? Date())
        } catch {
            // Sidecar storage unavailable or write failed — leave the UI
            // state untouched; reload below will show what's on disk.
        }
        reresolve()
        reload()
    }

    /// A non-nil `date` re-stamps the note's user-visible date; nil keeps it.
    func editNote(_ noteID: UUID, newBody: String, date: Date? = nil) async {
        do {
            try await repository.editNote(for: id, id: noteID, newBody: newBody, createdAt: date)
        } catch {
            // ignore — reload reflects the truth
        }
        reresolve()
        reload()
    }

    func deleteNote(_ noteID: UUID) async {
        do {
            try await repository.deleteNote(for: id, id: noteID)
        } catch {
            // ignore — reload reflects the truth
        }
        reresolve()
        reload()
    }
}
