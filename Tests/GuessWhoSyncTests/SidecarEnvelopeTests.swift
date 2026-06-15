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
              "value": "Snuggles",
              "modifiedAt": "2026-06-13T10:00:00.000Z",
              "modifiedBy": "device-A",
              "deletedAt": "2026-06-13T10:00:00.000Z"
            }
          }
        }
        """#
        let env = try decoder.decode(SidecarEnvelope.self, from: json.data(using: .utf8)!)
        #expect(env.schemaVersion == 1)
        #expect(env.entityID == "550e8400-e29b-41d4-a716-446655440000")
        #expect(env.fields.count == 3)

        let nick = try #require(env.fields["nickname"])
        #expect(nick.value == .string("Bear"))
        #expect(nick.modifiedBy == "device-A")
        #expect(nick.deletedAt == nil)

        let notes = try #require(env.fields["notes"])
        #expect(notes.value == .string("Met at WWDC"))
        #expect(notes.modifiedBy == "device-B")
        #expect(notes.deletedAt == nil)

        let pet = try #require(env.fields["petName"])
        #expect(pet.deletedAt != nil)
        #expect(pet.value == .string("Snuggles"))
    }

    @Test
    func roundtripsMixedFields() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000.000)
        let env = SidecarEnvelope(
            entityID: "abc",
            fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: when, modifiedBy: "device-A"),
                "petName": SidecarCell(value: .string("old"), modifiedAt: when, modifiedBy: "device-A", deletedAt: when),
                "age": SidecarCell(value: .number(7), modifiedAt: when, modifiedBy: "device-B"),
            ]
        )
        let data = try encoder.encode(env)
        let decoded = try decoder.decode(SidecarEnvelope.self, from: data)
        #expect(decoded.entityID == "abc")
        #expect(decoded.fields.count == 3)
        #expect(decoded.schemaVersion == 1)

        let nick = try #require(decoded.fields["nickname"])
        #expect(nick.value == .string("Bear"))
        #expect(nick.deletedAt == nil)

        let age = try #require(decoded.fields["age"])
        #expect(age.value == .number(7))

        let pet = try #require(decoded.fields["petName"])
        #expect(pet.deletedAt != nil)
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
