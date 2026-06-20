import Foundation
import GuessWhoSync

/// Thin app-side view model that exposes a contact's notes as a SwiftUI-
/// observable property and routes mutations through SyncService. The
/// authoritative store lives in the package: each note is its own sidecar
/// field-instance cell with `type == .note` and `field == "note"`. We just
/// reload the package's typed list after every mutation so the UI sees the
/// canonical sort order (createdAt ASC) and tombstone filtering.
@MainActor
@Observable
final class NotesStore {
    private let service: SyncService
    let contactUUID: String

    private(set) var notes: [ContactNote] = []

    init(service: SyncService, contactUUID: String) {
        self.service = service
        self.contactUUID = contactUUID
        reload()
    }

    func reload() {
        notes = service.notes(forContactUUID: contactUUID)
    }

    func addNote(body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try service.addNote(body: body, forContactUUID: contactUUID)
        } catch {
            // Sidecar storage unavailable or write failed — leave the UI
            // state untouched; reload below will show what's on disk.
        }
        reload()
    }

    func editNote(_ id: UUID, newBody: String) {
        do {
            try service.editNote(id: id, newBody: newBody, forContactUUID: contactUUID)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }

    func deleteNote(_ id: UUID) {
        do {
            try service.deleteNote(id: id, forContactUUID: contactUUID)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }
}
