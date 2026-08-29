import Foundation

enum SidecarISO8601 {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let nonFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(from date: Date) -> String {
        // Always write the fractional-seconds variant on encode (§7.1).
        fractionalFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        // Fast common path: the self-inflicted regular UTC layout parses
        // without touching ICU at all.
        if let date = fixedLayoutDate(from: string) {
            return date
        }

        // Fixed-layout parser declined (irregular spelling, out-of-range
        // field, pre-1600 year, non-`Z` zone, …). Restore the original
        // permissive decode EXACTLY (§7.1, §5.3 malformed-input handling):
        // try the fractional-seconds formatter first, then the non-fractional
        // one. The earlier "scan byte 19 for a period and pick one formatter"
        // shortcut silently regressed odd-but-Foundation-accepted spellings —
        // e.g. a single-digit month/day like `2024-2-29T12:34:56.123Z`, whose
        // fractional dot no longer sits at byte 19, was routed to the
        // non-fractional formatter and rejected. Trying both in this order is
        // what the formatters did before the optimization.
        return fractionalFormatter.date(from: string)
            ?? nonFractionalFormatter.date(from: string)
    }

    /// Parses only the UTC layout written by ``string(from:)`` (plus its
    /// accepted one- and two-digit fractional variants). Returning `nil` is
    /// intentional for every other spelling so `date(from:)` can preserve
    /// the formatter's existing permissive behavior.
    static func fixedLayoutDate(from string: String) -> Date? {
        fixedLayoutDate(from: Array(string.utf8))
    }

    private static let asciiPeriod: UInt8 = 46

    private static func fixedLayoutDate(from utf8: [UInt8]) -> Date? {
        let fractionDigitCount: Int
        switch utf8.count {
        case 20:
            fractionDigitCount = 0
        case 22...24:
            fractionDigitCount = utf8.count - 21
        default:
            return nil
        }

        guard utf8[4] == 45,
              utf8[7] == 45,
              utf8[10] == 84,
              utf8[13] == 58,
              utf8[16] == 58,
              utf8[utf8.count - 1] == 90,
              fractionDigitCount == 0 || utf8[19] == asciiPeriod,
              let year = decimal(utf8, startingAt: 0, count: 4),
              let month = decimal(utf8, startingAt: 5, count: 2),
              let day = decimal(utf8, startingAt: 8, count: 2),
              let hour = decimal(utf8, startingAt: 11, count: 2),
              let minute = decimal(utf8, startingAt: 14, count: 2),
              let second = decimal(utf8, startingAt: 17, count: 2),
              // ISO8601DateFormatter uses historical calendar behavior for
              // earlier years. Keep those rare values on the ICU fallback
              // rather than risk a subtly different absolute date.
              year >= 1600,
              (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        let milliseconds: Int
        if fractionDigitCount == 0 {
            milliseconds = 0
        } else {
            guard let fraction = decimal(utf8, startingAt: 20, count: fractionDigitCount) else {
                return nil
            }
            switch fractionDigitCount {
            case 1: milliseconds = fraction * 100
            case 2: milliseconds = fraction * 10
            default: milliseconds = fraction
            }
        }

        let daysSince1970 = gregorianDaysSince1970(year: year, month: month, day: day)
        let secondsSince1970 = daysSince1970 * 86_400
            + hour * 3_600
            + minute * 60
            + second
        return Date(
            timeIntervalSince1970: TimeInterval(secondsSince1970)
                + TimeInterval(milliseconds) / 1_000
        )
    }

    private static func decimal(_ utf8: [UInt8], startingAt start: Int, count: Int) -> Int? {
        var value = 0
        for index in start..<(start + count) {
            let byte = utf8[index]
            guard (48...57).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
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

    /// Proleptic-Gregorian civil date conversion, with 1970-01-01 as day 0.
    private static func gregorianDaysSince1970(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
