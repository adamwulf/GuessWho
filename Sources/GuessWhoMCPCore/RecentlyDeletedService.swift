import Foundation
import GuessWhoSync
import GuessWhoMCPWire

/// One row in the app's Recently Deleted screen: an agent-deleted item that
/// still exists as a recoverable record.
public struct RecentlyDeletedItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case note
        case customField
        case eventTag
        case linkedContact
    }

    /// Stable per-row id (the deleted instance's UUID string).
    public let id: String
    public let kind: Kind
    /// Plain row title, from the `RecentlyDeletedStrings` templates
    /// ("Note about Jane Doe").
    public let title: String
    /// What was deleted (the note body, field value, tag text, link note).
    public let detail: String
    public let deletedAt: Date
    /// Whether restore is safe: false when the live record's `modifiedAt`
    /// no longer matches the audited post-delete stamp — something else (a
    /// human, another device) touched it since, and a blind restore would
    /// LWW-clobber that newer state.
    public let canRestore: Bool

    let entry: MCPAuditEntry
}

/// Backs the app's user-reachable "Recently Deleted" screen — the v1
/// prerequisite for enabling agent writes (plans/cli-mcp.md Phase 2):
/// soft-delete only makes agent deletes safe FOR THE USER once the user can
/// see and undo them without knowing they happened.
///
/// Rows come from the device-local audit log's delete entries, resolved
/// against the live engine state through the same injected sources the
/// dispatcher uses. Restores route through the SAME app write paths
/// (INV-2), all of which un-delete a tombstoned cell on write.
@MainActor
public final class RecentlyDeletedService {
    private let audit: MCPAuditLog
    private let contacts: MCPContactSource
    private let events: MCPEventSource

    /// Sub-second slack for the restore guard: the audited stamp round-trips
    /// through JSON as an epoch double, so exact bit equality with the live
    /// `Date` is not guaranteed even when nothing changed.
    private static let modifiedAtTolerance: TimeInterval = 0.001

    public init(audit: MCPAuditLog, contacts: MCPContactSource, events: MCPEventSource) {
        self.audit = audit
        self.contacts = contacts
        self.events = events
    }

    /// The recoverable agent-deleted items, newest deletion first. Entries
    /// whose record was since restored (by anyone) or hard-removed drop out.
    public func items(limit: Int = 50) async -> [RecentlyDeletedItem] {
        let deletions = await audit.entries()
            .filter { entry in
                switch entry.action {
                case .deleteNote, .deleteCustomField, .deleteTag, .removeLinkedContact:
                    return true
                default:
                    return false
                }
            }
            .sorted { $0.at > $1.at }

        var items: [RecentlyDeletedItem] = []
        var seenInstances: Set<String> = []
        for entry in deletions {
            guard items.count < limit else { break }
            guard let instanceID = entry.instanceID, !seenInstances.contains(instanceID) else { continue }
            seenInstances.insert(instanceID)
            if let item = resolve(entry) {
                items.append(item)
            }
        }
        return items
    }

    /// Restore one item through the live write paths. Returns false when
    /// the guard blocks the restore (the record changed since the delete)
    /// or the underlying write fails — the UI shows the plain
    /// `RecentlyDeletedStrings` copy for either.
    public func restore(_ item: RecentlyDeletedItem) async -> Bool {
        guard item.canRestore, let instanceID = item.entry.instanceID,
              let instanceUUID = UUID(uuidString: instanceID)
        else { return false }
        switch item.entry.action {
        case .deleteNote:
            guard let contact = contact(guessWhoID: item.entry.subjectID),
                  let tombstone = contacts.allNotes(for: contact.contactID)
                    .first(where: { $0.id == instanceUUID })
            else { return false }
            // editNote un-deletes the cell; re-writing the tombstone's own
            // preserved body restores it verbatim.
            do {
                try await contacts.editNote(
                    for: contact.contactID, id: instanceUUID,
                    newBody: tombstone.body, createdAt: nil)
                return true
            } catch {
                return false
            }
        case .deleteCustomField:
            guard let contact = contact(guessWhoID: item.entry.subjectID),
                  let tombstone = contacts.allFields(for: contact.contactID)
                    .first(where: { $0.id == instanceUUID })
            else { return false }
            do {
                // Re-write the tombstone's own preserved value: type-aware
                // by construction (checkbox bools included — the engine
                // validates the payload against the cell's immutable type),
                // and the field write un-deletes the cell.
                try await contacts.editField(
                    for: contact.contactID, id: instanceUUID, value: tombstone.value)
                return true
            } catch {
                return false
            }
        case .deleteTag:
            guard let tombstone = events.allEventTagFields(forEventUUID: item.entry.subjectID)
                    .first(where: { $0.id == instanceUUID }),
                  case .string(let text) = tombstone.value
            else { return false }
            do {
                try events.editEventTag(id: instanceUUID, text: text, forEventUUID: item.entry.subjectID)
                return true
            } catch {
                return false
            }
        case .removeLinkedContact:
            guard let tombstone = contacts.link(id: instanceUUID) else { return false }
            do {
                // setLinkNote un-deletes; re-writing the preserved note
                // restores the row verbatim.
                try contacts.setLinkNote(id: instanceUUID, note: tombstone.note)
                return true
            } catch {
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Resolution

    private func resolve(_ entry: MCPAuditEntry) -> RecentlyDeletedItem? {
        guard let instanceID = entry.instanceID,
              let instanceUUID = UUID(uuidString: instanceID)
        else { return nil }

        switch entry.action {
        case .deleteNote:
            guard let contact = contact(guessWhoID: entry.subjectID),
                  let note = contacts.allNotes(for: contact.contactID)
                    .first(where: { $0.id == instanceUUID }),
                  note.deletedAt != nil
            else { return nil }
            return RecentlyDeletedItem(
                id: instanceID, kind: .note,
                title: String(format: RecentlyDeletedStrings.noteRowTitle, subjectName(entry)),
                detail: note.body,
                deletedAt: entry.at,
                canRestore: Self.matches(note.modifiedAt, entry.postModifiedAt),
                entry: entry)
        case .deleteCustomField:
            guard let contact = contact(guessWhoID: entry.subjectID),
                  let field = contacts.allFields(for: contact.contactID)
                    .first(where: { $0.id == instanceUUID }),
                  field.deletedAt != nil
            else { return nil }
            return RecentlyDeletedItem(
                id: instanceID, kind: .customField,
                title: String(format: RecentlyDeletedStrings.fieldRowTitle, subjectName(entry)),
                detail: field.field + (entry.priorValue.map { ": \($0)" } ?? ""),
                deletedAt: entry.at,
                canRestore: Self.matches(field.modifiedAt, entry.postModifiedAt),
                entry: entry)
        case .deleteTag:
            guard let cell = events.allEventTagFields(forEventUUID: entry.subjectID)
                    .first(where: { $0.id == instanceUUID }),
                  cell.deletedAt != nil
            else { return nil }
            return RecentlyDeletedItem(
                id: instanceID, kind: .eventTag,
                title: String(format: RecentlyDeletedStrings.tagRowTitle, subjectName(entry)),
                detail: entry.priorValue ?? "",
                deletedAt: entry.at,
                canRestore: Self.matches(cell.modifiedAt, entry.postModifiedAt),
                entry: entry)
        case .removeLinkedContact:
            guard let link = contacts.link(id: instanceUUID), link.deletedAt != nil else { return nil }
            return RecentlyDeletedItem(
                id: instanceID, kind: .linkedContact,
                title: String(format: RecentlyDeletedStrings.linkRowTitle, subjectName(entry)),
                detail: link.note,
                deletedAt: entry.at,
                canRestore: Self.matches(link.modifiedAt, entry.postModifiedAt),
                entry: entry)
        default:
            return nil
        }
    }

    private func subjectName(_ entry: MCPAuditEntry) -> String {
        entry.subjectName.isEmpty ? RecentlyDeletedStrings.unknownSubject : entry.subjectName
    }

    private func contact(guessWhoID: String) -> Contact? {
        guard !guessWhoID.isEmpty else { return nil }
        return contacts.allContacts.first {
            $0.contactID.restorationToken.guessWhoID == guessWhoID
        }
    }

    /// The restore guard: the live cell's `modifiedAt` must (within
    /// tolerance) equal the audited post-delete stamp. `modifiedBy` cannot
    /// distinguish an agent write from a human one (same device UUID), so
    /// this timestamp comparison is the only "did anything touch it since"
    /// signal.
    static func matches(_ current: Date, _ audited: Date?) -> Bool {
        guard let audited else { return false }
        return abs(current.timeIntervalSince(audited)) <= modifiedAtTolerance
    }
}
