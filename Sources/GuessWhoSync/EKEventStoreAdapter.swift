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
        return store.events(matching: predicate).compactMap(Self.toEvent)
    }

    public func fetch(externalID: String) throws -> Event? {
        guard let event = store.event(withIdentifier: externalID) else { return nil }
        return Self.toEvent(event)
    }

    private static func toEvent(_ e: EKEvent) -> Event? {
        guard let id = e.eventIdentifier, !id.isEmpty else { return nil }
        let location = (e.location?.isEmpty ?? true) ? nil : e.location
        let notes = (e.notes?.isEmpty ?? true) ? nil : e.notes
        return Event(
            externalID: id,
            title: e.title ?? "",
            startDate: e.startDate,
            endDate: e.endDate,
            isAllDay: e.isAllDay,
            location: location,
            notes: notes
        )
    }
}

#endif
