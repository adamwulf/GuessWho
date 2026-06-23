import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventAttendee")
struct EventAttendeeTests {

    @Test("Initializer lowercases email so attendee↔contact matching is a trivial compare")
    func testEmailLowercased() {
        let a = EventAttendee(name: "Jane Doe", email: "Jane@Example.COM")
        #expect(a.email == "jane@example.com")
        #expect(a.name == "Jane Doe")
    }

    @Test("Initializer leaves a nil email as nil (no empty-string normalization)")
    func testNilEmail() {
        let a = EventAttendee(name: "No Email")
        #expect(a.email == nil)
    }

    @Test("Event encodes and decodes attendees round-trip via Codable")
    func testEventCodableRoundTrip() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let original = Event(
            id: UUID(),
            eventKitID: "ek-1",
            title: "Team sync",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            attendees: [
                EventAttendee(name: "Jane", email: "jane@example.com"),
                EventAttendee(name: "John", email: nil),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Event.self, from: data)
        #expect(decoded == original)
    }

    @Test("Event default initializer leaves attendees empty so existing call sites compile unchanged")
    func testDefaultAttendeesEmpty() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let e = Event(startDate: start, endDate: start)
        #expect(e.attendees.isEmpty)
    }

    @Test("event(at:) overlay propagates live attendees onto the cached projection")
    func testOverlayPropagatesAttendees() throws {
        let ekid = "ek-attendee-overlay"
        let attendees = [
            EventAttendee(name: "Alice", email: "alice@example.com"),
            EventAttendee(name: "Bob", email: "bob@example.com"),
        ]
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let live = Event(
            id: UUID(),
            eventKitID: ekid,
            title: "Standup",
            startDate: start,
            endDate: start.addingTimeInterval(900),
            attendees: attendees
        )
        let contacts = InMemoryContactStore()
        let eventStore = InMemoryEventStore(events: [live])
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: eventStore,
            sidecars: sidecars,
            deviceID: "test-device"
        )

        // Link a sidecar to the live EKEvent so `event(at:)` exercises the
        // overlay path (cached projection + live overlay). The snapshot
        // populates cache cells; the live attendees come in via overlay.
        let mintedID = try sync.linkEvent(toEventKitID: ekid, snapshot: live)
        let key = SidecarKey(kind: .event, id: mintedID.uuidString.lowercased())

        let projected = try #require(try sync.event(at: key))
        #expect(projected.attendees == attendees)
    }
}
