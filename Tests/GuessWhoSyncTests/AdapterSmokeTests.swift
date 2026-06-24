import Foundation
import Testing
@testable import GuessWhoSync

#if canImport(Contacts) && canImport(EventKit)

@Suite("AdapterSmoke")
struct AdapterSmokeTests {
    @Test
    func cnAdapterConformsToContactStoreProtocol() {
        let p: ContactStoreProtocol.Type = CNContactStoreAdapter.self
        _ = p
    }

    @Test
    func ekAdapterConformsToEventStoreProtocol() {
        let p: EventStoreProtocol.Type = EKEventStoreAdapter.self
        _ = p
    }

    // Compile-time smoke: every new EventStoreProtocol method exists on the
    // adapter. The function bodies are never executed at test-time (no
    // EKEventStore is available in the test process); the value of this
    // suite is that it fails to compile if a method drops off the adapter.
    // Compile-time smoke: every new ContactGroup-related method exists on the
    // CN adapter. The function body is never executed at test-time (no
    // Contacts authorization is granted in the test process); the value of
    // this suite is that it fails to compile if a method drops off the adapter.
    @Test
    func cnAdapterExposesGroupSurface() {
        func _useGroups(_ adapter: CNContactStoreAdapter) async throws {
            _ = try await adapter.fetchAllGroups()
            _ = try await adapter.fetchGroup(localID: "x")
            _ = try await adapter.createGroup(name: "x")
            try await adapter.renameGroup(localID: "x", to: "y")
            try await adapter.deleteGroup(localID: "x")
            _ = try await adapter.fetchMembers(ofGroup: "x")
            _ = try await adapter.fetchGroupMemberships(contactLocalID: "x")
            try await adapter.addMember(contactLocalID: "x", toGroup: "y")
            try await adapter.removeMember(contactLocalID: "x", fromGroup: "y")
        }
        _ = _useGroups
    }

    // Compile-time smoke: the change-history delta read exists on the adapter.
    // The body never runs (no Contacts authorization in the test process); the
    // value is that it fails to compile if `changes(since:)` drops off.
    @Test
    func cnAdapterExposesChangeHistorySurface() {
        func _useChanges(_ adapter: CNContactStoreAdapter) async throws {
            _ = try await adapter.changes(since: nil)
            _ = try await adapter.changes(since: Data())
        }
        _ = _useChanges
    }

    @Test
    func ekAdapterExposesExtendedSurface() {
        func _useReads(_ adapter: EKEventStoreAdapter) throws {
            _ = try adapter.fetchEvents(in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 1)
            ))
            _ = try adapter.fetch(eventKitID: "any")
            _ = try adapter.fetchEvents(on: Date(timeIntervalSince1970: 0))
            _ = try adapter.searchEvents(
                matching: "x",
                in: DateInterval(
                    start: Date(timeIntervalSince1970: 0),
                    end: Date(timeIntervalSince1970: 1)
                )
            )
        }
        func _useWrites(_ adapter: EKEventStoreAdapter) throws {
            _ = try adapter.createEvent(
                title: "t",
                startDate: Date(timeIntervalSince1970: 0),
                endDate: Date(timeIntervalSince1970: 1),
                isAllDay: false,
                location: nil
            )
            try adapter.updateEvent(
                eventKitID: "x",
                title: "t",
                startDate: Date(timeIntervalSince1970: 0),
                endDate: Date(timeIntervalSince1970: 1),
                isAllDay: false,
                location: nil
            )
        }
        _ = _useReads
        _ = _useWrites
    }
}

#endif
