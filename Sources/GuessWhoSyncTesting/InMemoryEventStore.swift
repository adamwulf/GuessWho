import Foundation
import GuessWhoSync

public final class InMemoryEventStore: EventStoreProtocol {
    private let lock = NSLock()
    private var eventsByID: [String: Event]

    public init(events: [Event] = []) {
        var initial: [String: Event] = [:]
        for event in events {
            initial[event.externalID] = event
        }
        self.eventsByID = initial
    }

    public func fetchEvents(in interval: DateInterval) throws -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return eventsByID.values.filter { event in
            event.startDate <= interval.end && event.endDate >= interval.start
        }
    }

    public func fetch(externalID: String) throws -> Event? {
        lock.lock()
        defer { lock.unlock() }
        return eventsByID[externalID]
    }
}
