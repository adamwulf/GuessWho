import Foundation
import GuessWhoMCPWire
import XCTest
@testable import GuessWhoCLICore

/// The parity guard (§3.4): every `MCPTool` case has a CLI command whose path
/// matches the §2 derivation rule, and every registered command names a real
/// tool. `pending` is the EXPLICIT set of not-yet-implemented tools — it landed
/// in Phase 1 with 60 entries, shrank to 40 when Phase 2's 20 reads landed,
/// shrinks by Phase 3's 17 GuessWho-data writes, and must reach empty by Phase 5,
/// so the guard both exerts pressure during the build-out AND catches future
/// drift.
///
/// TODO (Phase 4): add the field-level schema-parity check from §3.4 — every
/// non-object schema property of a tool reachable as a positional/flag, every
/// scalar flag naming a real property. Deferred because the structured/per-field
/// flags land in Phase 4.
final class ParityGuardTests: XCTestCase {

    /// The tools without a CLI command yet — everything except the three shipped
    /// Phase 0/1 commands, the 20 Phase 2 reads, and the 17 Phase 3 GuessWho-data
    /// writes. What remains is the Phase 4 Contact Store writes and the Phase 5
    /// confirmation-gated delete; `expectedPendingCount` pins the current size.
    static let pending: Set<MCPTool> = [
        // Contact Store writes (Phase 4) — create/update/delete-photo, value
        // edits, structured entries.
        .contactsCreate, .contactsUpdate, .contactsDeletePhoto,
        .contactsAddValue, .contactsDeleteValue, .contactsEditValue,
        .contactsAddPostalAddress, .contactsEditPostalAddress, .contactsDeletePostalAddress,
        .contactsAddSocialProfile, .contactsEditSocialProfile, .contactsDeleteSocialProfile,
        .contactsAddInstantMessage, .contactsEditInstantMessage, .contactsDeleteInstantMessage,
        .organizationsRenameDepartment,
        .groupsCreate, .groupsRename, .groupsDelete, .groupsAddMembers, .groupsRemoveMembers,
        .groupsSetFavorite,
        // Confirmation-gated delete (Phase 5).
        .contactsDelete,
    ]

    /// The current expected size of `pending`. Phase 3 leaves 23 tools pending:
    /// 22 Phase 4 Contact Store writes + the Phase 5 confirmation-gated delete.
    static let expectedPendingCount = 23

    func testPendingHasExpectedCount() {
        XCTAssertEqual(Self.pending.count, Self.expectedPendingCount)
    }

    /// tool → command: every non-pending tool has a registered command whose
    /// ACTUAL path in the tree equals the §2-derived path.
    func testEveryNonPendingToolHasACommandAtTheDerivedPath() {
        let registered = CLICommandRegistry.commandsByTool
        for tool in MCPTool.allCases where !Self.pending.contains(tool) {
            guard let command = registered[tool] else {
                XCTFail("\(tool.rawValue) has no CLI command")
                continue
            }
            let actual = CLICommandRegistry.actualPath(for: command)
            XCTAssertEqual(
                actual, CLICommandRegistry.derivedPath(for: tool),
                "\(tool.rawValue) command path drifted from the derivation rule")
        }
    }

    /// command → tool: the registered count equals all tools minus pending, so
    /// no tool is both pending and registered, and none is forgotten by both.
    func testRegisteredCountMatchesToolsMinusPending() {
        let registered = CLICommandRegistry.commandsByTool
        XCTAssertEqual(registered.count, MCPTool.allCases.count - Self.pending.count)
    }

    /// pending and registered are disjoint (no tool claimed twice, none in both
    /// buckets).
    func testPendingAndRegisteredAreDisjointAndComplete() {
        let registered = Set(CLICommandRegistry.commandsByTool.keys)
        XCTAssertTrue(registered.isDisjoint(with: Self.pending))
        XCTAssertEqual(registered.union(Self.pending), Set(MCPTool.allCases))
    }

    /// The derivation rule itself, on representative names (locks the rule
    /// before the commands that use it exist).
    func testDerivationRuleExamples() {
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .contactsSearch), "contacts search")
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .contactsGetPhoto), "contacts get-photo")
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .contactsSetPhoto), "contacts set-photo")
        XCTAssertEqual(
            CLICommandRegistry.derivedPath(for: .contactsListCustomFields),
            "contacts list-custom-fields")
        XCTAssertEqual(
            CLICommandRegistry.derivedPath(for: .organizationsListDepartmentMembers),
            "organizations list-department-members")
    }

    /// Every registered command's `tool` round-trips through the derived path
    /// (guards a command declaring a `tool` its name doesn't match).
    func testRegisteredCommandsSitAtTheirToolsDerivedPath() {
        for command in CLICommandRegistry.toolCommands {
            let actual = CLICommandRegistry.actualPath(for: command)
            XCTAssertEqual(actual, CLICommandRegistry.derivedPath(for: command.tool))
        }
    }
}
