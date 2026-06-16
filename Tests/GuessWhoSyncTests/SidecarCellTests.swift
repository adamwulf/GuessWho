import Foundation
import Testing
@testable import GuessWhoSync

@Suite("SidecarCell")
struct SidecarCellTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test
    func liveCellRoundtrips() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000.123)
        let cell = SidecarCell(value: .string("Bear"), modifiedAt: when, modifiedBy: "device-A")
        let data = try encoder.encode(cell)
        let decoded = try decoder.decode(SidecarCell.self, from: data)
        #expect(decoded.value == .string("Bear"))
        #expect(decoded.modifiedBy == "device-A")
        #expect(decoded.modifiedAt.timeIntervalSince1970 == when.timeIntervalSince1970)
        #expect(decoded.deletedAt == nil)
    }

    @Test
    func deletedCellRoundtripsPreservingValue() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_500.456)
        let cell = SidecarCell(
            value: .string("what was here"),
            modifiedAt: when,
            modifiedBy: "device-B",
            deletedAt: when
        )
        let data = try encoder.encode(cell)
        let decoded = try decoder.decode(SidecarCell.self, from: data)
        #expect(decoded.value == .string("what was here"))
        #expect(decoded.modifiedBy == "device-B")
        #expect(decoded.modifiedAt.timeIntervalSince1970 == when.timeIntervalSince1970)
        #expect(decoded.deletedAt?.timeIntervalSince1970 == when.timeIntervalSince1970)
    }

    @Test
    func absentDeletedAtMeansLive() throws {
        let json = #"""
        {"value":"x","modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        let cell = try decoder.decode(SidecarCell.self, from: json.data(using: .utf8)!)
        #expect(cell.deletedAt == nil)
    }

    @Test
    func presentDeletedAtMeansDeleted() throws {
        let json = #"""
        {"value":"x","modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A","deletedAt":"2026-06-14T22:00:00.000Z"}
        """#
        let cell = try decoder.decode(SidecarCell.self, from: json.data(using: .utf8)!)
        #expect(cell.deletedAt != nil)
    }

    @Test
    func decodingMalformedModifiedAtThrows() {
        let json = #"""
        {"value":"x","modifiedAt":"not-a-date","modifiedBy":"device-A"}
        """#
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: json.data(using: .utf8)!)
        }
    }

    @Test
    func decodingMalformedDeletedAtThrows() {
        let json = #"""
        {"value":"x","modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A","deletedAt":"not-a-date"}
        """#
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: json.data(using: .utf8)!)
        }
    }

    @Test
    func decodingMissingValueKeyThrows() {
        let json = #"""
        {"modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: json.data(using: .utf8)!)
        }
    }

    @Test
    func nullValueIsValid() throws {
        let json = #"""
        {"value":null,"modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        let cell = try decoder.decode(SidecarCell.self, from: json.data(using: .utf8)!)
        #expect(cell.value == .null)
    }

    @Test
    func encodesISO8601WithMillisecondsInUTC() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000.500)
        let cell = SidecarCell(value: .string("x"), modifiedAt: when, modifiedBy: "d")
        let data = try encoder.encode(cell)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains(".500Z"))
    }
}
