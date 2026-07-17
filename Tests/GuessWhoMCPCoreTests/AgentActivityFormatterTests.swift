import XCTest
@testable import GuessWhoMCPCore
import GuessWhoMCPWire

/// The Preferences "Agent activity" rendering rules: template per action,
/// the favorite set/clear split on the recorded direction, display-name
/// fallback, newest-first ordering, and the value-snippet selection.
final class AgentActivityFormatterTests: XCTestCase {

    private func entry(
        at: Date = Date(timeIntervalSince1970: 1_000),
        action: MCPAuditEntry.Action,
        name: String = "Jane Doe",
        priorValue: String? = nil,
        newValue: String? = nil
    ) -> MCPAuditEntry {
        MCPAuditEntry(
            at: at, action: action, subjectKind: .contact, subjectID: "id",
            subjectName: name, instanceID: nil, postModifiedAt: nil,
            priorValue: priorValue, newValue: newValue)
    }

    func test_titles_useThePlainTemplates() {
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .addNote)),
            "Added a note to Jane Doe")
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .deleteCustomField)),
            "Deleted a custom field from Jane Doe")
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .addLinkedContact)),
            "Added a connection to Jane Doe")
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .createGuide, name: "Tokyo Trip")),
            "Created the guide Tokyo Trip")
    }

    func test_favoriteTitle_splitsOnRecordedDirection() {
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .setFavorite, newValue: "true")),
            "Marked Jane Doe as a favorite")
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .setFavorite, newValue: "false")),
            "Removed Jane Doe from favorites")
    }

    func test_title_fallsBackWhenNameSnapshotIsEmpty() {
        XCTAssertEqual(
            AgentActivityFormatter.title(for: entry(action: .deleteNote, name: "")),
            String(format: AgentActivityStrings.deletedNote, AgentActivityStrings.unknownSubject))
    }

    func test_detail_prefersNewValue_thenPriorValue() {
        XCTAssertEqual(
            AgentActivityFormatter.detail(for: entry(action: .editNote, priorValue: "old", newValue: "new")),
            "new")
        XCTAssertEqual(
            AgentActivityFormatter.detail(for: entry(action: .deleteNote, priorValue: "old")),
            "old")
    }

    func test_detail_suppressesRawFlagsAndOrderLists() {
        XCTAssertEqual(
            AgentActivityFormatter.detail(for: entry(action: .setFavorite, newValue: "true")),
            "")
        XCTAssertEqual(
            AgentActivityFormatter.detail(for: entry(action: .reorderPlaces)),
            "")
    }

    func test_rows_areNewestFirst_andCapped() {
        let entries = (0..<5).map { index in
            entry(at: Date(timeIntervalSince1970: Double(index)), action: .addNote, newValue: "note \(index)")
        }
        let rows = AgentActivityFormatter.rows(from: entries, limit: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.detail), ["note 4", "note 3", "note 2"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "row ids must be unique")
    }
}
