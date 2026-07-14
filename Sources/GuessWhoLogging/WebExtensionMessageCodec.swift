import Foundation

/// Pure helpers for decoding Safari's native-message envelope variants and
/// producing bounded, privacy-conscious diagnostic log strings.
///
/// Safari may deliver `{ payload: ... }` directly or wrap it as
/// `{ message: { payload: ... } }`. Keeping that shape handling here makes the
/// extension handler small and gives the no-value transport breadcrumb and
/// diagnostic bounds direct unit coverage.
public enum WebExtensionMessageCodec {
    public static let maximumDiagnosticBytes = 32_768

    public static func extractPayload(from raw: Any?) -> Any? {
        messageDictionary(from: raw)?["payload"]
    }

    public static func extractDiagnostic(from raw: Any?) -> Any? {
        messageDictionary(from: raw)?["diagnostic"]
    }

    /// A transport breadcrumb containing key names only. Values may include a
    /// full profile and photo, so they must never be interpolated here.
    public static func messageShape(_ raw: Any?) -> String {
        guard let dictionary = raw as? [String: Any] else {
            return "type=\(String(describing: type(of: raw)))"
        }
        let outerKeys = dictionary.keys.sorted().joined(separator: ",")
        let innerKeys = (dictionary["message"] as? [String: Any])?
            .keys.sorted().joined(separator: ",") ?? "-"
        return "outerKeys=\(outerKeys) innerKeys=\(innerKeys)"
    }

    /// Serialize one diagnostic as compact sorted JSON.
    ///
    /// The recursive preflight spends a JSON-escaped byte budget before
    /// `JSONSerialization` allocates output. It rejects deep, unsupported, or
    /// oversized trees early; a second exact `Data.count` check catches the
    /// difference between the estimate and actual Foundation serialization.
    /// Oversized diagnostics become a small fixed breadcrumb rather than a
    /// truncated (and therefore invalid) JSON fragment.
    public static func diagnosticDescription(_ diagnostic: Any) -> String {
        guard JSONSerialization.isValidJSONObject(diagnostic) else {
            return "<invalid diagnostic>"
        }
        var budget = maximumDiagnosticBytes
        guard consumePreflightBudget(for: diagnostic, budget: &budget, depth: 0) else {
            return "<diagnostic exceeds preflight bound>"
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: diagnostic,
                options: [.sortedKeys]
              ),
              let string = String(data: data, encoding: .utf8) else {
            return "<invalid diagnostic>"
        }
        guard data.count <= maximumDiagnosticBytes else {
            return "<diagnostic exceeds serialized bound>"
        }
        return string
    }

    private static func messageDictionary(from raw: Any?) -> [String: Any]? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        // Preserve direct-shape precedence if Safari supplies both a top-level
        // payload and an unrelated `message` field.
        if dictionary["payload"] != nil || dictionary["diagnostic"] != nil {
            return dictionary
        }
        return (dictionary["message"] as? [String: Any]) ?? dictionary
    }

    /// Serialized JSON byte estimate without allocating escaped string copies.
    /// The exact `Data.count` check after serialization remains authoritative.
    private static func consumePreflightBudget(
        for value: Any,
        budget: inout Int,
        depth: Int
    ) -> Bool {
        guard depth <= 32 else { return false }

        switch value {
        case is NSNull:
            return consume(4, from: &budget)
        case is Bool:
            return consume(5, from: &budget)
        case let number as NSNumber:
            return consume(String(describing: number).utf8.count, from: &budget)
        case let string as String:
            return consumeJSONStringBudget(string, from: &budget)
        case let array as [Any]:
            guard consume(2, from: &budget) else { return false }
            for (index, element) in array.enumerated() {
                if index > 0, !consume(1, from: &budget) { return false }
                guard consumePreflightBudget(
                    for: element,
                    budget: &budget,
                    depth: depth + 1
                ) else { return false }
            }
            return true
        case let dictionary as [String: Any]:
            guard consume(2, from: &budget) else { return false }
            for (index, entry) in dictionary.enumerated() {
                if index > 0, !consume(1, from: &budget) { return false }
                guard consumeJSONStringBudget(entry.key, from: &budget),
                      consume(1, from: &budget),
                      consumePreflightBudget(
                        for: entry.value,
                        budget: &budget,
                        depth: depth + 1
                      ) else { return false }
            }
            return true
        default:
            return false
        }
    }

    private static func consumeJSONStringBudget(_ string: String, from budget: inout Int) -> Bool {
        guard consume(2, from: &budget) else { return false } // surrounding quotes
        for scalar in string.unicodeScalars {
            let byteCount: Int
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                byteCount = 2 // short escape or escaped quote/backslash
            case 0x00...0x1F:
                byteCount = 6 // \u00XX
            case 0x20...0x7F:
                byteCount = 1
            case 0x80...0x7FF:
                byteCount = 2
            case 0x800...0xFFFF:
                byteCount = 3
            default:
                byteCount = 4
            }
            guard consume(byteCount, from: &budget) else { return false }
        }
        return true
    }

    private static func consume(_ amount: Int, from budget: inout Int) -> Bool {
        guard amount >= 0, amount <= budget else { return false }
        budget -= amount
        return true
    }
}
