import Foundation
import GuessWhoSync

/// Navigation payload for "show this contact's detail." Carries the opaque,
/// package-vended `ContactID` — NEVER a raw `localID` — so the app's whole
/// navigation layer keys on stable GuessWho identity (`guessWhoID ?? localID`)
/// rather than Apple's transient `CNContact.identifier`. The scene delegate
/// resolves it back to a `Contact` via `repository.contact(id:)` when it builds
/// the detail view; an unresolvable id (deleted / retired) yields the detail
/// view's non-crashing "unavailable" state.
struct ContactReference: Hashable {
    let id: ContactID
}

/// Navigation payload for "show the people in this department of this
/// organization." Carries the organization's opaque `ContactID` (resolved to
/// the org record when the destination list is built) plus the department name
/// as the user typed it into their contacts. The pair identifies one department
/// bucket within one organization — the same department string under a
/// different organization is a distinct destination.
struct DepartmentReference: Hashable {
    let organizationID: ContactID
    let department: String
}

struct EventReference: Hashable {
    let eventUUID: String
    /// Optional EventKit identifier carried as a hint so the detail view can
    /// adopt an ephemeral EventKit row (one whose `eventUUID` is a synthetic
    /// `Event.stableID(forEventKitID:)`, not a real sidecar UUID). NOT part
    /// of identity — see Hashable/Equatable below — so the same underlying
    /// event pushed with vs. without the hint is treated as one stack entry.
    let eventKitID: String?

    init(eventUUID: String, eventKitID: String? = nil) {
        self.eventUUID = eventUUID.lowercased()
        self.eventKitID = eventKitID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(eventUUID)
    }

    static func == (lhs: EventReference, rhs: EventReference) -> Bool {
        lhs.eventUUID == rhs.eventUUID
    }
}

