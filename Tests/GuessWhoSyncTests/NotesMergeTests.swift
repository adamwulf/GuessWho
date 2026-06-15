import Foundation
import Testing
@testable import GuessWhoSync

@Suite("NotesMerge")
struct NotesMergeTests {
    private let entityID = "550e8400-e29b-41d4-a716-446655440000"
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)
    private let t3 = Date(timeIntervalSince1970: 1_700_001_000)
    private let idX = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let idY = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let idZ = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    // MARK: - Same ID, both sides

    @Test
    func sameIDBothSidesLargerStampWins() throws {
        let older = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "old")
        let newer = makeNote(id: idX, modifiedAt: t2, modifiedBy: "device-A", body: "new")
        let merged = try mergeNotes([older], [newer])
        #expect(merged.count == 1)
        #expect(merged.first?.body == "new")
        #expect(merged.first?.modifiedAt == t2)
    }

    @Test
    func sameIDIdenticalModifiedAtModifiedByLexTiebreak() throws {
        let fromA = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "from-A")
        let fromB = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-B", body: "from-B")
        let merged = try mergeNotes([fromA], [fromB])
        #expect(merged.count == 1)
        // Lex-larger modifiedBy wins.
        #expect(merged.first?.body == "from-B")

        // Commutative.
        let mergedBA = try mergeNotes([fromB], [fromA])
        #expect(mergedBA == merged)
    }

    // MARK: - Parallel creates

    @Test
    func parallelCreatesBothSurvive() throws {
        let x = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "X")
        let y = makeNote(id: idY, modifiedAt: t1, modifiedBy: "device-B", body: "Y")
        let merged = try mergeNotes([x], [y])
        #expect(Set(merged) == Set([x, y]))
    }

    // MARK: - Edit vs delete

    @Test
    func editVsDeleteSameIDDifferentStampsNewerWins() throws {
        let edit = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "edited")
        let delete = makeNote(id: idX, modifiedAt: t2, modifiedBy: "device-B", body: "", deleted: true)
        let merged = try mergeNotes([edit], [delete])
        #expect(merged.count == 1)
        #expect(merged.first?.deleted == true)
    }

    @Test
    func editVsDeleteIdenticalModifiedAtModifiedByTiebreak() throws {
        let edit = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "edited")
        let delete = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-B", body: "", deleted: true)
        let merged = try mergeNotes([edit], [delete])
        #expect(merged.count == 1)
        // device-B > device-A lexicographically.
        #expect(merged.first?.deleted == true)
    }

    @Test
    func tombstoneVsOlderEditSameIDTombstoneWins() throws {
        let edit = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "old edit")
        let tomb = makeNote(id: idX, modifiedAt: t2, modifiedBy: "device-A", body: "", deleted: true)
        let merged = try mergeNotes([edit], [tomb])
        #expect(merged.count == 1)
        #expect(merged.first?.deleted == true)
        #expect(merged.first?.modifiedAt == t2)
    }

    @Test
    func twoTombstonesSameIDLargerStampWins() throws {
        let tombOld = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "", deleted: true)
        let tombNew = makeNote(id: idX, modifiedAt: t2, modifiedBy: "device-B", body: "", deleted: true)
        let merged = try mergeNotes([tombOld], [tombNew])
        #expect(merged.count == 1)
        #expect(merged.first?.modifiedAt == t2)
        #expect(merged.first?.modifiedBy == "device-B")
    }

    // MARK: - One-sided pass-through (no codec round-trip)

    @Test
    func onlyOneSideHasNotesResultEqualsThatSideVerbatim() throws {
        let n = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "hi")
        let aCell = try #require(NotesCellCodec.encodeCell([n]))
        let a = envelope(fields: ["notes": aCell])
        let b = envelope(fields: ["nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-B")])

        let merged = try merge(a, b).get()
        // Byte-equal: the SidecarCell from `a` survives unchanged.
        try assertCellEqual(merged.fields["notes"], aCell)
    }

    @Test
    func onlyOneSideHasMalformedNotesCellPassesThroughVerbatim() throws {
        // §12.3 override: a malformed one-sided "notes" cell is preserved
        // verbatim, NOT round-tripped through the codec.
        let malformed: SidecarCell = .value(.string("oops"), modifiedAt: t1, modifiedBy: "device-A")
        let a = envelope(fields: ["notes": malformed])
        let b = envelope(fields: ["nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-B")])

        let merged = try merge(a, b).get()
        try assertCellEqual(merged.fields["notes"], malformed)
    }

    // MARK: - Empty / both malformed

    @Test
    func bothSidesMalformedNotesCellsResultOmitsNotesKey() throws {
        // §5.2 tombstone cells aren't a notes-list shape — the codec treats
        // them as []. Both sides → empty merged list → "notes" omitted.
        let a = envelope(fields: ["notes": .tombstone(modifiedAt: t1, modifiedBy: "device-A")])
        let b = envelope(fields: ["notes": .value(.string("garbage"), modifiedAt: t2, modifiedBy: "device-B")])

        let merged = try merge(a, b).get()
        #expect(merged.fields["notes"] == nil)
    }

    @Test
    func mergeResultingInEmptyListOmitsNotesKey() throws {
        // Construct an unrealistic but explicit case: both sides have a cell
        // that decodes to [] (e.g. an empty array). The merge produces an
        // empty union → the key drops out per §12.3 step 4.
        let emptyArrayCell: SidecarCell = .value(.array([]), modifiedAt: t1, modifiedBy: "device-A")
        let otherEmptyCell: SidecarCell = .value(.array([]), modifiedAt: t2, modifiedBy: "device-B")
        let a = envelope(fields: ["notes": emptyArrayCell])
        let b = envelope(fields: ["notes": otherEmptyCell])

        let merged = try merge(a, b).get()
        #expect(merged.fields["notes"] == nil)
    }

    // MARK: - Outer-cell stamp invariant

    @Test
    func outerStampEqualsMaxAcrossAllMergedNotesIncludingTombstones() throws {
        let live = makeNote(id: idX, modifiedAt: t1, modifiedBy: "device-A", body: "x")
        let tomb = makeNote(id: idY, modifiedAt: t3, modifiedBy: "device-B", body: "", deleted: true)
        let other = makeNote(id: idZ, modifiedAt: t2, modifiedBy: "device-C", body: "z")

        let a = envelope(fields: ["notes": try #require(NotesCellCodec.encodeCell([live, other]))])
        let b = envelope(fields: ["notes": try #require(NotesCellCodec.encodeCell([tomb]))])

        let merged = try merge(a, b).get()
        guard case .value(_, let outerAt, let outerBy) = merged.fields["notes"] else {
            Issue.record("expected value cell")
            return
        }
        #expect(outerAt == t3)
        #expect(outerBy == "device-B")
    }

    // MARK: - Commutativity / associativity over randomized 3-note lists

    @Test
    func commutativityAndAssociativityAcrossRandomized3NoteLists() throws {
        // Seeded so the test is deterministic across runs / machines.
        var rng = LinearCongruentialRNG(seed: 0xC0FFEE as UInt64)
        for trial in 0..<32 {
            let listA = randomNotes(count: 3, &rng)
            let listB = randomNotes(count: 3, &rng)
            let listC = randomNotes(count: 3, &rng)

            let cellA = NotesCellCodec.encodeCell(listA)
            let cellB = NotesCellCodec.encodeCell(listB)
            let cellC = NotesCellCodec.encodeCell(listC)

            let a = envelope(fields: cellA.map { ["notes": $0] } ?? [:])
            let b = envelope(fields: cellB.map { ["notes": $0] } ?? [:])
            let c = envelope(fields: cellC.map { ["notes": $0] } ?? [:])

            let ab = try merge(a, b).get()
            let ba = try merge(b, a).get()
            try assertCellEqual(ab.fields["notes"], ba.fields["notes"], note: "commutativity trial \(trial)")

            let leftFold = try merge(merge(a, b).get(), c).get()
            let rightFold = try merge(a, merge(b, c).get()).get()
            try assertCellEqual(leftFold.fields["notes"], rightFold.fields["notes"], note: "associativity trial \(trial)")
        }
    }

    // MARK: - Cell equality helper

    private func assertCellEqual(
        _ x: SidecarCell?,
        _ y: SidecarCell?,
        note: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        switch (x, y) {
        case (nil, nil):
            return
        case (let .some(xx), let .some(yy)):
            switch (xx, yy) {
            case (.value(let xv, let xt, let xb), .value(let yv, let yt, let yb)):
                #expect(xv == yv, "value mismatch \(note)", sourceLocation: sourceLocation)
                #expect(xt == yt, "modifiedAt mismatch \(note)", sourceLocation: sourceLocation)
                #expect(xb == yb, "modifiedBy mismatch \(note)", sourceLocation: sourceLocation)
            case (.tombstone(let xt, let xb), .tombstone(let yt, let yb)):
                #expect(xt == yt, "tombstone modifiedAt mismatch \(note)", sourceLocation: sourceLocation)
                #expect(xb == yb, "tombstone modifiedBy mismatch \(note)", sourceLocation: sourceLocation)
            default:
                Issue.record("cells differ in kind: \(xx) vs \(yy) \(note)", sourceLocation: sourceLocation)
            }
        default:
            Issue.record("nil/non-nil mismatch: \(String(describing: x)) vs \(String(describing: y)) \(note)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Helpers

    private func makeNote(
        id: UUID,
        modifiedAt: Date,
        modifiedBy: String,
        body: String,
        deleted: Bool = false
    ) -> ContactNote {
        // createdAt is fixed across all helper notes to keep tests focused on
        // modifiedAt/modifiedBy. modifiedAt floors at createdAt.
        ContactNote(
            id: id,
            createdAt: t1,
            modifiedAt: modifiedAt,
            modifiedBy: modifiedBy,
            body: body,
            deleted: deleted
        )
    }

    private func envelope(fields: [String: SidecarCell]) -> SidecarEnvelope {
        SidecarEnvelope(schemaVersion: 1, entityID: entityID, fields: fields)
    }

    private func mergeNotes(_ a: [ContactNote], _ b: [ContactNote]) throws -> [ContactNote] {
        let envA = envelope(fields: NotesCellCodec.encodeCell(a).map { ["notes": $0] } ?? [:])
        let envB = envelope(fields: NotesCellCodec.encodeCell(b).map { ["notes": $0] } ?? [:])
        let merged = try merge(envA, envB).get()
        return NotesCellCodec.decode(merged.fields["notes"])
    }

    private func randomNotes(count: Int, _ rng: inout LinearCongruentialRNG) -> [ContactNote] {
        let pool: [UUID] = [idX, idY, idZ]
        let writers = ["device-A", "device-B", "device-C"]
        let times = [t1, t2, t3]
        var out: [ContactNote] = []
        for _ in 0..<count {
            let id = pool[Int(rng.next() % UInt64(pool.count))]
            let modAt = times[Int(rng.next() % UInt64(times.count))]
            let by = writers[Int(rng.next() % UInt64(writers.count))]
            let isDel = rng.next() % 4 == 0
            let body = isDel ? "" : "body-\(rng.next() % 1000)"
            out.append(ContactNote(
                id: id,
                createdAt: t1,
                modifiedAt: modAt,
                modifiedBy: by,
                body: body,
                deleted: isDel
            ))
        }
        return out
    }
}

// Deterministic seeded RNG so the randomized property test produces the same
// sequence on every machine. Knuth's LCG parameters; quality is fine for
// shuffling 3-note lists.
struct LinearCongruentialRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
