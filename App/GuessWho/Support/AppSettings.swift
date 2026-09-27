import Foundation

enum AppSettings {
    enum Key {
        static let debugModeEnabled = "com.milestonemade.guesswho.settings.debugModeEnabled"
        static let hiddenEventCalendarIDs = "com.milestonemade.guesswho.settings.hiddenEventCalendarIDs"
    }

    enum Default {
        static let debugModeEnabled = false
    }
}
