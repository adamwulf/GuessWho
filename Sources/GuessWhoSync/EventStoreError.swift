import Foundation

public enum EventStoreError: Error, Equatable {
    case eventNotFound(eventKitID: String)
    case noWritableCalendar
}
