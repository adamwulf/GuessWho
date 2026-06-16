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
        // Permissive on decode (§7.1, §5.3 malformed-input handling): accept
        // both variants so an envelope written by a peer with a slightly
        // different encoder still decodes.
        if let d = fractionalFormatter.date(from: string) { return d }
        return nonFractionalFormatter.date(from: string)
    }
}
