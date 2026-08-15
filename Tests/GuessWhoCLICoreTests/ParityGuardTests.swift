import Foundation
import GuessWhoMCPWire
import XCTest
@testable import GuessWhoCLICore

/// The parity guard (§3.4): every `MCPTool` case has a CLI command whose path
/// matches the §2 derivation rule, and every registered command names a real
/// tool. `pending` is the EXPLICIT set of not-yet-implemented tools — it landed
/// in Phase 1 with 60 entries, shrank to 40 when Phase 2's 20 reads landed, and
/// must shrink to empty by Phase 5, so the guard both exerts pressure during the
/// build-out AND catches future drift.
///
/// TODO (Phase 4): add the field-level schema-parity check from §3.4 — every
/// non-object schema property of a tool reachable as a positional/flag, every
/// scalar flag naming a real property. Deferred because the structured/per-field
/// flags land in Phase 4.
final class ParityGuardTests: XCTestCase {

    /// The 40 tools without a CLI command yet (everything except the three
    /// shipped Phase 0/1 commands and the 20 Phase 2 reads). Shrinks one phase
    /// at a time.
    static let pending: Set<MCPTool> = [
        // Writes (40)
        .contactsCreate, .contactsUpdate, .contactsDelete, .contactsDeletePhoto,
        .contactsAddValue, .contactsDeleteValue, .contactsEditValue,
        .contactsAddPostalAddress, .contactsEditPostalAddress, .contactsDeletePostalAddress,
        .contactsAddSocialProfile, .contactsEditSocialProfile, .contactsDeleteSocialProfile,
        .contactsAddInstantMessage, .contactsEditInstantMessage, .contactsDeleteInstantMessage,
        .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
        .contactsSetCustomField, .contactsDeleteCustomField, .contactsSetFavorite,
        .favoritesSet, .favoritesReorder, .organizationsRenameDepartment,
        .groupsCreate, .groupsRename, .groupsDelete, .groupsAddMembers, .groupsRemoveMembers,
        .groupsSetFavorite, .eventsAddTag, .eventsEditTag, .eventsDeleteTag,
        .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete,
        .linksCreate, .linksDelete,
    ]

    func testPendingHasExactlyFortyEntries() {
        XCTAssertEqual(Self.pending.count, 40)
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
