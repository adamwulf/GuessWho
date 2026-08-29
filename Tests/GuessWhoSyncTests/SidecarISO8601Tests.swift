import Foundation
import Testing
@testable import GuessWhoSync

@Suite("SidecarISO8601")
struct SidecarISO8601Tests {
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private let nonFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    @Test
    func fixedLayoutMatchesReferenceAcrossBoundaries() {
        let inputs = [
            "1600-02-29T00:00:00.1Z",
            "1900-02-28T23:59:59.01Z",
            "1970-01-01T00:00:00Z",
            "1999-12-31T23:59:59.999Z",
            "2000-02-29T12:34:56.001Z",
            "2023-01-31T23:59:59.9Z",
            "2023-02-01T00:00:00.09Z",
            "2024-02-28T23:59:59.099Z",
            "2024-02-29T00:00:00.9Z",
            "2024-02-29T23:59:59.99Z",
            "2024-03-01T00:00:00.999Z",
            "2024-04-30T23:59:59.001Z",
            "2024-05-01T00:00:00Z",
            "2024-12-31T23:59:59.999Z",
            "2025-01-01T00:00:00Z",
            "2100-02-28T23:59:59.1Z",
            "2400-02-29T23:59:59.01Z",
            "9999-12-31T23:59:59.999Z",
        ]

        for input in inputs {
            let reference = referenceDate(from: input)
            #expect(reference != nil, "Reference formatter rejected \(input)")
            #expect(SidecarISO8601.fixedLayoutDate(from: input) == reference)
            #expect(SidecarISO8601.date(from: input) == reference)
        }
    }

    @Test
    func formatterFallbackMatchesPreviousBehavior() {
        let inputs = [
            "2024-02-29T12:34:56+05:30",
            "2024-02-29T12:34:56-07:00",
            "2024-02-29T12:34:56+0530",
            "2024-02-29T12:34:56.123+05:30",
            "2024-02-29T12:34:56.123-07:00",
            "2024-02-29T12:34:56.1234Z",
            "2024-02-29T12:34:56.123456789Z",
            "2024-01-01T00:00:00.12z",
            // Foundation normalizes these. They must bypass the strict path
            // and retain that pre-optimization behavior.
            "2023-02-29T00:00:00Z",
            "2024-02-30T00:00:00Z",
            "2024-01-01T24:00:00Z",
            "0001-01-01T00:00:00Z",
            "0000-01-01T00:00:00Z",
        ]

        for input in inputs {
            #expect(SidecarISO8601.fixedLayoutDate(from: input) == nil)
            #expect(SidecarISO8601.date(from: input) == referenceDate(from: input))
        }
    }

    @Test
    func malformedInputReturnsNil() {
        let inputs = [
            "",
            "not-a-date",
            "2024-02-29",
            "2024-02-29 12:34:56Z",
            "2024-02-29T12:34Z",
            "2024-02-29T12:34:56",
            "2024-13-01T00:00:00Z",
            "2024-00-01T00:00:00Z",
            "2024-01-00T00:00:00Z",
            "2024-01-01T23:60:00Z",
            "2024-01-01T23:59:60Z",
            "2024-01-01T00:00:00.Z",
            "2024-01-01T00:00:00.AZ",
            "2024-01-01T00:00:00.12x",
        ]

        for input in inputs {
            #expect(referenceDate(from: input) == nil, "Reference formatter unexpectedly accepted \(input)")
            #expect(SidecarISO8601.fixedLayoutDate(from: input) == nil)
            #expect(SidecarISO8601.date(from: input) == nil)
        }
    }

    @Test
    func fixedLayoutRejectsEveryUnrecognizedShape() {
        let inputs = [
            "2024-02-29t12:34:56Z",
            "2024-02-29T12:34:56z",
            "2024/02/29T12:34:56Z",
            "2024-02-29T12-34-56Z",
            "2024-02-29T12:34:56+00:00",
            "2024-02-29T12:34:56.000+00:00",
            "2024-02-29T12:34:56.0000Z",
            "2024-02-29T12:34:56,000Z",
            "2024-2-29T12:34:56Z",
            "2024-02-9T12:34:56Z",
            "2024-02-29T1:34:56Z",
            "2024-02-29T12:3:56Z",
            "2024-02-29T12:34:5Z",
            "２０２４-02-29T12:34:56Z",
        ]

        for input in inputs {
            #expect(SidecarISO8601.fixedLayoutDate(from: input) == nil)
        }
    }

    @Test
    func generatedFixedLayoutInputsExactlyMatchFormatters() {
        var state: UInt64 = 0x4d59_5df4_d0f3_3173

        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        for _ in 0..<4_096 {
            let year = 1_600 + Int(next() % 8_400)
            let month = 1 + Int(next() % 12)
            let day = 1 + Int(next() % UInt64(daysInMonth(month, year: year)))
            let hour = Int(next() % 24)
            let minute = Int(next() % 60)
            let second = Int(next() % 60)
            let fractionDigitCount = Int(next() % 4)

            let prefix = String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d",
                year,
                month,
                day,
                hour,
                minute,
                second
            )
            let input: String
            if fractionDigitCount == 0 {
                input = prefix + "Z"
            } else {
                let modulus = [10, 100, 1_000][fractionDigitCount - 1]
                let fraction = Int(next() % UInt64(modulus))
                input = prefix + String(format: ".%0*dZ", fractionDigitCount, fraction)
            }

            let reference = referenceDate(from: input)
            #expect(reference != nil, "Reference formatter rejected generated input \(input)")
            #expect(SidecarISO8601.fixedLayoutDate(from: input) == reference)
            #expect(SidecarISO8601.date(from: input) == reference)
        }
    }

    private func referenceDate(from string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) {
            return date
        }
        return nonFractionalFormatter.date(from: string)
    }

    private func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let isLeapYear = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return isLeapYear ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
