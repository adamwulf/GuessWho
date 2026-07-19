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
    /// The id doesn't resolve to a live record — unknown, out of date
    /// (the record changed or was removed), or of the wrong kind. Since
    /// Revision 2 the wire id is the record's own durable id, so there is
    /// no separate per-run stale-reference state: every unresolvable id is
    /// `notFound`, with guidance to search/list again.
    case notFound
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
    /// A match-based single-entry edit (contacts_edit_value)
    /// found MORE THAN ONE entry with the given value, so applying it
    /// would guess which one the caller meant. Additive like `busy`:
    /// `invalidParams` would tell the agent its arguments are malformed
    /// (they aren't), and `notFound` would tell it to search again (the
    /// entries exist — that's the problem). Nothing is ever changed on an
    /// ambiguous match.
    case ambiguous
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
    public static let busy =
        "Too many requests at once. Wait a moment and try again."
    // The notFound* strings pair with the `notFound` code above. Since the
    // wire id is the record's own durable id, an unresolvable id always
    // means the record is gone or changed — the fix is to search/list again.
    public static let notFoundContact =
        "No matching contact was found for that id. It may have changed or been removed — search again to get a current id."
    public static let notFoundEvent =
        "No matching event was found for that id. Run events_list again to get current ids."
    public static let notFoundGroup =
        "No matching group was found for that id. Run contacts_list_groups again to get current ids."
    public static let notFoundGuide =
        "No matching guide was found for that id. Run guides_list again to get current ids."
    public static let notFoundNote =
        "No matching note was found on that contact. List the notes again to get current ids."
    public static let notFoundField =
        "No matching custom field was found on that contact. List the custom fields again to get current ids."
    public static let notFoundTag =
        "No matching tag was found on that event. List the tags again to get current ids."
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
    // Write-path argument errors, centralized here (rather than inline in
    // the dispatcher) so the banned-vocabulary test scans them.
    public static let emptyNameArgument =
        "The name argument must not be empty."
    public static let invalidDateFieldValue =
        "The value argument for a date field must be an ISO 8601 date, like 2026-07-01."
    public static let invalidCheckboxFieldValue =
        "The value argument for a checkbox field must be \"true\" or \"false\"."
    public static let reorderMustCoverEveryPlace =
        "The placeIds argument must contain every place in the guide exactly once, in the desired order."
    // Contact-record write errors (plans/cli-mcp.md Revision 2: full
    // Contact Store read/write parity).
    /// A create/update whose field set leaves the contact unnameable.
    public static let contactNeedsAName =
        "Provide at least a name or an organization for the contact."
    public static let invalidKindArgument =
        "The kind argument must be \"person\" or \"organization\"."
    /// contacts_list's kind filter took something other than its two plain
    /// values.
    public static let invalidTypeArgument =
        "The type argument must be \"person\" or \"organization\". Omit it to list both."
    public static let updateNeedsAField =
        "Pass at least one field to change."
    public static let invalidCalendarDateValue =
        "Dates must look like 2026-08-01, or --08-01 when the year is unknown."
    /// A wire-supplied web address tried to use the app's own reserved
    /// address form.
    public static let reservedWebAddress =
        "One of the web addresses uses a form reserved for the app's own use. Remove it and try again."
    /// A create/update carried a note-shaped argument. Contact cards never
    /// accept one over this channel; GuessWho's own dated notes are the
    /// supported way to write notes.
    public static let contactNoteNotAccepted =
        "Contact cards don't accept a note argument. To save a note about a contact, use contacts_add_note."
    /// The system rejected a field value on save (CNError validation
    /// family). Deliberately carries NO detail — interpolating the system's
    /// description could echo contact data into an error string.
    public static let contactFieldRejected =
        "The system rejected one of the field values. Check the values and try again."
    // Single-entry list edits (plans/cli-mcp.md Phase 7). contacts_update
    // is scalars-only: a whole-list argument is rejected LOUDLY toward the
    // dedicated one-entry-at-a-time tools, never silently ignored.
    public static let invalidContactListField =
        "The field argument must be one of: \(WireContactListField.allCases.map(\.rawValue).joined(separator: ", "))."
    /// contacts_update carried one of the single-entry-editable lists.
    public static let listArgumentNotAccepted =
        "contacts_update changes single-value fields only. To add, change, or remove a phone number, email address, web address, related name, or date, use contacts_add_value, contacts_edit_value, or contacts_remove_value with field phone, email, url, related_name, or date."
    /// contacts_update carried a list that has no single-entry tools yet
    /// (postal addresses, social profiles, instant messages).
    public static let createOnlyListArgumentNotAccepted =
        "contacts_update can't change postal addresses, social profiles, or instant messages. Those can currently only be provided when creating a contact with contacts_create."
    public static let emptyValueArgument =
        "The value argument must not be empty."
    // Match-based single-entry edits: the 0-match answers per list.
    public static let noPhoneWithThatValue =
        "No phone number with that exact value was found on that contact. Read the contact to see its current phone numbers, then pass one of them verbatim."
    public static let noEmailWithThatValue =
        "No email address with that exact value was found on that contact. Read the contact to see its current email addresses, then pass one of them verbatim."
    public static let noURLWithThatValue =
        "No web address with that exact value was found on that contact. Read the contact to see its current web addresses, then pass one of them verbatim."
    public static let noRelatedNameWithThatValue =
        "No related name with that exact value was found on that contact. Read the contact to see its current related names, then pass one of them verbatim."
    public static let noDateWithThatValue =
        "No date with that value was found on that contact. Read the contact to see its current dates, then pass one of them."
    // Match-based single-entry edits: the more-than-one-match answers. The
    // duplicate entries are indistinguishable by value, so the wire never
    // guesses — the user resolves it in the app.
    public static let ambiguousPhoneValue =
        "That contact has more than one phone number with that exact value, so it isn't clear which one you mean. Nothing was changed. Ask the user to make this change in the GuessWho app."
    public static let ambiguousEmailValue =
        "That contact has more than one email address with that exact value, so it isn't clear which one you mean. Nothing was changed. Ask the user to make this change in the GuessWho app."
    public static let ambiguousURLValue =
        "That contact has more than one web address with that exact value, so it isn't clear which one you mean. Nothing was changed. Ask the user to make this change in the GuessWho app."
    public static let ambiguousRelatedNameValue =
        "That contact has more than one related name with that exact value, so it isn't clear which one you mean. Nothing was changed. Ask the user to make this change in the GuessWho app."
    public static let ambiguousDateValue =
        "That contact has more than one date with that value, so it isn't clear which one you mean. Nothing was changed. Ask the user to make this change in the GuessWho app."
    /// Confirmation-gated writes: nothing on screen to present the
    /// confirmation on.
    public static let confirmationUnavailable =
        "This change needs the user's confirmation, but the confirmation couldn't be shown. Ask the user to bring the GuessWho app to the front, then try again."
    /// Confirmation-gated writes: the user answered after the call had
    /// already timed out, so the change was NOT applied (the reported
    /// timeout and the actual effect must always agree).
    public static let confirmationExpired =
        "The confirmation wasn't answered in time, so nothing was changed. Try again and ask the user to respond to the dialog."
    /// A second confirmation-gated request while one is already on screen.
    public static let confirmationAlreadyPending =
        "Another change is already waiting for the user's confirmation. Wait for that answer, then try again."
    // Generic-connection (links_*) argument errors. Same arrangement as the
    // other write-path messages: fixed strings, centralized here so the
    // banned-vocabulary test scans them.
    public static let invalidLinkKindArgument =
        "Each kind argument must be \"person\", \"organization\", \"event\", or \"place\"."
    /// An id that resolves, but not to a record of the kind declared for it
    /// (e.g. fromKind "organization" with a person's id).
    public static let linkKindMismatch =
        "One of the ids doesn't belong to a record of the kind given for it. Check fromKind and toKind against the ids and try again."
    /// The one kind pair with no way to connect in the app.
    public static let linkPairUnsupported =
        "Two places can't be connected to each other. Connect a place to a person, an organization, or an event."
    public static let linkSelfNotAllowed =
        "A record can't be connected to itself. Pass two different records."
    /// The event-side Option B rule, in connection form: the wire never
    /// sets an event up on its own (see eventNeedsAppFirst).
    public static let eventNeedsAppFirstToConnect =
        "That event can't be connected yet. Ask the user to open the event once in the GuessWho app, then try again."
    /// links_remove with an id that isn't a live connection.
    public static let notFoundConnection =
        "No matching connection was found for that id. Run links_list again to get current ids."
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
            readOnly, tooLarge, busy,
            notFoundContact, notFoundEvent, notFoundGroup, notFoundGuide,
            noHostStatus,
            hostNotReady, timedOut,
            notFoundNote, notFoundField, notFoundTag, notFoundPlace,
            eventNeedsAppFirst, writeFailed, writeBusy, reservedFieldName,
            invalidFieldType,
            emptyNameArgument,
            invalidDateFieldValue, invalidCheckboxFieldValue,
            reorderMustCoverEveryPlace,
            contactNeedsAName, invalidKindArgument, invalidTypeArgument,
            updateNeedsAField,
            invalidCalendarDateValue,
            reservedWebAddress, contactNoteNotAccepted,
            listArgumentNotAccepted, createOnlyListArgumentNotAccepted,
            emptyValueArgument,
            noPhoneWithThatValue, noEmailWithThatValue, noURLWithThatValue,
            noRelatedNameWithThatValue, noDateWithThatValue,
            ambiguousPhoneValue, ambiguousEmailValue, ambiguousURLValue,
            ambiguousRelatedNameValue, ambiguousDateValue,
            contactFieldRejected, confirmationUnavailable, confirmationExpired,
            confirmationAlreadyPending,
            invalidLinkKindArgument, linkKindMismatch, linkPairUnsupported,
            linkSelfNotAllowed, eventNeedsAppFirstToConnect, notFoundConnection,
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
    /// contacts_delete after the user approved the in-app confirmation.
    public static let contactDeleted = "The contact was deleted."
    /// contacts_delete after the user cancelled the in-app confirmation.
    /// Deliberately a NORMAL (non-error) result: the agent should read
    /// "declined" as an answer, not a failure to retry.
    public static let contactDeleteDeclined =
        "The user declined to delete this contact. Nothing was changed."

    /// Every fixed string above, for the banned-vocabulary test.
    public static var allFixedStrings: [String] {
        [
            noteDeleted, fieldDeleted, tagDeleted, linkRemoved,
            favoriteSet, favoriteCleared, guideDeleted, placeDeleted,
            placesReordered, contactDeleted, contactDeleteDeclined,
        ]
    }
}

/// User-facing copy for the in-app confirmation that gates uniquely
/// destructive agent writes (contacts_delete — plans/cli-mcp.md Revision
/// 2). Presented by the app as a standard alert naming the SPECIFIC
/// contact; the delete proceeds only on an explicit Delete. Lives here so
/// the banned-vocabulary test covers it.
public enum ConfirmationStrings {
    public static let deleteContactTitle = "Delete Contact?"
    /// %@ is the contact's display name.
    public static let deleteContactMessage =
        "An assistant is asking to delete “%@” from your contacts. This removes the contact from Contacts on all your devices."
    public static let deleteButton = "Delete"
    public static let cancelButton = "Cancel"

    public static var allFixedStrings: [String] {
        [deleteContactTitle, deleteContactMessage, deleteButton, cancelButton]
    }
}

/// User-facing copy for the settings toggles (rendered by the app's
/// Preferences in Phase 3; defined here so the banned-vocabulary test
/// covers them from day one). Plain language only — the user thinks in
/// assistants, contacts, and events, never in transport mechanics.
public enum PreferencesStrings {
    public static let mcpSectionTitle = "AI Assistant Access"
    public static let cliSectionTitle = "Terminal Access"

    /// The one tri-state control per surface (off → read-only →
    /// read-write; Allume's access-mode row, collapsed with its enable
    /// switch into a single picker).
    public static let accessModeLabel = "Access"
    public static let accessModeOff = "Off"
    public static let accessModeReadOnly = "Read-only"
    public static let accessModeReadWrite = "Read-write"

    // Per-state descriptions, per surface, shown under the picker.
    public static let mcpOffDescription =
        "AI assistants you connect (like Claude) can't see or change anything."
    public static let mcpReadOnlyDescription =
        "Read-only: assistants can look up your contacts, events, and guides while GuessWho is open. Nothing can be added, changed, or deleted."
    public static let mcpReadWriteDescription =
        "Read-write: assistants can look up your contacts, events, and guides, and can add and edit them — including contact details like phone numbers and addresses — while GuessWho is open."
    public static let cliOffDescription =
        "Terminal commands can't see or change anything."
    public static let cliReadOnlyDescription =
        "Read-only: terminal commands can look up your contacts, events, and guides while GuessWho is open. Nothing can be added, changed, or deleted."
    public static let cliReadWriteDescription =
        "Read-write: terminal commands can look up your contacts, events, and guides, and can add and edit them — including contact details like phone numbers and addresses — while GuessWho is open."

    public static var allFixedStrings: [String] {
        [
            mcpSectionTitle, cliSectionTitle,
            accessModeLabel, accessModeOff, accessModeReadOnly, accessModeReadWrite,
            mcpOffDescription, mcpReadOnlyDescription, mcpReadWriteDescription,
            cliOffDescription, cliReadOnlyDescription, cliReadWriteDescription,
        ]
    }
}

/// User-facing copy for the Preferences install section (the copy-path
/// primary install + the four-state status — plans/cli-mcp.md Phase 3).
/// Defined here so the banned-vocabulary test covers every string: plain
/// language only, never a mechanism word — the user sees "command-line
/// access" and "link", never the tool that implements it.
public enum InstallStrings {
    public static let sectionTitle = "Command-Line Access"

    // Four-state status copy (one per CLISymlinkResolver state).
    public static let statusNotInstalled = "Install command-line access"
    public static let statusInstalled = "Command-line access is set up."
    public static let statusDangling =
        "The command-line link is broken — reinstall to repair."
    public static let statusConflict =
        "Something else is already installed at this location."

    public static let installButton = "Install"
    public static let reinstallButton = "Reinstall"
    public static let revealConflictButton = "Show in Finder"
    public static let copyRemovalButton = "Copy Removal Command"
    public static let copyPathButton = "Copy Path"
    public static let copiedConfirmation = "Copied"

    /// Caption over the helper-path row — the PRIMARY install on every
    /// channel: the user pastes this absolute path into their assistant's
    /// settings (no generated config, no writing into the client's files).
    public static let helperPathCaption =
        "To connect an assistant, copy this location and paste it into the assistant's settings:"
    /// Caption over the copyable removal command (uninstall is a paste,
    /// never a hand-typed path).
    public static let removalCaption =
        "To remove command-line access, paste this command in Terminal:"
    /// Shown under the installed status.
    public static let installedDetail =
        "You can use the guesswho command in Terminal."
    /// Stale-location repair hint: the app moved (or was updated in place)
    /// since the user last copied the path or installed, so a pasted
    /// absolute path in an assistant's settings no longer resolves.
    public static let repairHint =
        "GuessWho has moved since it was set up. Copy the new location and update the assistant's settings, or reinstall below."
    /// Alert title/body when the embedded command-line tool can't be found
    /// in the app bundle at all (packaging failure).
    public static let helperMissing = "The command-line tool couldn't be found."
    public static let installFailedTitle = "Couldn't Install"

    public static var allFixedStrings: [String] {
        [
            sectionTitle, statusNotInstalled, statusInstalled, statusDangling,
            statusConflict, installButton, reinstallButton, revealConflictButton,
            copyRemovalButton, copyPathButton, copiedConfirmation,
            helperPathCaption, removalCaption, installedDetail, repairHint,
            helperMissing, installFailedTitle,
        ]
    }
}

/// User-facing copy for the Preferences "Agent activity" section — the
/// device-local audit log rendered as plain rows ("Added a note to Jane
/// Doe — 3:14 PM"). Row titles are templates; %@ is the record's display
/// name snapshot from the audit entry.
public enum AgentActivityStrings {
    public static let sectionTitle = "Agent Activity"
    public static let emptyMessage = "No agent activity yet."
    public static let footer =
        "Changes that assistants and terminal commands make on this Mac appear here."

    public static let addedNote = "Added a note to %@"
    public static let editedNote = "Edited a note on %@"
    public static let deletedNote = "Deleted a note from %@"
    public static let setCustomField = "Set a custom field on %@"
    public static let deletedCustomField = "Deleted a custom field from %@"
    public static let addedConnection = "Added a connection to %@"
    public static let removedConnection = "Removed a connection from %@"
    public static let markedFavorite = "Marked %@ as a favorite"
    public static let clearedFavorite = "Removed %@ from favorites"
    public static let addedTag = "Added a tag to %@"
    public static let editedTag = "Edited a tag on %@"
    public static let deletedTag = "Deleted a tag from %@"
    public static let createdGuide = "Created the guide %@"
    public static let deletedGuide = "Deleted the guide %@"
    public static let reorderedPlaces = "Reordered the places in %@"
    public static let deletedPlace = "Deleted a place from %@"
    public static let createdContact = "Added the contact %@"
    public static let editedContact = "Edited the contact %@"
    public static let deletedContact = "Deleted the contact %@ (approved by you)"
    /// Fallback when the entry's display-name snapshot is empty.
    public static let unknownSubject = "an item"

    public static var allFixedStrings: [String] {
        [
            sectionTitle, emptyMessage, footer,
            addedNote, editedNote, deletedNote,
            setCustomField, deletedCustomField,
            addedConnection, removedConnection,
            markedFavorite, clearedFavorite,
            addedTag, editedTag, deletedTag,
            createdGuide, deletedGuide, reorderedPlaces, deletedPlace,
            createdContact, editedContact, deletedContact,
            unknownSubject,
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
