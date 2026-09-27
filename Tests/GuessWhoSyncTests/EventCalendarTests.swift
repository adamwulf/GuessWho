#if canImport(EventKit)
import EventKit
#endif
import Foundation
import Testing
@testable import GuessWhoSync

@Suite("EventCalendar")
struct EventCalendarTests {

    // MARK: - Event.calendarID Codable

    @Test("Event decodes a payload written before calendarID existed, with calendarID nil")
    func eventDecodesPayloadWithoutCalendarID() throws {
        // Keys exactly as the pre-calendarID synthesized encoder wrote them.
        let legacy = """
        {
          "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "eventKitID": "ek-legacy",
          "title": "Standup",
          "startDate": 0,
          "endDate": 900,
          "isAllDay": false,
          "attendees": [],
          "calendarName": "Work",
          "calendarColorHex": "#FF9500"
        }
        """
        let decoded = try JSONDecoder().decode(Event.self, from: Data(legacy.utf8))
        #expect(decoded.calendarID == nil)
        #expect(decoded.eventKitID == "ek-legacy")
        #expect(decoded.calendarName == "Work")
        #expect(decoded.calendarColorHex == "#FF9500")
    }

    @Test("Event round-trips calendarID through Codable")
    func eventRoundTripsCalendarID() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let original = Event(
            eventKitID: "ek-1",
            title: "Planning",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            calendarID: "cal-work",
            calendarName: "Work",
            calendarColorHex: "#FF9500"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        #expect(decoded == original)
        #expect(decoded.calendarID == "cal-work")
    }

    @Test("A manual event has no calendarID by default")
    func manualEventHasNoCalendarID() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(Event(startDate: start, endDate: start).calendarID == nil)
    }

    @Test("EventCalendar round-trips through Codable, with and without a color")
    func eventCalendarRoundTrips() throws {
        let calendars = [
            EventCalendar(id: "cal-1", title: "Work", sourceID: "src-1", sourceTitle: "iCloud", colorHex: "#FF9500"),
            EventCalendar(id: "cal-2", title: "Birthdays", sourceID: "src-2", sourceTitle: "Other"),
        ]
        let data = try JSONEncoder().encode(calendars)
        #expect(try JSONDecoder().decode([EventCalendar].self, from: data) == calendars)
        #expect(calendars[1].colorHex == nil)
    }

#if canImport(EventKit)

    // MARK: - EKEventStoreAdapter mapping

    @Test("calendarID(of:) is nil when the event has no calendar")
    func calendarIDOfNilCalendarIsNil() {
        #expect(EKEventStoreAdapter.calendarID(of: nil) == nil)
    }

    @Test("toEventCalendar mirrors the EKCalendar identity, title, and color")
    func toEventCalendarMirrorsCalendar() throws {
        // A new, unsaved EKCalendar needs no calendar access. It has no source,
        // so this also covers the empty account fallback.
        let calendar = EKCalendar(for: .event, eventStore: EKEventStore())
        calendar.title = "Work"
        calendar.cgColor = CGColor(srgbRed: 1, green: 149.0 / 255.0, blue: 0, alpha: 1)

        let mapped = try #require(EKEventStoreAdapter.toEventCalendar(calendar))
        #expect(!mapped.id.isEmpty)
        #expect(mapped.id == calendar.calendarIdentifier)
        // The same rule stamps Event.calendarID in toEvent, so an event in
        // this calendar filters to exactly this descriptor.
        #expect(EKEventStoreAdapter.calendarID(of: calendar) == mapped.id)
        #expect(mapped.title == "Work")
        #expect(mapped.colorHex == "#FF9500")
        #expect(mapped.sourceID == "")
        #expect(mapped.sourceTitle == "")
    }

    // MARK: - EKEventStoreAdapter.fetchEventCalendars

    private static let listed = [
        EventCalendar(id: "cal-work", title: "Work", sourceID: "src-icloud", sourceTitle: "iCloud", colorHex: "#FF9500"),
        EventCalendar(id: "cal-team", title: "Team", sourceID: "src-exchange", sourceTitle: "Exchange"),
    ]

    private func makeAdapter(
        authorization: CalendarAuthorizationBox,
        listings: CalendarListingCounter
    ) -> EKEventStoreAdapter {
        EKEventStoreAdapter(
            notificationCenter: NotificationCenter(),
            fetchEventsWork: { _, _ in [] },
            fetchCalendarsWork: { _ in
                listings.increment()
                return Self.listed
            },
            authorizationStatusWork: { authorization.value }
        )
    }

    @Test("With read access the adapter returns the EventKit calendar listing")
    func adapterListsCalendarsWhenAuthorized() throws {
        let listings = CalendarListingCounter()
        let adapter = makeAdapter(authorization: CalendarAuthorizationBox(.authorized), listings: listings)
        #expect(try adapter.fetchEventCalendars() == Self.listed)
        #expect(listings.count == 1)
    }

    @Test(
        "Without read access the adapter lists nothing and never asks EventKit",
        arguments: [StoreAuthorizationStatus.notDetermined, .denied, .restricted]
    )
    func adapterListsNothingWithoutReadAccess(_ status: StoreAuthorizationStatus) throws {
        let listings = CalendarListingCounter()
        let authorization = CalendarAuthorizationBox(status)
        let adapter = makeAdapter(authorization: authorization, listings: listings)
        #expect(try adapter.fetchEventCalendars().isEmpty)
        #expect(listings.count == 0)

        // Nothing is cached: a later grant lists the calendars.
        authorization.value = .authorized
        #expect(try adapter.fetchEventCalendars() == Self.listed)
        #expect(listings.count == 1)
    }

#endif
}

#if canImport(EventKit)

private final class CalendarAuthorizationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: StoreAuthorizationStatus

    init(_ status: StoreAuthorizationStatus) {
        self.status = status
    }

    var value: StoreAuthorizationStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
        set {
            lock.lock()
            status = newValue
            lock.unlock()
        }
    }
}

private final class CalendarListingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}

#endif
