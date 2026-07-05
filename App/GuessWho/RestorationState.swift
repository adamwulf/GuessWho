import Foundation
import GuessWhoSync

/// The per-scene UI state we restore across launches: which section (sidebar
/// tab) was showing, and — optionally — the specific record open in the detail
/// column/stack.
///
/// This is the payload behind scene-based state restoration
/// (`UISceneDelegate.stateRestorationActivity(for:)`). On Mac Catalyst a ⌘Q
/// quit + relaunch restores it (macOS window-restoration semantics); on
/// iPhone/iPad the system restores it when it discards a backgrounded scene.
/// It is deliberately SMALL — a section plus one record reference — matching the
/// agreed "restore the section + the detail you were looking at" scope (not the
/// full navigation breadcrumb).
///
/// ## Identity, persisted correctly
///
/// A contact selection stores a `ContactRestorationToken`, NOT a `ContactID`:
/// `ContactID` is deliberately non-persistable (it carries a transient
/// `localID` that would dangle), while `ContactRestorationToken` is the
/// purpose-built `Codable` snapshot. An event stores its already-durable
/// `eventUUID` string plus the optional `eventKitID` needed to adopt an
/// ephemeral EventKit row on reopen.
struct RestorationState: Codable, Equatable {
    /// Which section was showing. Stored as the `SidebarTab.rawValue` string.
    var section: SidebarTab

    /// The record open in the detail area, if any. Nil ⇒ restore the section
    /// with no selected record (land on the list/placeholder).
    var selection: Selection?

    enum Selection: Codable, Equatable {
        /// A contact detail, keyed by its persistable restoration token.
        case contact(ContactRestorationToken)
        /// An event detail. `eventUUID` is the sidecar UUID (or the synthetic
        /// `Event.stableID(forEventKitID:)` for a pre-adoption EventKit row);
        /// `eventKitID` lets the reopened detail adopt that ephemeral row.
        case event(eventUUID: String, eventKitID: String?)
    }
}

extension RestorationState {
    /// The activity type for the restoration `NSUserActivity`. Derived from the
    /// bundle id so Debug and Release builds (different bundle ids) never share
    /// or clobber each other's restoration state.
    static var activityType: String {
        let base = Bundle.main.bundleIdentifier ?? "com.milestonemade.guesswho"
        return "\(base).state-restoration"
    }

    private static let payloadKey = "restorationState"

    /// Serialize into a fresh `NSUserActivity` for the scene to hand back to the
    /// system. Encodes the whole `RestorationState` as JSON under a single
    /// `userInfo` key so the shape can evolve without touching the plumbing.
    func makeUserActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        if let data = try? JSONEncoder().encode(self) {
            activity.addUserInfoEntries(from: [Self.payloadKey: data])
        }
        return activity
    }

    /// Reconstruct from a restoration `NSUserActivity`, or nil if the activity is
    /// absent, the wrong type, or its payload can't be decoded (a forward/back
    /// incompatible or corrupt blob restores nothing rather than crashing).
    init?(userActivity: NSUserActivity?) {
        guard let activity = userActivity, activity.activityType == Self.activityType else { return nil }
        guard let data = activity.userInfo?[Self.payloadKey] as? Data else { return nil }
        guard let decoded = try? JSONDecoder().decode(RestorationState.self, from: data) else { return nil }
        self = decoded
    }
}
