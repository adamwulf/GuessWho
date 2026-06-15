import Foundation

public protocol EventStoreProtocol {
    func fetchEvents(in interval: DateInterval) throws -> [Event]
    func fetch(externalID: String) throws -> Event?
}
