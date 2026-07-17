import Foundation
import GuessWhoMCPWire

/// One row of the Preferences "Agent activity" section, ready to render:
/// a plain title from the `AgentActivityStrings` templates ("Added a note
/// to Jane Doe"), a value snippet, and the entry's timestamp (the view
/// formats it — "3:14 PM").
public struct AgentActivityRow: Identifiable, Sendable, Equatable {
    /// Stable per-row id (position in the log + timestamp — audit entries
    /// have no id of their own and the log is append-only).
    public let id: String
    public let title: String
    /// The written / removed value, when the action has one ("" otherwise).
    public let detail: String
    public let at: Date
}

/// Pure mapping from audit entries to display rows, so the rendering rules
/// (template per action, favorite set/clear split, display-name fallback)
/// are unit-testable under plain `swift test`. The view supplies no copy of
/// its own — every string comes from `AgentActivityStrings`, which the
/// banned-vocabulary test scans.
public enum AgentActivityFormatter {

    /// Newest first, capped at `limit`.
    public static func rows(from entries: [MCPAuditEntry], limit: Int = 50) -> [AgentActivityRow] {
        entries.enumerated()
            .sorted { $0.element.at > $1.element.at }
            .prefix(limit)
            .map { index, entry in
                AgentActivityRow(
                    id: "\(index)-\(entry.at.timeIntervalSince1970)",
                    title: title(for: entry),
                    detail: detail(for: entry),
                    at: entry.at)
            }
    }

    static func title(for entry: MCPAuditEntry) -> String {
        let name = entry.subjectName.isEmpty
            ? AgentActivityStrings.unknownSubject
            : entry.subjectName
        return String(format: template(for: entry), name)
    }

    private static func template(for entry: MCPAuditEntry) -> String {
        switch entry.action {
        case .addNote: return AgentActivityStrings.addedNote
        case .editNote: return AgentActivityStrings.editedNote
        case .deleteNote: return AgentActivityStrings.deletedNote
        case .setCustomField: return AgentActivityStrings.setCustomField
        case .deleteCustomField: return AgentActivityStrings.deletedCustomField
        case .addLinkedContact: return AgentActivityStrings.addedConnection
        case .removeLinkedContact: return AgentActivityStrings.removedConnection
        case .setFavorite:
            // The dispatcher records the flip's direction as "true"/"false".
            return entry.newValue == "false"
                ? AgentActivityStrings.clearedFavorite
                : AgentActivityStrings.markedFavorite
        case .addTag: return AgentActivityStrings.addedTag
        case .editTag: return AgentActivityStrings.editedTag
        case .deleteTag: return AgentActivityStrings.deletedTag
        case .createGuide: return AgentActivityStrings.createdGuide
        case .deleteGuide: return AgentActivityStrings.deletedGuide
        case .reorderPlaces: return AgentActivityStrings.reorderedPlaces
        case .deletePlace: return AgentActivityStrings.deletedPlace
        }
    }

    static func detail(for entry: MCPAuditEntry) -> String {
        switch entry.action {
        case .setFavorite, .reorderPlaces:
            // The title already says everything; "true" / a raw order list
            // would read as debug output.
            return ""
        default:
            return entry.newValue ?? entry.priorValue ?? ""
        }
    }
}
