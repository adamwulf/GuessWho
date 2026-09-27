import Foundation

extension Notification.Name {
    /// Posted after the set of calendars shown in the Events section changes.
    /// `EventsRepository` observes this so an open list updates immediately.
    static let calendarVisibilityDidChange = Notification.Name("CalendarVisibilityDidChange")
}

/// Persists which system calendars are hidden from the app's Events section.
///
/// We store the exceptions (hidden identifiers), rather than the selected
/// identifiers, so a newly-added calendar is visible by default. Events that
/// do not come from a system calendar are always visible.
@MainActor
@Observable
final class CalendarVisibilitySettings {
    private let defaults: UserDefaults?
    private let notificationCenter: NotificationCenter

    private(set) var hiddenCalendarIDs: Set<String>

    init(
        defaults: UserDefaults? = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.hiddenCalendarIDs = Set(
            defaults?.stringArray(forKey: AppSettings.Key.hiddenEventCalendarIDs) ?? []
        )
    }

    func isVisible(calendarID: String?) -> Bool {
        guard let calendarID else { return true }
        return !hiddenCalendarIDs.contains(calendarID)
    }

    /// An EventKit event can have equivalent copies in several calendars.
    /// Keep its single Events-section row whenever at least one copy belongs
    /// to a shown calendar. An empty set is a manual event and is always shown.
    func isVisible(calendarIDs: Set<String>) -> Bool {
        calendarIDs.isEmpty || !calendarIDs.isSubset(of: hiddenCalendarIDs)
    }

    func setVisible(_ isVisible: Bool, calendarID: String) {
        setVisible(isVisible, calendarIDs: [calendarID])
    }

    /// Applies an account-level selection as one persisted change and one list
    /// refresh, even when the account contains many calendars.
    func setVisible(_ isVisible: Bool, calendarIDs: [String]) {
        var changed = false
        for calendarID in calendarIDs {
            if isVisible {
                changed = hiddenCalendarIDs.remove(calendarID) != nil || changed
            } else {
                changed = hiddenCalendarIDs.insert(calendarID).inserted || changed
            }
        }
        guard changed else { return }

        defaults?.set(hiddenCalendarIDs.sorted(), forKey: AppSettings.Key.hiddenEventCalendarIDs)
        notificationCenter.post(name: .calendarVisibilityDidChange, object: self)
    }
}
