import Foundation
import Testing
@testable import GuessWhoSync

@Suite("JSONValue")
struct JSONValueTests {
    private func roundtrip(_ value: JSONValue) throws -> JSONValue {
        // Wrap in an array so the top level is unambiguous to JSONEncoder
        // (which can't encode a single null/scalar without a fragment policy).
        let data = try JSONEncoder().encode([value])
        let decoded = try JSONDecoder().decode([JSONValue].self, from: data)
        return decoded[0]
    }

    @Test
    func nullRoundtrips() throws {
        let result = try roundtrip(.null)
        #expect(result == .null)
    }

    @Test
    func boolRoundtrips() throws {
        #expect(try roundtrip(.bool(true)) == .bool(true))
        #expect(try roundtrip(.bool(false)) == .bool(false))
    }

    @Test
    func numberRoundtrips() throws {
        #expect(try roundtrip(.number(42)) == .number(42))
        #expect(try roundtrip(.number(-3.14)) == .number(-3.14))
        #expect(try roundtrip(.number(0)) == .number(0))
    }

    @Test
    func stringRoundtrips() throws {
        #expect(try roundtrip(.string("")) == .string(""))
        #expect(try roundtrip(.string("hello")) == .string("hello"))
        #expect(try roundtrip(.string("with \"quotes\" and \\slashes")) ==
                .string("with \"quotes\" and \\slashes"))
    }

    @Test
    func arrayRoundtrips() throws {
        let value: JSONValue = .array([.number(1), .string("two"), .null, .bool(true)])
        let result = try roundtrip(value)
        #expect(result == value)
    }

    @Test
    func objectRoundtrips() throws {
        let value: JSONValue = .object([
            "name": .string("Bear"),
            "age": .number(7),
            "active": .bool(true),
            "missing": .null,
        ])
        let result = try roundtrip(value)
        #expect(result == value)
    }

    @Test
    func nestedRoundtrips() throws {
        let value: JSONValue = .object([
            "tags": .array([.string("friend"), .string("colleague")]),
            "address": .object([
                "city": .string("Austin"),
                "zip": .number(78701),
            ]),
            "notes": .null,
        ])
        let result = try roundtrip(value)
        #expect(result == value)
    }

    @Test
    func decodesRawJSON() throws {
        let json = #"""
        {"k":[1,"two",null,{"nested":true}]}
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let expected: JSONValue = .object([
            "k": .array([
                .number(1),
                .string("two"),
                .null,
                .object(["nested": .bool(true)]),
            ]),
        ])
        #expect(decoded == expected)
    }
}
