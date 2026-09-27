import Foundation

enum AppSettings {
    enum Key {
        static let debugModeEnabled = "com.milestonemade.guesswho.settings.debugModeEnabled"
        static let hiddenEventCalendarIDs = "com.milestonemade.guesswho.settings.hiddenEventCalendarIDs"
        static let hiddenEventCalendarAccountIDs = "com.milestonemade.guesswho.settings.hiddenEventCalendarAccountIDs"
    }

    enum Default {
        static let debugModeEnabled = false
    }
}
