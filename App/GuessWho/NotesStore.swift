import Foundation
import GuessWhoSync

@MainActor
@Observable
final class NotesStore {
    private let service: SyncService
    let contactUUID: String

    private var allNotes: [ContactNote] = []

    init(service: SyncService, contactUUID: String) {
        self.service = service
        self.contactUUID = contactUUID
        reload()
    }

    // Live notes for the UI: tombstoned notes filtered out, deterministic
    // sort by (createdAt, id.uuidString) ascending per §12.5.
    var notes: [ContactNote] {
        allNotes
            .filter { !$0.deleted }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func reload() {
        let cell = readCell()
        allNotes = NotesCellCodec.decode(cell)
    }

    func addNote(body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Read-decode-mutate-encode-write in memory, per §12.5 concurrency
        // model. Race-loss policy: at most one dropped edit per loser.
        reload()
        let now = Date()
        let new = ContactNote(
            id: UUID(),
            createdAt: now,
            modifiedAt: now,
            modifiedBy: service.deviceID,
            body: body,
            deleted: false
        )
        allNotes.append(new)
        write()
    }

    func editNote(_ id: UUID, newBody: String) {
        reload()
        guard let idx = allNotes.firstIndex(where: { $0.id == id }) else { return }
        allNotes[idx].body = newBody
        allNotes[idx].modifiedAt = Date()
        allNotes[idx].modifiedBy = service.deviceID
        write()
    }

    func deleteNote(_ id: UUID) {
        reload()
        guard let idx = allNotes.firstIndex(where: { $0.id == id }) else { return }
        allNotes[idx].deleted = true
        allNotes[idx].body = ""
        allNotes[idx].modifiedAt = Date()
        allNotes[idx].modifiedBy = service.deviceID
        write()
    }

    private func readCell() -> SidecarCell? {
        do {
            let envelope = try service.sidecarEnvelope(forContactUUID: contactUUID)
            return envelope?.fields["notes"]
        } catch {
            return nil
        }
    }

    private func write() {
        let value = NotesCellCodec.encodeValue(allNotes)
        do {
            try service.setField("notes", value: value, forContactUUID: contactUUID)
            reload()
        } catch {
            // Optimistic in-memory state is now ahead of disk. Re-read so the
            // UI reflects the truth; the user re-issues if they still want it.
            reload()
        }
    }
}
