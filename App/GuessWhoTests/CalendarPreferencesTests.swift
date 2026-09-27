#if targetEnvironment(macCatalyst)

import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

@Suite("Calendar preferences")
struct CalendarPreferencesTests {
    @Test
    func groupsCalendarsByAccountIdentityWithStableDisplayOrder() throws {
        let calendars = [
            EventCalendar(
                id: "z-calendar",
                title: "Team",
                sourceID: "exchange-b",
                sourceTitle: "Exchange"
            ),
            EventCalendar(
                id: "b-calendar",
                title: "Work",
                sourceID: "exchange-a",
                sourceTitle: "Exchange"
            ),
            EventCalendar(
                id: "a-calendar",
                title: "Family",
                sourceID: "exchange-a",
                sourceTitle: "Exchange"
            ),
            EventCalendar(
                id: "local-calendar",
                title: "Local",
                sourceID: "",
                sourceTitle: ""
            ),
        ]

        let groups = CalendarAccountGroup.groups(from: calendars)

        #expect(groups.map(\.id) == ["exchange-a", "exchange-b", ""])
        #expect(groups.map(\.title) == ["Exchange", "Exchange", "Other"])
        #expect(groups[0].calendars.map(\.id) == ["a-calendar", "b-calendar"])
        #expect(groups[1].calendars.map(\.id) == ["z-calendar"])
        #expect(groups[2].calendars.map(\.id) == ["local-calendar"])
    }

    /// The account switch and its calendars' switches never change each other.
    /// Turning the account off hides every calendar in it; turning it back on
    /// restores the calendars the user had selected inside it.
    @Test @MainActor
    func accountAndCalendarSwitchesAreIndependent() throws {
        let visibility = CalendarVisibilitySettings(defaults: nil, notificationCenter: NotificationCenter())
        visibility.updateCalendars([
            EventCalendar(id: "work", title: "Work", sourceID: "exchange", sourceTitle: "Exchange"),
            EventCalendar(id: "holidays", title: "Holidays", sourceID: "exchange", sourceTitle: "Exchange"),
            EventCalendar(id: "family", title: "Family", sourceID: "icloud", sourceTitle: "iCloud"),
        ])

        // Hiding one calendar leaves its account and sibling on.
        visibility.setCalendarEnabled(false, calendarID: "holidays")
        #expect(visibility.isAccountEnabled("exchange"))
        #expect(visibility.isVisible(calendarID: "work"))
        #expect(visibility.isVisible(calendarID: "holidays") == false)

        // Hiding every calendar in an account still leaves the account on.
        visibility.setCalendarEnabled(false, calendarID: "work")
        #expect(visibility.isAccountEnabled("exchange"))
        visibility.setCalendarEnabled(true, calendarID: "work")

        // Turning the account off hides its calendars without changing their
        // own switches, and leaves other accounts alone.
        visibility.setAccountEnabled(false, accountID: "exchange")
        #expect(visibility.isCalendarEnabled("work"))
        #expect(visibility.isCalendarEnabled("holidays") == false)
        #expect(visibility.isVisible(calendarID: "work") == false)
        #expect(visibility.isVisible(calendarIDs: ["work", "holidays"]) == false)
        #expect(visibility.isVisible(calendarIDs: ["work", "family"]))
        #expect(visibility.isVisible(calendarID: "family"))

        // Turning it back on restores the selection made inside it.
        visibility.setAccountEnabled(true, accountID: "exchange")
        #expect(visibility.isVisible(calendarID: "work"))
        #expect(visibility.isVisible(calendarID: "holidays") == false)
    }
}

#endif
