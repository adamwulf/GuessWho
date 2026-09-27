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
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    private(set) var hiddenCalendarIDs: Set<String>

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.hiddenCalendarIDs = Set(
            defaults.stringArray(forKey: AppSettings.Key.hiddenEventCalendarIDs) ?? []
        )
    }

    func isVisible(calendarID: String?) -> Bool {
        guard let calendarID else { return true }
        return !hiddenCalendarIDs.contains(calendarID)
    }

    func setVisible(_ isVisible: Bool, calendarID: String) {
        let changed: Bool
        if isVisible {
            changed = hiddenCalendarIDs.remove(calendarID) != nil
        } else {
            changed = hiddenCalendarIDs.insert(calendarID).inserted
        }
        guard changed else { return }

        defaults.set(hiddenCalendarIDs.sorted(), forKey: AppSettings.Key.hiddenEventCalendarIDs)
        notificationCenter.post(name: .calendarVisibilityDidChange, object: self)
    }
}
