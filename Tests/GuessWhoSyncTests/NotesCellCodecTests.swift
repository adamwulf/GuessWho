import Foundation
import Testing
@testable import GuessWhoSync

@Suite("NotesCellCodec")
struct NotesCellCodecTests {
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)
    private let t3 = Date(timeIntervalSince1970: 1_700_001_000)
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let idC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    // MARK: - Empty / absent

    @Test
    func decodeOfAbsentFieldReturnsEmpty() {
        #expect(NotesCellCodec.decode(nil) == [])
    }

    @Test
    func encodeCellOfEmptyListReturnsNil() {
        #expect(NotesCellCodec.encodeCell([]) == nil)
    }

    @Test
    func roundTripEmptyList() {
        let cell = NotesCellCodec.encodeCell([])
        #expect(cell == nil)
        // An absent cell decodes to [] — round-trip closed.
        #expect(NotesCellCodec.decode(cell) == [])
    }

    // MARK: - Tombstone-shaped cell (§5.2)

    @Test
    func decodeOfTombstoneCellReturnsEmpty() {
        let cell: SidecarCell = .tombstone(modifiedAt: t1, modifiedBy: "device-A")
        #expect(NotesCellCodec.decode(cell) == [])
    }

    // MARK: - Malformed JSON

    @Test
    func decodeOfMalformedJSONValueReturnsEmpty() {
        let cell: SidecarCell = .value(.string("oops"), modifiedAt: t1, modifiedBy: "device-A")
        #expect(NotesCellCodec.decode(cell) == [])
    }

    @Test
    func decodeOfPartiallyMalformedArrayDropsBadKeepsGood() {
        let goodNote = makeNote(id: idA, modifiedBy: "device-A")
        let goodJSON = encodeNoteAsJSON(goodNote)
        let badJSON: JSONValue = .object([
            // Missing "id"
            "createdAt": .string("2026-06-14T20:15:00.000Z"),
            "modifiedAt": .string("2026-06-14T20:15:00.000Z"),
            "modifiedBy": .string("device-B"),
            "body": .string("orphan"),
            "deleted": .bool(false),
        ])
        let cell: SidecarCell = .value(.array([goodJSON, badJSON]), modifiedAt: t1, modifiedBy: "device-A")
        let decoded = NotesCellCodec.decode(cell)
        #expect(decoded == [goodNote])
    }

    // MARK: - Round-trip

    @Test
    func roundTripAllTombstonesList() {
        let dead1 = ContactNote(
            id: idA,
            createdAt: t1,
            modifiedAt: t2,
            modifiedBy: "device-A",
            body: "",
            deleted: true
        )
        let dead2 = ContactNote(
            id: idB,
            createdAt: t1,
            modifiedAt: t3,
            modifiedBy: "device-B",
            body: "",
            deleted: true
        )
        let cell = NotesCellCodec.encodeCell([dead1, dead2])
        let decoded = NotesCellCodec.decode(cell)
        #expect(Set(decoded) == Set([dead1, dead2]))
    }

    // MARK: - Outer stamp invariant (§12.2)

    @Test
    func encodeCellStampIsMaxAcrossInnerNotes() {
        let n1 = makeNote(id: idA, modifiedAt: t1, modifiedBy: "device-A")
        let n2 = makeNote(id: idB, modifiedAt: t3, modifiedBy: "device-B")
        let n3 = makeNote(id: idC, modifiedAt: t2, modifiedBy: "device-C")
        let cell = try? #require(NotesCellCodec.encodeCell([n1, n2, n3]))
        guard case .value(_, let outerAt, let outerBy) = cell else {
            Issue.record("expected value cell")
            return
        }
        #expect(outerAt == t3)
        #expect(outerBy == "device-B")
    }

    @Test
    func encodeCellStampTiebreaksOnModifiedByWhenModifiedAtEqual() {
        let n1 = makeNote(id: idA, modifiedAt: t2, modifiedBy: "device-A")
        let n2 = makeNote(id: idB, modifiedAt: t2, modifiedBy: "device-C")
        let n3 = makeNote(id: idC, modifiedAt: t2, modifiedBy: "device-B")
        let cell = try? #require(NotesCellCodec.encodeCell([n1, n2, n3]))
        guard case .value(_, let outerAt, let outerBy) = cell else {
            Issue.record("expected value cell")
            return
        }
        #expect(outerAt == t2)
        #expect(outerBy == "device-C")
    }

    // MARK: - Strict ISO8601 output

    @Test
    func encodeValueProducesStrictMillisecondISO8601() throws {
        let note = makeNote(id: idA, modifiedBy: "device-A")
        guard case .array(let elements) = NotesCellCodec.encodeValue([note]),
              let element = elements.first,
              case .object(let fields) = element
        else {
            Issue.record("expected array of objects")
            return
        }
        guard case .string(let createdAtString) = fields["createdAt"] ?? .null,
              case .string(let modifiedAtString) = fields["modifiedAt"] ?? .null
        else {
            Issue.record("expected createdAt and modifiedAt strings")
            return
        }
        // Strict ISO8601 + millisecond + Z form: yyyy-MM-ddTHH:mm:ss.SSSZ
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        #expect(createdAtString.range(of: pattern, options: .regularExpression) != nil)
        #expect(modifiedAtString.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test
    func encodeValueIncludesDeletedFalseExplicitly() throws {
        let note = makeNote(id: idA, modifiedBy: "device-A")
        guard case .array(let elements) = NotesCellCodec.encodeValue([note]),
              let first = elements.first,
              case .object(let fields) = first
        else {
            Issue.record("expected array of objects")
            return
        }
        // §12.5 — `deleted: false` is emitted explicitly so the JSON is self-describing.
        guard case .bool(let deleted) = fields["deleted"] ?? .null else {
            Issue.record("expected explicit deleted: false")
            return
        }
        #expect(deleted == false)
    }

    // MARK: - Permissive date decoding (§12.2)

    @Test
    func decodePermissiveZFormSucceeds() {
        let note = makeNoteJSON(id: idA, createdAt: "2026-06-14T20:15:00.000Z")
        let cell: SidecarCell = .value(.array([note]), modifiedAt: t1, modifiedBy: "device-A")
        #expect(NotesCellCodec.decode(cell).count == 1)
    }

    @Test
    func decodePermissivePlusZeroFormSucceeds() {
        let note = makeNoteJSON(id: idA, createdAt: "2026-06-14T20:15:00.000+00:00")
        let cell: SidecarCell = .value(.array([note]), modifiedAt: t1, modifiedBy: "device-A")
        #expect(NotesCellCodec.decode(cell).count == 1)
    }

    @Test
    func decodePermissiveNoFractionSucceeds() {
        let note = makeNoteJSON(id: idA, createdAt: "2026-06-14T20:15:00Z")
        let cell: SidecarCell = .value(.array([note]), modifiedAt: t1, modifiedBy: "device-A")
        #expect(NotesCellCodec.decode(cell).count == 1)
    }

    @Test
    func decodeUnparseableDateDropsElement() {
        let badDate = makeNoteJSON(id: idA, createdAt: "not-a-date")
        let goodDate = encodeNoteAsJSON(makeNote(id: idB, modifiedBy: "device-B"))
        let cell: SidecarCell = .value(.array([badDate, goodDate]), modifiedAt: t1, modifiedBy: "device-A")
        let decoded = NotesCellCodec.decode(cell)
        #expect(decoded.count == 1)
        #expect(decoded.first?.id == idB)
    }

    // MARK: - Helpers

    private func makeNote(
        id: UUID,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        modifiedBy: String,
        body: String = "hi",
        deleted: Bool = false
    ) -> ContactNote {
        ContactNote(
            id: id,
            createdAt: createdAt ?? t1,
            modifiedAt: modifiedAt ?? t1,
            modifiedBy: modifiedBy,
            body: body,
            deleted: deleted
        )
    }

    private func encodeNoteAsJSON(_ note: ContactNote) -> JSONValue {
        // Round-trip through the codec so the test's "good" JSON matches the
        // codec's emit shape exactly.
        guard case .array(let arr) = NotesCellCodec.encodeValue([note]), let first = arr.first else {
            return .null
        }
        return first
    }

    private func makeNoteJSON(id: UUID, createdAt: String) -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "createdAt": .string(createdAt),
            "modifiedAt": .string(createdAt),
            "modifiedBy": .string("device-X"),
            "body": .string("hi"),
            "deleted": .bool(false),
        ])
    }
}
