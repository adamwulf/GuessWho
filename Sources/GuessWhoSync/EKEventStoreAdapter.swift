#if canImport(EventKit)
import EventKit
import Foundation

public final class EKEventStoreAdapter: EventStoreProtocol {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func fetchEvents(in interval: DateInterval) throws -> [Event] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).map(Self.toEvent)
    }

    public func fetch(externalID: String) throws -> Event? {
        let items = store.calendarItems(withExternalIdentifier: externalID)
        guard let event = items.compactMap({ $0 as? EKEvent }).first else {
            return nil
        }
        return Self.toEvent(event)
    }

    private static func toEvent(_ e: EKEvent) -> Event {
        Event(
            externalID: e.calendarItemExternalIdentifier ?? "",
            title: e.title ?? "",
            startDate: e.startDate,
            endDate: e.endDate,
            isAllDay: e.isAllDay,
            location: e.location,
            notes: e.notes
        )
    }
}

#endif
