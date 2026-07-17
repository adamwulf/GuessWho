import Foundation

/// The typed error taxonomy for the CLI/MCP wire (plans/cli-mcp.md Phase 1).
///
/// Case names are INTERNAL wire codes: they ride the relay↔app envelope so
/// tests and logs can discriminate, but the agent-facing rendering is ONLY
/// the plain `message` string. Never interpolate a model value (`Contact`,
/// `Event`, …) into a wire message — a serialized model in an error would
/// leak fields the DTO allowlist exists to withhold (INV-3/INV-3b).
public enum WireErrorCode: String, Codable, Sendable, CaseIterable {
    case notRunning
    case disabled
    case permissionDenied
    case readOnly
    case tooLarge
    case notFound
    case staleHandle
    case invalidParams
    /// Rate-limit rejection (search / global budgets). Additive to the
    /// plan's taxonomy: the rate limit needs an honest code of its own —
    /// mislabeling it `invalidParams` would tell the agent to change its
    /// arguments, which is not the fix.
    case busy
}

/// Standard agent-actionable messages, verbatim from the plan's drafts.
/// Each tells the agent what to DO, never which mechanism failed. All of
/// these are covered by the banned-vocabulary test.
public enum WireErrorMessage {
    public static let notRunning =
        "GuessWho isn't open. Ask the user to open the GuessWho app, then try again."
    public static let disabled =
        "That capability is turned off in GuessWho's settings."
    public static let permissionDeniedContacts =
        "GuessWho doesn't have access to Contacts yet. Ask the user to grant Contacts access in System Settings, then try again."
    public static let permissionDeniedEvents =
        "GuessWho doesn't have access to the user's calendars yet. Ask the user to grant calendar access in System Settings, then try again."
    public static let readOnly =
        "Editing is turned off. The user can enable it in GuessWho's settings."
    public static let tooLarge =
        "That result is too large — narrow the search or lower the limit."
    public static let staleReference =
        "That contact reference is out of date. Search again to get a current one, then retry."
    public static let staleReferenceGeneric =
        "That id is out of date. Run the matching list tool again to get a current one, then retry."
    public static let busy =
        "Too many requests at once. Wait a moment and try again."
    public static let notFoundContact = "No matching contact was found."
    public static let notFoundEvent = "No matching event was found."
    public static let notFoundGroup = "No matching group was found."
    public static let notFoundGuide = "No matching guide was found."
    /// Shown in place of a tool list when the app isn't reachable. Worded as
    /// a pass-through instruction so the agent relays "open the app," not
    /// "there are no tools."
    public static let noHostStatus =
        "GuessWho isn't open, so its tools are unavailable right now. Ask the user to open the GuessWho app, then list tools again."
    /// The app is running but the session handshake didn't complete — a
    /// distinct, diagnosable state from "not running".
    public static let hostNotReady =
        "GuessWho is open but couldn't get ready. Wait a moment and try again."
    public static let timedOut =
        "GuessWho didn't answer in time. Try again in a moment."

    /// Every fixed string above, for the banned-vocabulary test.
    public static var allFixedStrings: [String] {
        [
            notRunning, disabled, permissionDeniedContacts, permissionDeniedEvents,
            readOnly, tooLarge, staleReference, staleReferenceGeneric, busy,
            notFoundContact, notFoundEvent, notFoundGroup, notFoundGuide, noHostStatus,
            hostNotReady, timedOut,
        ]
    }
}

/// User-facing copy for the settings toggles (rendered by the app's
/// Preferences in Phase 3; defined here so the banned-vocabulary test
/// covers them from day one). Plain language only — the user thinks in
/// assistants, contacts, and events, never in transport mechanics.
public enum PreferencesStrings {
    public static let mcpToggleTitle = "AI assistant access"
    public static let mcpToggleFooter =
        "Let AI assistants you connect (like Claude) look up your contacts, events, and guides while GuessWho is open."
    public static let cliToggleTitle = "Terminal access"
    public static let cliToggleFooter =
        "Let terminal commands look up your contacts, events, and guides while GuessWho is open."
    public static let mcpReadOnlyTitle = "Read-only for AI assistants"
    public static let cliReadOnlyTitle = "Read-only for terminal commands"
    public static let readOnlyFooter =
        "When read-only is on, lookups work but nothing can be added, changed, or deleted."

    public static var allFixedStrings: [String] {
        [
            mcpToggleTitle, mcpToggleFooter, cliToggleTitle, cliToggleFooter,
            mcpReadOnlyTitle, cliReadOnlyTitle, readOnlyFooter,
        ]
    }
}
