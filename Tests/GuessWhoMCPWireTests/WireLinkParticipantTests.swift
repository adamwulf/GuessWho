import XCTest
import GuessWhoMCPWire

/// `WireLink.participants` is an ADDITIVE, optional field: a two-record
/// connection omits it so the payload is byte-identical to the pre-grouping
/// wire, an old payload with no key decodes to `nil`, and a grouped
/// connection round-trips every far record.
final class WireLinkParticipantTests: XCTestCase {

    func testTwoRecordLinkOmitsParticipantsKey() throws {
        let link = WireLink(
            id: "11111111-1111-4111-8111-111111111111",
            kind: "event", otherId: "e-abc", note: "Met here",
            createdAt: "2025-01-01T00:00:00Z")
        let json = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)
        XCTAssertFalse(
            json.contains("participants"),
            "a nil participants field must be omitted, not encoded as null")
    }

    func testOldPayloadWithoutParticipantsDecodesToNil() throws {
        // A payload written before the field existed — no `participants` key.
        let legacy = """
        {"id":"11111111-1111-4111-8111-111111111111","kind":"person",\
        "otherId":"c-jane","note":"College roommate","createdAt":"2025-01-01T00:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(WireLink.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.participants)
        XCTAssertEqual(decoded.kind, "person")
        XCTAssertEqual(decoded.otherId, "c-jane")
    }

    func testExplicitNullParticipantsDecodesToNil() throws {
        let payload = """
        {"id":"11111111-1111-4111-8111-111111111111","kind":"event",\
        "otherId":"e-abc","createdAt":"2025-01-01T00:00:00Z","participants":null}
        """
        let decoded = try JSONDecoder().decode(WireLink.self, from: Data(payload.utf8))
        XCTAssertNil(decoded.participants)
    }

    func testGroupedLinkRoundTripsEveryParticipant() throws {
        let link = WireLink(
            id: "22222222-2222-4222-8222-222222222222",
            kind: "event", otherId: "e-gala", note: nil,
            createdAt: "2025-02-02T00:00:00Z",
            participants: [
                WireLinkParticipant(kind: "event", otherId: "e-gala"),
                WireLinkParticipant(kind: "place", otherId: "p-cafe"),
                WireLinkParticipant(kind: "person", otherId: "c-jane"),
            ])
        let encoded = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(WireLink.self, from: encoded)
        XCTAssertEqual(decoded.kind, "event")
        XCTAssertEqual(decoded.otherId, "e-gala")
        XCTAssertEqual(
            decoded.participants?.map { [$0.kind, $0.otherId] },
            [["event", "e-gala"], ["place", "p-cafe"], ["person", "c-jane"]],
            "participant order is preserved on the wire")
    }
}
