import Foundation
import Testing
@testable import GuessWhoSync

/// §5.3 malformed-input handling: a single malformed cell is treated as
/// absent — the rest of the envelope still decodes. This used to silently
/// poison the whole envelope on auto-derived Codable.
@Suite("Envelope defensive decode")
struct EnvelopeDefensiveDecodeTests {
    private let decoder = JSONDecoder()

    @Test
    func envelopeWithOneMalformedCellDropsItButKeepsOthers() throws {
        // good cell + bad cell (malformed modifiedAt) + another good cell.
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": {
            "good1": {
              "value": "alive",
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A"
            },
            "bad": {
              "value": "x",
              "modifiedAt": "not-an-iso-date",
              "modifiedBy": "device-B"
            },
            "good2": {
              "value": "also alive",
              "modifiedAt": "2026-06-14T21:00:00.000Z",
              "modifiedBy": "device-C"
            }
          }
        }
        """#
        let env = try decoder.decode(SidecarEnvelope.self, from: json.data(using: .utf8)!)
        #expect(env.fields.keys.sorted() == ["good1", "good2"])
        let g1 = try #require(env.fields["good1"])
        #expect(g1.value == .string("alive"))
    }

    @Test
    func envelopeWithMalformedDeletedAtCellDropsThatCellOnly() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": {
            "ok": {
              "value": "v",
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A"
            },
            "badDeleted": {
              "value": "x",
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A",
              "deletedAt": "bogus"
            }
          }
        }
        """#
        let env = try decoder.decode(SidecarEnvelope.self, from: json.data(using: .utf8)!)
        #expect(env.fields.keys.sorted() == ["ok"])
    }

    @Test
    func envelopeWithMissingValueKeyOnOneCellDropsThatCellOnly() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": {
            "ok": {
              "value": "v",
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A"
            },
            "noValue": {
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A"
            }
          }
        }
        """#
        let env = try decoder.decode(SidecarEnvelope.self, from: json.data(using: .utf8)!)
        #expect(env.fields.keys.sorted() == ["ok"])
    }

    @Test
    func droppedCellCountIsExposed() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": {
            "ok": {
              "value": "v",
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A"
            },
            "bad1": { "value": "x", "modifiedAt": "nope", "modifiedBy": "d" },
            "bad2": { "modifiedAt": "2026-06-14T20:15:00.000Z", "modifiedBy": "d" }
          }
        }
        """#
        let env = try decoder.decode(SidecarEnvelope.self, from: json.data(using: .utf8)!)
        #expect(env.cellsDroppedOnDecode == 2)
        #expect(env.fields.count == 1)
    }

    @Test
    func freshlyConstructedEnvelopeReportsZeroDroppedCells() {
        let env = SidecarEnvelope(entityID: "x", fields: [
            "a": SidecarCell(value: .string("y"), modifiedAt: Date(), modifiedBy: "d")
        ])
        #expect(env.cellsDroppedOnDecode == 0)
    }

    @Test
    func envelopeWithMalformedFieldsKeyCountsAsOneDrop() throws {
        // `fields` is present but not a JSON object — a structurally broken
        // envelope at the top level. The decoder must NOT silently treat this
        // as a legitimate zero-fields envelope (would let merge() overwrite
        // it with a clean shape and lose the evidence of corruption).
        let nullFields = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": null
        }
        """#
        let envNull = try decoder.decode(SidecarEnvelope.self, from: nullFields.data(using: .utf8)!)
        #expect(envNull.fields.isEmpty)
        #expect(envNull.cellsDroppedOnDecode == 1)

        let scalarFields = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": 42
        }
        """#
        let envScalar = try decoder.decode(SidecarEnvelope.self, from: scalarFields.data(using: .utf8)!)
        #expect(envScalar.fields.isEmpty)
        #expect(envScalar.cellsDroppedOnDecode == 1)

        // An absent `fields` key is a legitimate zero-fields envelope.
        let noFields = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000"
        }
        """#
        let envNone = try decoder.decode(SidecarEnvelope.self, from: noFields.data(using: .utf8)!)
        #expect(envNone.fields.isEmpty)
        #expect(envNone.cellsDroppedOnDecode == 0)
    }

    @Test
    func envelopeWithAllCellsMalformedDecodesAsEmptyFields() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": {
            "a": { "value": "x", "modifiedAt": "nope", "modifiedBy": "d" },
            "b": { "modifiedAt": "2026-06-14T20:15:00.000Z", "modifiedBy": "d" }
          }
        }
        """#
        let env = try decoder.decode(SidecarEnvelope.self, from: json.data(using: .utf8)!)
        #expect(env.entityID == "550e8400-e29b-41d4-a716-446655440000")
        #expect(env.fields.isEmpty)
    }
}
