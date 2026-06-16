import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("SidecarField (field-instance API)")
struct SidecarFieldTests {
    private func makeOrchestrator() -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")
        return (sync, sidecars)
    }

    private let contactKey = SidecarKey(kind: .contact, id: "11111111-1111-1111-1111-111111111111")

    // MARK: - Notes (.note type)

    @Test
    func addFieldNoteRoundTrip() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "general notes", type: .note, value: .string("Met at WWDC"))
        let f = try #require(try sync.field(at: contactKey, id: id))
        #expect(f.id == id)
        #expect(f.type == .note)
        #expect(f.value == .string("Met at WWDC"))
        #expect(f.field == "general notes")
        #expect(f.deletedAt == nil)
        #expect(f.createdAt != nil)
    }

    @Test
    func setFieldPreservesCreatedAt() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "notes", type: .note, value: .string("v1"))
        let first = try #require(try sync.field(at: contactKey, id: id))
        Thread.sleep(forTimeInterval: 0.01)
        try sync.setField(at: contactKey, id: id, field: "notes", value: .string("v2"))
        let second = try #require(try sync.field(at: contactKey, id: id))
        #expect(second.value == .string("v2"))
        #expect(second.modifiedAt > first.modifiedAt)
        #expect(second.createdAt == first.createdAt)
    }

    @Test
    func deleteFieldSetsDeletedAt() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "n", type: .note, value: .string("x"))
        try sync.deleteField(at: contactKey, id: id)
        let f = try #require(try sync.field(at: contactKey, id: id))
        #expect(f.deletedAt != nil)
        #expect(f.value == .string("x")) // preserved per Core Semantics
    }

    @Test
    func setFieldOnSoftDeletedCellUndeletes() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "n", type: .note, value: .string("v1"))
        try sync.deleteField(at: contactKey, id: id)
        try sync.setField(at: contactKey, id: id, field: "n", value: .string("v2"))
        let f = try #require(try sync.field(at: contactKey, id: id))
        #expect(f.deletedAt == nil)
        #expect(f.value == .string("v2"))
    }

    @Test
    func setFieldOnMissingCellIsSilentNoOp() throws {
        let (sync, sidecars) = makeOrchestrator()
        try sync.setField(at: contactKey, id: UUID(), field: "n", value: .string("x"))
        #expect(try sidecars.read(contactKey) == nil)
    }

    @Test
    func deleteFieldOnMissingCellIsSilentNoOp() throws {
        let (sync, sidecars) = makeOrchestrator()
        try sync.deleteField(at: contactKey, id: UUID())
        #expect(try sidecars.read(contactKey) == nil)
    }

    @Test
    func deleteFieldOnAlreadyDeletedIsNoOp() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "n", type: .note, value: .string("x"))
        try sync.deleteField(at: contactKey, id: id)
        let first = try #require(try sync.field(at: contactKey, id: id))
        try sync.deleteField(at: contactKey, id: id)
        let second = try #require(try sync.field(at: contactKey, id: id))
        #expect(first.modifiedAt == second.modifiedAt)
        #expect(first.deletedAt == second.deletedAt)
    }

    @Test
    func parallelAddFieldCreatesTwoDistinctInstances() throws {
        let (sync, _) = makeOrchestrator()
        let a = try sync.addField(at: contactKey, field: "notes", type: .note, value: .string("A"))
        let b = try sync.addField(at: contactKey, field: "notes", type: .note, value: .string("B"))
        #expect(a != b)
        let all = try sync.fields(at: contactKey)
        #expect(all.count == 2)
        let bodies = Set(all.compactMap { f -> String? in
            if case .string(let s) = f.value { return s } else { return nil }
        })
        #expect(bodies == Set(["A", "B"]))
    }

    @Test
    func fieldsReturnsDecodedFieldsInUnspecifiedOrder() throws {
        let (sync, _) = makeOrchestrator()
        _ = try sync.addField(at: contactKey, field: "a", type: .note, value: .string("1"))
        _ = try sync.addField(at: contactKey, field: "b", type: .note, value: .string("2"))
        let result = try sync.fields(at: contactKey)
        #expect(result.count == 2)
    }

    @Test
    func fieldsReturnsSoftDeletedFields() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "n", type: .note, value: .string("x"))
        try sync.deleteField(at: contactKey, id: id)
        let all = try sync.fields(at: contactKey)
        #expect(all.count == 1)
        #expect(all[0].deletedAt != nil)
    }

    // MARK: - Type immutability + validation

    @Test
    func addFieldNoteRejectsNonStringValue() {
        let (sync, _) = makeOrchestrator()
        #expect(throws: SidecarStoreError.self) {
            try sync.addField(at: contactKey, field: "n", type: .note, value: .bool(true))
        }
    }

    @Test
    func addFieldCheckboxRejectsNonBoolValue() {
        let (sync, _) = makeOrchestrator()
        #expect(throws: SidecarStoreError.self) {
            try sync.addField(at: contactKey, field: "c", type: .checkbox, value: .string("yes"))
        }
    }

    @Test
    func addFieldDateRejectsMalformedISO8601() {
        let (sync, _) = makeOrchestrator()
        #expect(throws: SidecarStoreError.self) {
            try sync.addField(at: contactKey, field: "d", type: .date, value: .string("not-a-date"))
        }
    }

    @Test
    func addFieldCheckboxAcceptsBool() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "c", type: .checkbox, value: .bool(true))
        let f = try #require(try sync.field(at: contactKey, id: id))
        #expect(f.type == .checkbox)
        #expect(f.value == .bool(true))
    }

    @Test
    func addFieldDateAcceptsValidISO8601() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "d", type: .date, value: .string("2024-09-15T00:00:00.000Z"))
        let f = try #require(try sync.field(at: contactKey, id: id))
        #expect(f.type == .date)
    }

    @Test
    func setFieldRejectsTypeMismatch() throws {
        let (sync, _) = makeOrchestrator()
        let id = try sync.addField(at: contactKey, field: "n", type: .note, value: .string("x"))
        #expect(throws: SidecarStoreError.self) {
            try sync.setField(at: contactKey, id: id, field: "n", value: .bool(true))
        }
    }

    // MARK: - Forward compatibility

    @Test
    func fieldsOmitsCellsWithUnknownType() throws {
        let (sync, sidecars) = makeOrchestrator()
        let id = UUID()
        // Hand-construct a cell whose inner type is a string this version
        // doesn't know about. fields(at:) must omit it; raw envelope keeps it.
        let inner: JSONValue = .object([
            "field": .string("future"),
            "type": .string("hyperlink"),
            "value": .string("https://example.com"),
        ])
        let cell = SidecarCell(value: inner, modifiedAt: Date(), modifiedBy: "device-A")
        try sidecars.write(
            SidecarEnvelope(entityID: contactKey.id, fields: [id.uuidString: cell]),
            at: contactKey
        )
        let decoded = try sync.fields(at: contactKey)
        #expect(decoded.isEmpty)
        #expect(try sync.field(at: contactKey, id: id) == nil)
        // Raw envelope still carries the cell.
        let env = try #require(try sync.sidecar(at: contactKey))
        #expect(env.fields.count == 1)
    }
}
