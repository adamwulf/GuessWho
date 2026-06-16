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
