import Foundation
import Testing
@testable import GuessWhoSync

@Suite("SidecarEnvelope")
struct SidecarEnvelopeTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test
    func defaultsSchemaVersionToOne() {
        let env = SidecarEnvelope(entityID: "id-1", fields: [:])
        #expect(env.schemaVersion == 1)
    }

    @Test
    func roundtripsEmptyEnvelope() throws {
        let env = SidecarEnvelope(entityID: "id-1", fields: [:])
        let data = try encoder.encode(env)
        let decoded = try decoder.decode(SidecarEnvelope.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.entityID == "id-1")
        #expect(decoded.fields.isEmpty)
    }

    @Test
    func decodesSpecExampleEnvelope() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "550e8400-e29b-41d4-a716-446655440000",
          "fields": {
            "nickname": {
              "value": "Bear",
              "modifiedAt": "2026-06-14T20:15:00.000Z",
              "modifiedBy": "device-A"
            },
            "notes": {
              "value": "Met at WWDC",
              "modifiedAt": "2026-06-14T22:00:00.000Z",
              "modifiedBy": "device-B"
            },
            "petName": {
              "deleted": true,
              "modifiedAt": "2026-06-13T10:00:00.000Z",
              "modifiedBy": "device-A"
            }
          }
        }
        """#
        let data = json.data(using: .utf8)!
        let env = try decoder.decode(SidecarEnvelope.self, from: data)
        #expect(env.schemaVersion == 1)
        #expect(env.entityID == "550e8400-e29b-41d4-a716-446655440000")
        #expect(env.fields.count == 3)

        guard case .value(let nick, _, let nickBy) = env.fields["nickname"] else {
            Issue.record("nickname should be a value cell")
            return
        }
        #expect(nick == .string("Bear"))
        #expect(nickBy == "device-A")

        guard case .value(let notes, _, let notesBy) = env.fields["notes"] else {
            Issue.record("notes should be a value cell")
            return
        }
        #expect(notes == .string("Met at WWDC"))
        #expect(notesBy == "device-B")

        guard case .tombstone(_, let petBy) = env.fields["petName"] else {
            Issue.record("petName should be a tombstone")
            return
        }
        #expect(petBy == "device-A")
    }

    @Test
    func roundtripsMixedFields() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000.000)
        let env = SidecarEnvelope(
            entityID: "abc",
            fields: [
                "nickname": .value(.string("Bear"), modifiedAt: when, modifiedBy: "device-A"),
                "petName": .tombstone(modifiedAt: when, modifiedBy: "device-A"),
                "age": .value(.number(7), modifiedAt: when, modifiedBy: "device-B"),
            ]
        )
        let data = try encoder.encode(env)
        let decoded = try decoder.decode(SidecarEnvelope.self, from: data)
        #expect(decoded.entityID == "abc")
        #expect(decoded.fields.count == 3)
        #expect(decoded.schemaVersion == 1)

        if case .value(let v, _, _) = decoded.fields["nickname"] {
            #expect(v == .string("Bear"))
        } else {
            Issue.record("nickname missing or wrong shape")
        }
        if case .value(let v, _, _) = decoded.fields["age"] {
            #expect(v == .number(7))
        } else {
            Issue.record("age missing or wrong shape")
        }
        if case .tombstone = decoded.fields["petName"] {
            // expected
        } else {
            Issue.record("petName missing or wrong shape")
        }
    }

    @Test
    func encodesNoKindField() throws {
        let env = SidecarEnvelope(entityID: "id-1", fields: [:])
        let data = try encoder.encode(env)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["kind"] == nil)
        #expect(object?["schemaVersion"] as? Int == 1)
        #expect(object?["entityID"] as? String == "id-1")
    }
}
