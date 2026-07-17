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
    /// A write named an instance (note, tag, field, row) that doesn't
    /// exist on the target record — distinct from `staleHandle` (the id
    /// itself is unknown/expired). Phase 1's read tools answer every
    /// unresolvable id with `staleHandle`; Phase 2's writes use this when
    /// the id resolves but the instance is gone.
    case notFound
    case staleHandle
    case invalidParams
    /// Rate-limit rejection (search / global budgets). Additive to the
    /// plan's taxonomy: the rate limit needs an honest code of its own —
    /// mislabeling it `invalidParams` would tell the agent to change its
    /// arguments, which is not the fix.
    case busy
    /// The write needs the user to do something in the app first (the
    /// event-tag Option B rule: a write to an event the app hasn't opened
    /// yet mints nothing and answers this — plans/cli-mcp.md Phase 2).
    /// Additive, like `busy`: `invalidParams` would misdirect the agent to
    /// change arguments, and `notFound` would misdirect it to search again.
    case requiresAppAction
    /// The engine rejected or couldn't complete a write (storage
    /// unavailable, save failure). The message carries the re-read-before-
    /// retry guidance so a timeout-then-retry doesn't duplicate the write.
    case writeFailed
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
    // The notFound* strings pair with the `notFound` code above: unused by
    // Phase 1's reads (which answer `staleHandle` uniformly), wired up by
    // Phase 2's write tools. Kept under the banned-vocabulary test from day
    // one.
    public static let notFoundContact = "No matching contact was found."
    public static let notFoundEvent = "No matching event was found."
    public static let notFoundGroup = "No matching group was found."
    public static let notFoundGuide = "No matching guide was found."
    public static let notFoundNote =
        "No matching note was found on that contact. List the notes again to get current ids."
    public static let notFoundField =
        "No matching custom field was found on that contact. List the custom fields again to get current ids."
    public static let notFoundTag =
        "No matching tag was found on that event. List the tags again to get current ids."
    public static let notFoundLink =
        "No matching connection was found. List the Linked Contacts or Linked Organizations again to get current ids."
    public static let notFoundPlace =
        "No matching place was found. List the places again to get current ids."
    // Write-path messages (plans/cli-mcp.md Phase 2).
    /// Event-tag Option B: writes never set an event up on their own — the
    /// user opens it in the app once, which does.
    public static let eventNeedsAppFirst =
        "That event can't be tagged yet. Ask the user to open the event once in the GuessWho app, then try again."
    /// Engine write failure. Carries the re-read guidance: a timed-out write
    /// may still have landed, so a blind retry duplicates it.
    public static let writeFailed =
        "That change couldn't be saved. Re-read the item before retrying, in case an earlier attempt already went through."
    /// Write budget exhausted (distinct from the search `busy`: the fix is
    /// to pause, and a re-read guards against duplicating queued retries).
    public static let writeBusy =
        "Too many changes in a short time. Wait a minute, re-read anything you retried, then continue."
    /// The custom-field name collides with one the app uses internally.
    public static let reservedFieldName =
        "That field name is reserved for the app's own use. Choose a different name."
    /// The custom-field type isn't one an assistant may write.
    public static let invalidFieldType =
        "The type argument must be \"text\", \"multilineNote\", \"date\", or \"checkbox\"."
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
            notFoundNote, notFoundField, notFoundTag, notFoundLink, notFoundPlace,
            eventNeedsAppFirst, writeFailed, writeBusy, reservedFieldName,
            invalidFieldType,
        ]
    }
}

/// Fixed acknowledgement texts for write tools whose result has no natural
/// payload to echo (deletes, reorders, favorite flips). Agent-facing, so they
/// live here under the banned-vocabulary test like the error strings.
public enum WireAckMessage {
    public static let noteDeleted = "The note was deleted."
    public static let fieldDeleted = "The custom field was deleted."
    public static let tagDeleted = "The tag was deleted."
    public static let linkRemoved = "The connection was removed."
    public static let favoriteSet = "Done — the contact is now a favorite."
    public static let favoriteCleared = "Done — the contact is no longer a favorite."
    public static let guideDeleted = "The guide was deleted."
    public static let placeDeleted = "The place was deleted."
    public static let placesReordered = "The new order was saved."

    /// Every fixed string above, for the banned-vocabulary test.
    public static var allFixedStrings: [String] {
        [
            noteDeleted, fieldDeleted, tagDeleted, linkRemoved,
            favoriteSet, favoriteCleared, guideDeleted, placeDeleted,
            placesReordered,
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

/// User-facing copy for the Recently Deleted surface (rendered by the app;
/// defined here so the banned-vocabulary test covers it — same arrangement
/// as `PreferencesStrings`). Named "Recently Deleted" after Apple's own
/// Photos/Notes term; plain language only, no seam or mechanism words.
public enum RecentlyDeletedStrings {
    public static let title = "Recently Deleted"
    public static let emptyMessage = "Nothing has been deleted recently."
    public static let restoreButton = "Restore"
    public static let restoreBlocked =
        "This item changed after it was deleted, so it can't be restored automatically."
    public static let restoreFailed = "The item couldn't be restored. Try again."
    public static let restored = "Restored."
    /// Row-title templates. The %@ is the record's display name ("Jane
    /// Doe", an event title, a guide name).
    public static let noteRowTitle = "Note about %@"
    public static let fieldRowTitle = "Custom field on %@"
    public static let tagRowTitle = "Tag on %@"
    public static let linkRowTitle = "Connection on %@"
    /// Fallback when the record the item belonged to can't be resolved
    /// anymore (e.g. the contact was removed).
    public static let unknownSubject = "a contact or event"

    public static var allFixedStrings: [String] {
        [
            title, emptyMessage, restoreButton, restoreBlocked, restoreFailed,
            restored, noteRowTitle, fieldRowTitle, tagRowTitle, linkRowTitle,
            unknownSubject,
        ]
    }
}
