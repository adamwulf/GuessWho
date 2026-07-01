import UIKit

extension UIColor {
    /// Parse a `#RRGGBB` (or `RRGGBB`) hex string into a color. Returns nil
    /// for any string that isn't exactly six hex digits. Matches the format
    /// emitted by `EKEventStoreAdapter.hexString(from:)` for calendar colors,
    /// so a stored calendar color round-trips back into a `UIColor` swatch.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }
}
