import Foundation
import Testing
@testable import GuessWhoSync

@Suite("SidecarCell")
struct SidecarCellTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test
    func valueCellRoundtrips() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000.123)
        let cell: SidecarCell = .value(.string("Bear"), modifiedAt: when, modifiedBy: "device-A")
        let data = try encoder.encode(cell)
        let decoded = try decoder.decode(SidecarCell.self, from: data)
        guard case .value(let v, let ts, let by) = decoded else {
            Issue.record("expected value cell, got \(decoded)")
            return
        }
        #expect(v == .string("Bear"))
        #expect(by == "device-A")
        #expect(ts.timeIntervalSince1970 == when.timeIntervalSince1970)
    }

    @Test
    func tombstoneCellRoundtrips() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_500.456)
        let cell: SidecarCell = .tombstone(modifiedAt: when, modifiedBy: "device-B")
        let data = try encoder.encode(cell)
        let decoded = try decoder.decode(SidecarCell.self, from: data)
        guard case .tombstone(let ts, let by) = decoded else {
            Issue.record("expected tombstone cell, got \(decoded)")
            return
        }
        #expect(by == "device-B")
        #expect(ts.timeIntervalSince1970 == when.timeIntervalSince1970)
    }

    @Test
    func decodingBothValueAndDeletedThrows() {
        let json = #"""
        {"deleted":true,"value":"x","modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: data)
        }
    }

    @Test
    func decodingNeitherValueNorDeletedThrows() {
        let json = #"""
        {"modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: data)
        }
    }

    @Test
    func decodingDeletedFalseAlsoThrows() {
        let json = #"""
        {"deleted":false,"modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: data)
        }
    }

    @Test
    func decodingMalformedTimestampThrows() {
        let json = #"""
        {"value":"x","modifiedAt":"not-a-date","modifiedBy":"device-A"}
        """#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try self.decoder.decode(SidecarCell.self, from: data)
        }
    }

    @Test
    func encodesISO8601WithMillisecondsInUTC() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000.500)
        let cell: SidecarCell = .value(.string("x"), modifiedAt: when, modifiedBy: "d")
        let data = try encoder.encode(cell)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains(".500Z"))
    }

    @Test
    func decodesExactSpecExampleValueCell() throws {
        let json = #"""
        {"value":"Bear","modifiedAt":"2026-06-14T20:15:00.000Z","modifiedBy":"device-A"}
        """#
        let data = json.data(using: .utf8)!
        let cell = try decoder.decode(SidecarCell.self, from: data)
        guard case .value(let v, _, let by) = cell else {
            Issue.record("expected value cell")
            return
        }
        #expect(v == .string("Bear"))
        #expect(by == "device-A")
    }

    @Test
    func decodesExactSpecExampleTombstone() throws {
        let json = #"""
        {"deleted":true,"modifiedAt":"2026-06-13T10:00:00.000Z","modifiedBy":"device-A"}
        """#
        let data = json.data(using: .utf8)!
        let cell = try decoder.decode(SidecarCell.self, from: data)
        guard case .tombstone(_, let by) = cell else {
            Issue.record("expected tombstone cell")
            return
        }
        #expect(by == "device-A")
    }
}
