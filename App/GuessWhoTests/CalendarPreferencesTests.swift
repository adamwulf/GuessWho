#if targetEnvironment(macCatalyst)

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
}

#endif
