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

    @Test("Equality treats two attendees with same name and case-insensitive-equivalent email as equal")
    func testEqualityRespectsLowercasing() {
        let a = EventAttendee(name: "Jane", email: "Jane@Example.COM")
        let b = EventAttendee(name: "Jane", email: "jane@example.com")
        #expect(a == b)
    }

    // MARK: - mailto: parser

    // EKEventStoreAdapter is gated on #if canImport(EventKit) — these
    // tests only compile (and only matter) on platforms where the
    // adapter exists. `email(from:)` is `internal static` specifically
    // so we can exercise it with synthetic URLs (real `EKParticipant`
    // has no public init).

#if canImport(EventKit)
    @Test("email(from:) parses a plain mailto URL")
    func testEmailParsesPlainMailto() throws {
        let url = try #require(URL(string: "mailto:jane@example.com"))
        #expect(EKEventStoreAdapter.email(from: url) == "jane@example.com")
    }

    @Test("email(from:) tolerates MAILTO / Mailto scheme casing")
    func testEmailToleratesCasing() throws {
        let upper = try #require(URL(string: "MAILTO:bob@example.com"))
        let mixed = try #require(URL(string: "Mailto:bob@example.com"))
        #expect(EKEventStoreAdapter.email(from: upper) == "bob@example.com")
        #expect(EKEventStoreAdapter.email(from: mixed) == "bob@example.com")
    }

    @Test("email(from:) percent-decodes the address so %40 round-trips to @")
    func testEmailPercentDecodes() throws {
        let url = try #require(URL(string: "mailto:foo%40bar.com"))
        #expect(EKEventStoreAdapter.email(from: url) == "foo@bar.com")
    }

    @Test("email(from:) strips RFC 6068 ?headers after the address")
    func testEmailStripsHeaders() throws {
        let url = try #require(URL(string: "mailto:dev@example.com?subject=Hi"))
        #expect(EKEventStoreAdapter.email(from: url) == "dev@example.com")
    }

    @Test("email(from:) returns nil for non-mailto schemes")
    func testEmailRejectsNonMailto() throws {
        let tel = try #require(URL(string: "tel:+15555551212"))
        let http = try #require(URL(string: "https://example.com"))
        #expect(EKEventStoreAdapter.email(from: tel) == nil)
        #expect(EKEventStoreAdapter.email(from: http) == nil)
    }

    @Test("email(from:) returns nil for a mailto URL with an empty body")
    func testEmailEmptyBodyReturnsNil() throws {
        let url = try #require(URL(string: "mailto:"))
        #expect(EKEventStoreAdapter.email(from: url) == nil)
    }

    @Test("email(from:) trims surrounding whitespace from the parsed address")
    func testEmailTrimsWhitespace() throws {
        // `mailto:%20jane%40example.com%20` — percent-decoded body is
        // ` jane@example.com `; the parser trims back to the bare address.
        let url = try #require(URL(string: "mailto:%20jane%40example.com%20"))
        #expect(EKEventStoreAdapter.email(from: url) == "jane@example.com")
    }
#endif

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
