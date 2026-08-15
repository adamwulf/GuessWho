import ArgumentParser
import Foundation
import GuessWhoMCPWire

/// The single place that knows which CLI tool commands exist, so the parity
/// guard (§3.4) is one loop over `MCPTool.allCases` against this list — a new
/// tool without a command, or a command whose path drifts from the §2
/// derivation rule, fails the guard.
///
/// `run` and `probe` are non-tool commands (they have no `MCPTool`), so they
/// are structurally exempt: they don't conform to `CLIToolCommand` and never
/// appear in `toolCommands`.
public enum CLICommandRegistry {
    /// The root of the command tree — the parity/vocabulary tests walk from
    /// here, and the app-target shim dispatches to it.
    public static let rootCommand: ParsableCommand.Type = GuessWhoCLIRoot.self

    /// Every registered tool command. Grows one entry per command as the later
    /// phases land; Phase 1 shipped the three Phase 0/1 commands, Phase 2 adds
    /// the 20 remaining reads.
    public static let toolCommands: [any CLIToolCommand.Type] = [
        // Phase 0/1 (shipped).
        ContactsSearch.self,
        ContactsGetPhoto.self,
        ContactsSetPhoto.self,
        // Phase 2 reads — contacts.
        ContactsList.self,
        ContactsGet.self,
        ContactsListNotes.self,
        ContactsListCustomFields.self,
        ContactsListGroups.self,
        // Phase 2 reads — organizations.
        OrganizationsListMembers.self,
        OrganizationsListDepartments.self,
        OrganizationsListDepartmentMembers.self,
        // Phase 2 reads — groups.
        GroupsListForContact.self,
        // Phase 2 reads — events.
        EventsList.self,
        EventsGet.self,
        EventsListTags.self,
        // Phase 2 reads — guides.
        GuidesList.self,
        GuidesGet.self,
        GuidesListForPlace.self,
        // Phase 2 reads — places.
        PlacesList.self,
        PlacesSearch.self,
        PlacesGet.self,
        // Phase 2 reads — links.
        LinksList.self,
        // Phase 2 reads — favorites.
        FavoritesList.self,
        // Phase 3 writes — contacts notes.
        ContactsAddNote.self,
        ContactsEditNote.self,
        ContactsDeleteNote.self,
        // Phase 3 writes — contacts custom fields.
        ContactsSetCustomField.self,
        ContactsDeleteCustomField.self,
        // Phase 3 writes — contacts favorite.
        ContactsSetFavorite.self,
        // Phase 3 writes — favorites.
        FavoritesSet.self,
        FavoritesReorder.self,
        // Phase 3 writes — event tags.
        EventsAddTag.self,
        EventsEditTag.self,
        EventsDeleteTag.self,
        // Phase 3 writes — guides.
        GuidesCreate.self,
        GuidesDelete.self,
        GuidesReorderPlaces.self,
        // Phase 3 writes — places.
        PlacesDelete.self,
        // Phase 3 writes — links.
        LinksCreate.self,
        LinksDelete.self,
        // Phase 4 writes — contacts card.
        ContactsCreate.self,
        ContactsUpdate.self,
        ContactsDeletePhoto.self,
        // Phase 4 writes — contacts value edits.
        ContactsAddValue.self,
        ContactsDeleteValue.self,
        ContactsEditValue.self,
    ]

    /// The tool commands keyed by the `MCPTool` each one sends. A duplicate
    /// key (two commands claiming one tool) collapses here and is caught by
    /// the parity guard's count assertion.
    public static var commandsByTool: [MCPTool: any CLIToolCommand.Type] {
        var result: [MCPTool: any CLIToolCommand.Type] = [:]
        for command in toolCommands {
            result[command.tool] = command
        }
        return result
    }

    /// The §2 derivation rule as code: the tool name's text before the first
    /// underscore is the noun group; the rest becomes the hyphenated verb.
    /// `contacts_get_photo` → `contacts get-photo`.
    public static func derivedPath(for tool: MCPTool) -> String {
        let raw = tool.rawValue
        guard let underscore = raw.firstIndex(of: "_") else { return raw }
        let noun = String(raw[..<underscore])
        let verb = raw[raw.index(after: underscore)...].replacingOccurrences(of: "_", with: "-")
        return "\(noun) \(verb)"
    }

    /// The ACTUAL path a command occupies in the tree (e.g. "contacts search"),
    /// discovered by walking the root's subcommand structure — so the parity
    /// guard compares the real registration against the derived rule rather
    /// than trusting a hand-written string. `nil` if the type isn't reachable
    /// from the root.
    public static func actualPath(for commandType: ParsableCommand.Type) -> String? {
        discoveredPaths()[ObjectIdentifier(commandType)]
    }

    /// Every command type reachable from the root (excluding the root itself),
    /// for the vocabulary scan over their help text.
    public static var allSubcommandTypes: [ParsableCommand.Type] {
        var result: [ParsableCommand.Type] = []
        walk(rootCommand, prefix: []) { type, _ in result.append(type) }
        return result
    }

    // MARK: - Tree walk

    private static func discoveredPaths() -> [ObjectIdentifier: String] {
        var result: [ObjectIdentifier: String] = [:]
        walk(rootCommand, prefix: []) { type, path in
            result[ObjectIdentifier(type)] = path.joined(separator: " ")
        }
        return result
    }

    /// Depth-first walk of the subcommand tree. `visit` is called for every
    /// command BELOW the root with its full path (the root's own name is not
    /// part of any path — paths read "contacts search", not
    /// "guesswho-cli contacts search").
    private static func walk(
        _ type: ParsableCommand.Type,
        prefix: [String],
        visit: (ParsableCommand.Type, [String]) -> Void
    ) {
        for sub in type.configuration.subcommands {
            let name = sub.configuration.commandName ?? String(describing: sub).lowercased()
            let path = prefix + [name]
            visit(sub, path)
            walk(sub, prefix: path, visit: visit)
        }
    }
}
