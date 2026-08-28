import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Proves the sidecar forward-compatibility contract directly: a cell whose
/// inner `type` string this build does not know is HIDDEN from the decoded
/// field list but PRESERVED verbatim in storage — it survives the store's
/// read-modify-write and a whole-cell merge. If a future change breaks a leg of
/// the contract (rebuilds the envelope from decoded fields, drops undecodable
/// cells, or decode-then-remerges), one of these tests fails.
///
/// The contract and its rules live in `docs/sidecar-compatibility.md`.
@Suite("Sidecar forward-compatibility: unknown-typed cells survive")
struct SidecarForwardCompatTests {
    private func makeSync(_ sidecars: InMemorySidecarStore, deviceID: String = "device-A") -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: deviceID
        )
    }

    private let key = SidecarKey(kind: .contact, id: "11111111-1111-1111-1111-111111111111")
    private let unknownID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!

    /// An inner-value object shaped exactly like a real field cell, but with a
    /// `type` string no `SidecarFieldType` case defines — i.e. a field a newer
    /// build would write. Built by hand because the typed API (`addField`)
    /// validates the type and would reject it.
    private func unknownInner(url: String, at stamp: Date) -> JSONValue {
        .object([
            SidecarField.innerFieldKey: .string("source"),
            SidecarField.innerTypeKey: .string("url_from_the_future"),
            SidecarField.innerValueKey: .string(url),
            SidecarField.innerCreatedAtKey: .string(SidecarISO8601.string(from: stamp)),
        ])
    }

    @Test
    func unknownTypedCellIsHiddenFromDecodedListButPreservedAcrossAWrite() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let seededValue = unknownInner(url: "https://example.com/x", at: stamp)

        // Seed an unknown-typed cell directly into the store.
        try sidecars.write(
            SidecarEnvelope(entityID: key.id, fields: [
                unknownID.uuidString: SidecarCell(
                    value: seededValue, modifiedAt: stamp, modifiedBy: "future-device"),
            ]),
            at: key
        )

        // DISPLAY leg: the decoded list omits it (SidecarField.decode -> nil).
        #expect(try sync.fields(at: key).contains { $0.id == unknownID } == false)

        // This build now writes its OWN, known field on the same entity. The
        // mutation is a read-modify-write of the whole raw cell map.
        let knownID = try sync.addField(at: key, field: "note", type: .note, value: .string("hi"))

        // The known field is visible; the unknown one is still hidden.
        let visible = try sync.fields(at: key)
        #expect(visible.contains { $0.id == knownID })
        #expect(visible.contains { $0.id == unknownID } == false)

        // STORAGE leg: the unknown cell is still in the raw envelope, byte for
        // byte — value, author, and undeleted state all intact.
        let raw = try #require(try sidecars.read(key))
        let preserved = try #require(raw.fields[unknownID.uuidString])
        #expect(preserved.value == seededValue)
        #expect(preserved.modifiedBy == "future-device")
        #expect(preserved.deletedAt == nil)
    }

    @Test
    func unknownTypedCellSurvivesWholeCellMerge() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let unknownValue = unknownInner(url: "https://example.com/y", at: stamp)

        // Envelope A carries the unknown cell; B carries only a known cell.
        let a = SidecarEnvelope(entityID: key.id, fields: [
            unknownID.uuidString: SidecarCell(
                value: unknownValue, modifiedAt: stamp, modifiedBy: "future-device"),
        ])
        let knownID = UUID().uuidString
        let b = SidecarEnvelope(entityID: key.id, fields: [
            knownID: SidecarCell(
                value: SidecarField.makeInnerValue(
                    field: "note", type: .note, value: .string("hi"), createdAt: stamp),
                modifiedAt: stamp, modifiedBy: "device-A"),
        ])

        // MERGE leg: whole-cell union keeps the unknown cell untouched.
        let merged = try merge(a, b).get()
        #expect(merged.fields[unknownID.uuidString]?.value == unknownValue)
        #expect(merged.fields[unknownID.uuidString]?.modifiedBy == "future-device")
        #expect(merged.fields[knownID] != nil)
    }
}
