import Foundation
import GuessWhoSync

extension Notification.Name {
    /// Posted after the set of calendars shown in the Events section changes.
    /// `EventsRepository` observes this so an open list updates immediately.
    static let calendarVisibilityDidChange = Notification.Name("CalendarVisibilityDidChange")
}

/// Persists which system calendars are hidden from the app's Events section.
///
/// Each calendar and each account has its own switch, and neither changes the
/// other: turning an account off hides all of its calendars but keeps each
/// calendar's own switch, so turning the account back on restores the
/// selection the user made inside it. A calendar is shown only while its own
/// switch AND its account's switch are on.
///
/// We store the exceptions (hidden identifiers), rather than the selected
/// identifiers, so a newly-added calendar or account is visible by default.
/// Events that do not come from a system calendar are always visible.
@MainActor
@Observable
final class CalendarVisibilitySettings {
    private let defaults: UserDefaults?
    private let notificationCenter: NotificationCenter

    /// Calendars whose own switch is off.
    private(set) var hiddenCalendarIDs: Set<String>

    /// Accounts (`EventCalendar.sourceID`) whose switch is off.
    private(set) var hiddenAccountIDs: Set<String>

    /// The account of each listed calendar. Events name only their calendars,
    /// so this is how a hidden account hides them. Learned from the calendar
    /// list through `updateCalendars(_:)`; kept in memory only, because the
    /// Events list refreshes it on every full reload. A calendar missing from
    /// it is governed by its own switch alone.
    private var accountIDsByCalendarID: [String: String] = [:]

    init(
        defaults: UserDefaults? = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.hiddenCalendarIDs = Set(
            defaults?.stringArray(forKey: AppSettings.Key.hiddenEventCalendarIDs) ?? []
        )
        self.hiddenAccountIDs = Set(
            defaults?.stringArray(forKey: AppSettings.Key.hiddenEventCalendarAccountIDs) ?? []
        )
    }

    /// Whether events from this calendar are shown: its own switch and its
    /// account's switch are both on. Events with no calendar are always shown.
    func isVisible(calendarID: String?) -> Bool {
        guard let calendarID else { return true }
        guard isCalendarEnabled(calendarID) else { return false }
        guard let accountID = accountIDsByCalendarID[calendarID] else { return true }
        return isAccountEnabled(accountID)
    }

    /// An EventKit event can have equivalent copies in several calendars.
    /// Keep its single Events-section row whenever at least one copy belongs
    /// to a shown calendar. An empty set is a manual event and is always shown.
    func isVisible(calendarIDs: Set<String>) -> Bool {
        calendarIDs.isEmpty || calendarIDs.contains { isVisible(calendarID: $0) }
    }

    /// The calendar's own switch, independent of its account's switch.
    func isCalendarEnabled(_ calendarID: String) -> Bool {
        !hiddenCalendarIDs.contains(calendarID)
    }

    /// The account's own switch, independent of its calendars' switches.
    func isAccountEnabled(_ accountID: String) -> Bool {
        !hiddenAccountIDs.contains(accountID)
    }

    func setCalendarEnabled(_ isEnabled: Bool, calendarID: String) {
        guard Self.update(&hiddenCalendarIDs, id: calendarID, isHidden: !isEnabled) else { return }
        defaults?.set(hiddenCalendarIDs.sorted(), forKey: AppSettings.Key.hiddenEventCalendarIDs)
        notificationCenter.post(name: .calendarVisibilityDidChange, object: self)
    }

    func setAccountEnabled(_ isEnabled: Bool, accountID: String) {
        guard Self.update(&hiddenAccountIDs, id: accountID, isHidden: !isEnabled) else { return }
        defaults?.set(hiddenAccountIDs.sorted(), forKey: AppSettings.Key.hiddenEventCalendarAccountIDs)
        notificationCenter.post(name: .calendarVisibilityDidChange, object: self)
    }

    /// Records which account each calendar belongs to. Posts no change: the
    /// Events list calls this during a full reload, before it publishes the
    /// rows this filters, so the next snapshot already uses it.
    func updateCalendars(_ calendars: [EventCalendar]) {
        accountIDsByCalendarID = Dictionary(
            calendars.map { ($0.id, $0.sourceID) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Inserts or removes `id`; true when the set changed.
    private static func update(_ hidden: inout Set<String>, id: String, isHidden: Bool) -> Bool {
        isHidden ? hidden.insert(id).inserted : hidden.remove(id) != nil
    }
}
