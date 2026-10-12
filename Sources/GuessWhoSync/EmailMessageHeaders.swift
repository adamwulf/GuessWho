import Foundation

/// The header metadata of one email message, read from the raw bytes of an
/// RFC 5322 message (an `.eml` file). Only the header block is read; the body
/// is never looked at.
public struct EmailMessageHeaders: Sendable, Equatable {
    /// The `Message-ID` header value, unfolded and trimmed, as found (angle
    /// brackets kept). Nil when the header is absent or empty.
    public var messageID: String?
    /// The `Subject`, RFC 2047-decoded, with each run of spaces and tabs
    /// collapsed to one space. Nil when absent or empty.
    public var subject: String?
    /// The decoded display name of the first `From` mailbox. For the legacy
    /// `addr (Full Name)` spelling, the comment is the name.
    public var fromName: String?
    /// The addr-spec of the first `From` mailbox. Nil when that mailbox has
    /// no well-formed addr-spec (one `@`, no unquoted spaces or specials).
    public var fromAddress: String?
    /// The parsed `Date` header. Nil when absent or unparseable.
    public var date: Date?

    public init(
        messageID: String? = nil,
        subject: String? = nil,
        fromName: String? = nil,
        fromAddress: String? = nil,
        date: Date? = nil
    ) {
        self.messageID = messageID
        self.subject = subject
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.date = date
    }

    /// Parses the header block of an RFC 5322 message (the bytes of an .eml file).
    ///
    /// Reads at most the first `maximumHeaderBytes` bytes, and stops at the
    /// first empty line. Never throws or traps. A header that is missing, or
    /// whose value doesn't parse (a `From` mailbox with no valid addr-spec, an
    /// unreadable `Date`), leaves its property nil, so garbage input returns
    /// all-nil headers.
    public static func parse(_ data: Data) -> EmailMessageHeaders {
        let fields = headerFields(in: data)
        var headers = EmailMessageHeaders()
        headers.messageID = nonEmpty(fields["message-id"])
        headers.subject = nonEmpty(fields["subject"].map { decodeEncodedWords(collapsingFoldingWhitespace($0)) })
        if let from = fields["from"] {
            let mailbox = firstMailbox(in: from)
            headers.fromName = mailbox.name
            headers.fromAddress = mailbox.address
        }
        headers.date = fields["date"].flatMap(parseDate)
        return headers
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Each run of spaces and tabs as one space, trimmed at both ends.
    /// Unfolding keeps the folding whitespace, which is often a tab.
    private static func collapsingFoldingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

// MARK: - Header block

extension EmailMessageHeaders {
    /// How many leading bytes are scanned for the header block. Real header
    /// blocks are a few KiB; the bound keeps a huge message from costing more.
    static let maximumHeaderBytes = 256 * 1024

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// The first occurrence of each header field, keyed by lowercased name,
    /// with continuation lines unfolded into the value.
    ///
    /// Like common mail parsers, a leading mbox `From ` envelope line is
    /// skipped, and the first line that is neither a field nor a continuation
    /// ends the header block (it is treated as the start of the body).
    static func headerFields(in data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        var current: (name: String, value: String)?

        func finishCurrent() {
            if let current, fields[current.name] == nil {
                fields[current.name] = current.value
            }
            current = nil
        }

        for (index, line) in headerLines(in: data).enumerated() {
            if let first = line.unicodeScalars.first, first == " " || first == "\t" {
                // Unfolding removes only the line break; the leading
                // whitespace stays part of the value (RFC 5322 §2.2.3).
                current?.value += line
                continue
            }
            finishCurrent()
            guard let field = parseField(line) else {
                if index == 0, line.hasPrefix("From ") { continue }
                break
            }
            current = field
        }
        finishCurrent()
        return fields
    }

    /// The decoded lines of the header block: everything before the first
    /// empty line, within the first `maximumHeaderBytes` bytes. Each line is
    /// decoded on its own, as UTF-8 (RFC 6532) or else ISO Latin 1, so one
    /// stray byte can't garble its neighbors.
    private static func headerLines(in data: Data) -> [String] {
        let bytes = [UInt8](data.prefix(maximumHeaderBytes))
        var lines: [String] = []
        var start = 0
        while start < bytes.count {
            let lineFeedIndex = bytes[start...].firstIndex(of: lineFeed)
            var end = lineFeedIndex ?? bytes.count
            if end > start, bytes[end - 1] == carriageReturn { end -= 1 }
            if end == start { break }
            lines.append(decodeLine(bytes[start..<end]))
            guard let lineFeedIndex else { break }
            start = lineFeedIndex + 1
        }
        return lines
    }

    private static func decodeLine(_ bytes: ArraySlice<UInt8>) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        // ISO Latin 1 maps every byte to the Unicode scalar of the same value.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    /// Splits `name: value`. The name must be printable ASCII without a
    /// colon; whitespace before the colon is allowed (RFC 5322 §4.5).
    private static func parseField(_ line: String) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
        else { return nil }
        return (name.lowercased(), String(line[line.index(after: colon)...]))
    }
}

// MARK: - RFC 2047 encoded-words

extension EmailMessageHeaders {
    /// Decodes RFC 2047 encoded-words (`=?charset?B?text?=` and
    /// `=?charset?Q?text?=`) in `text`.
    ///
    /// Whitespace between two adjacent encoded-words is dropped (RFC 2047
    /// §6.2). Adjacent words in the same charset are decoded as one byte run,
    /// so a character a sender split across two words still decodes. A word
    /// whose charset is unknown, or whose text or bytes don't decode, stays as
    /// its raw text.
    static func decodeEncodedWords(_ text: String) -> String {
        var output = ""
        var run: (encoding: String.Encoding, bytes: [UInt8], raw: String)?

        func flushRun() {
            guard let pending = run else { return }
            output += String(bytes: pending.bytes, encoding: pending.encoding) ?? pending.raw
            run = nil
        }

        var rest = text[...]
        while let marker = rest.range(of: "=?") {
            let before = rest[..<marker.lowerBound]
            guard let word = EncodedWord(parsing: rest[marker.lowerBound...]) else {
                // Not an encoded-word: keep the "=?" literally and scan on.
                flushRun()
                output += rest[..<marker.upperBound]
                rest = rest[marker.upperBound...]
                continue
            }
            let followsWord = run != nil && before.allSatisfy { $0 == " " || $0 == "\t" }
            if let encoding = word.encoding, let bytes = word.bytes {
                if followsWord, let pending = run, pending.encoding == encoding {
                    run = (encoding, pending.bytes + bytes, pending.raw + before + word.raw)
                } else {
                    flushRun()
                    if !followsWord { output += before }
                    run = (encoding, bytes, String(word.raw))
                }
            } else {
                flushRun()
                output += before + word.raw
            }
            rest = rest[word.raw.endIndex...]
        }
        flushRun()
        output += rest
        return output
    }

    private struct EncodedWord {
        /// The whole `=?…?=` spelling.
        let raw: Substring
        /// Nil when the charset is unknown.
        let encoding: String.Encoding?
        /// The decoded transfer-encoding bytes; nil when malformed.
        let bytes: [UInt8]?

        /// Parses the encoded-word at the start of `text`, which begins with
        /// `=?`. Nil when the text there isn't encoded-word syntax.
        init?(parsing text: Substring) {
            let charsetStart = text.index(text.startIndex, offsetBy: 2)
            guard let charsetEnd = text[charsetStart...].firstIndex(of: "?") else { return nil }
            let charset = text[charsetStart..<charsetEnd]

            let letterIndex = text.index(after: charsetEnd)
            guard letterIndex < text.endIndex else { return nil }
            let letter = text[letterIndex]
            let separator = text.index(after: letterIndex)
            guard separator < text.endIndex, text[separator] == "?" else { return nil }

            let encodedStart = text.index(after: separator)
            guard let encodedEnd = text[encodedStart...].firstIndex(of: "?") else { return nil }
            let closing = text.index(after: encodedEnd)
            guard closing < text.endIndex, text[closing] == "=" else { return nil }
            let encodedText = text[encodedStart..<encodedEnd]

            guard !charset.isEmpty,
                  !charset.contains(where: \.isWhitespace),
                  !encodedText.contains(where: \.isWhitespace)
            else { return nil }

            switch letter {
            case "B", "b": bytes = EmailMessageHeaders.base64Bytes(encodedText)
            case "Q", "q": bytes = EmailMessageHeaders.qEncodedBytes(encodedText)
            default: return nil
            }
            raw = text[..<text.index(after: closing)]
            encoding = EmailMessageHeaders.stringEncoding(forCharset: charset)
        }
    }

    /// The encoding for an IANA charset name, ignoring an RFC 2231
    /// `*language` suffix. Nil when Core Foundation doesn't know the name.
    private static func stringEncoding(forCharset charset: Substring) -> String.Encoding? {
        let name = charset.split(separator: "*", maxSplits: 1).first.map(String.init) ?? ""
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func base64Bytes(_ text: Substring) -> [UInt8]? {
        var padded = String(text)
        // Some senders drop the trailing padding.
        let remainder = padded.utf8.count % 4
        if remainder > 1 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: padded).map { [UInt8]($0) }
    }

    /// RFC 2047 "Q": `_` is a space, `=XX` is a hex byte, the rest is literal.
    private static func qEncodedBytes(_ text: Substring) -> [UInt8]? {
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < source.count {
            switch source[index] {
            case UInt8(ascii: "_"):
                bytes.append(UInt8(ascii: " "))
                index += 1
            case UInt8(ascii: "="):
                guard index + 2 < source.count,
                      let high = hexValue(source[index + 1]),
                      let low = hexValue(source[index + 2])
                else { return nil }
                bytes.append(high << 4 | low)
                index += 3
            case let byte:
                bytes.append(byte)
                index += 1
            }
        }
        return bytes
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}

// MARK: - From mailbox

extension EmailMessageHeaders {
    /// One lexical unit of an address header (RFC 5322 §3.2).
    private enum AddressToken {
        /// A character outside quotes and comments (specials included).
        case character(Character)
        /// A quoted string: its source spelling and its unescaped content.
        case quoted(raw: String, content: String)
        /// A comment's unescaped content, without the outer parentheses.
        case comment(String)
    }

    private static func addressTokens(_ text: String) -> [AddressToken] {
        var tokens: [AddressToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\"":
                var raw = "\""
                var content = ""
                index = text.index(after: index)
                while index < text.endIndex {
                    let character = text[index]
                    raw.append(character)
                    index = text.index(after: index)
                    if character == "\"" { break }
                    if character == "\\", index < text.endIndex {
                        raw.append(text[index])
                        content.append(text[index])
                        index = text.index(after: index)
                        continue
                    }
                    content.append(character)
                }
                tokens.append(.quoted(raw: raw, content: content))
            case "(":
                var depth = 0
                var content = ""
                while index < text.endIndex {
                    let character = text[index]
                    index = text.index(after: index)
                    if character == "\\", index < text.endIndex {
                        content.append(text[index])
                        index = text.index(after: index)
                        continue
                    }
                    if character == "(" {
                        depth += 1
                        if depth == 1 { continue }
                    } else if character == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    content.append(character)
                }
                tokens.append(.comment(content))
            case let character:
                tokens.append(.character(character))
                index = text.index(after: index)
            }
        }
        return tokens
    }

    /// The display name and address of the first mailbox in an address-list
    /// value. A group (`Name: a@b, c@d;`) contributes its first member; empty
    /// entries (`undisclosed-recipients:;`, stray commas) are skipped.
    ///
    /// A comma before the entry has any address (no `<` and no `@` yet)
    /// belongs to an unquoted display name, as in `Doe, Jane <jane@x>`, so it
    /// doesn't end the entry.
    static func firstMailbox(in value: String) -> (name: String?, address: String?) {
        var entry: [AddressToken] = []
        var inAngle = false
        for token in addressTokens(value) {
            if case .character(let character) = token {
                switch character {
                case "<":
                    inAngle = true
                case ">":
                    inAngle = false
                case ":" where !inAngle:
                    // Everything so far was a group's display name.
                    entry.removeAll()
                    continue
                case "," where !inAngle && !hasAddress(entry):
                    if !entry.allSatisfy(isBlank) { entry.append(token) }
                    continue
                case ",", ";":
                    guard !inAngle else { break }
                    let mailbox = mailbox(from: entry)
                    if mailbox.name != nil || mailbox.address != nil { return mailbox }
                    entry.removeAll()
                    continue
                default:
                    break
                }
            }
            entry.append(token)
        }
        return mailbox(from: entry)
    }

    private static func hasAddress(_ tokens: [AddressToken]) -> Bool {
        tokens.contains { isCharacter($0, "<") || isCharacter($0, "@") }
    }

    /// Whitespace or a comment.
    private static func isBlank(_ token: AddressToken) -> Bool {
        switch token {
        case .character(let character): character.isWhitespace
        case .comment: true
        case .quoted: false
        }
    }

    /// `phrase <addr-spec>`, or a bare addr-spec whose comment (the legacy
    /// `addr (Full Name)` form) serves as the name.
    private static func mailbox(from tokens: [AddressToken]) -> (name: String?, address: String?) {
        let commentName = tokens.lazy.compactMap { token -> String? in
            guard case .comment(let text) = token else { return nil }
            return displayText(text)
        }.first

        guard let open = tokens.firstIndex(where: { isCharacter($0, "<") }) else {
            return (commentName, addrSpec(tokens[...]))
        }
        let afterOpen = tokens.index(after: open)
        let close = tokens[afterOpen...].firstIndex(where: { isCharacter($0, ">") }) ?? tokens.endIndex

        var phrase = ""
        for token in tokens[..<open] {
            switch token {
            case .character(let character): phrase.append(character)
            case .quoted(_, let content): phrase += content
            case .comment: phrase += " "
            }
        }
        return (displayText(phrase) ?? commentName, addrSpec(tokens[afterOpen..<close]))
    }

    private static func isCharacter(_ token: AddressToken, _ character: Character) -> Bool {
        if case .character(let found) = token { return found == character }
        return false
    }

    /// Whitespace collapsed, encoded-words decoded, nil when empty.
    private static func displayText(_ text: String) -> String? {
        nonEmpty(decodeEncodedWords(collapsingFoldingWhitespace(text)))
    }

    /// Characters that can't appear in an addr-spec outside a quoted string.
    private static let addrSpecSpecials: Set<Character> = ["<", ">", ",", ";", ":", "\\", "(", ")"]

    /// The addr-spec spelled by `tokens`, with quoted local parts kept as
    /// written and an obsolete source route (`@relay:`) removed. Nil unless
    /// it is one unbroken run (whitespace and comments only around it) with
    /// exactly one `@` outside quotes, so a phrase such as `Jane Example`
    /// is never taken for an address.
    private static func addrSpec(_ tokens: ArraySlice<AddressToken>) -> String? {
        var tokens = tokens
        if let first = tokens.first(where: { !isBlank($0) }), isCharacter(first, "@"),
           let colon = tokens.firstIndex(where: { isCharacter($0, ":") }) {
            tokens = tokens[tokens.index(after: colon)...]
        }
        var spec = ""
        var atSigns = 0
        var endedRun = false
        for token in tokens {
            switch token {
            case .comment:
                endedRun = !spec.isEmpty
            case .character(let character) where character.isWhitespace:
                endedRun = !spec.isEmpty
            case .character(let character):
                guard !endedRun, !addrSpecSpecials.contains(character) else { return nil }
                if character == "@" { atSigns += 1 }
                spec.append(character)
            case .quoted(let raw, _):
                guard !endedRun else { return nil }
                spec += raw
            }
        }
        return atSigns == 1 ? spec : nil
    }
}

// MARK: - Date

extension EmailMessageHeaders {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// RFC 5322 §4.3 obsolete zone names.
    private static let obsoleteZoneOffsets = [
        "UT": "+0000", "GMT": "+0000",
        "EST": "-0500", "EDT": "-0400",
        "CST": "-0600", "CDT": "-0500",
        "MST": "-0700", "MDT": "-0600",
        "PST": "-0800", "PDT": "-0700",
    ]

    /// Parses an RFC 5322 `Date` value, including the obsolete forms of §4.3:
    /// an optional day-of-week, optional seconds, two- or three-digit years,
    /// a numeric zone or a zone name, and comments such as `(CDT)`. The
    /// fields are validated and respelled in one canonical layout, then parsed
    /// by an `en_US_POSIX` formatter. Nil when unparseable.
    static func parseDate(_ value: String) -> Date? {
        var text = ""
        for token in addressTokens(value) {
            switch token {
            case .character(let character): text.append(character)
            case .quoted(let raw, _): text += raw
            case .comment: text += " "
            }
        }
        if let comma = text.firstIndex(of: ",") {
            text = String(text[text.index(after: comma)...])
        }
        var parts = text.split(whereSeparator: \.isWhitespace)
        // A day-of-week written without its comma.
        if let first = parts.first, first.allSatisfy(\.isLetter) { parts.removeFirst() }

        guard parts.count >= 5,
              let day = number(parts[0], digits: 1...2),
              let month = monthAbbreviation(parts[1]),
              let year = fullYear(parts[2]),
              let time = time(parts[3]),
              let zone = numericZone(parts[4])
        else { return nil }
        return dateFormatter.date(from: "\(day) \(month) \(year) \(time) \(zone)")
    }

    private static func number(_ text: Substring, digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(text.count),
              text.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(text)
    }

    private static func monthAbbreviation(_ text: Substring) -> String? {
        guard text.count >= 3, text.allSatisfy(\.isLetter) else { return nil }
        let prefix = text.prefix(3).lowercased()
        return monthAbbreviations.first { $0.lowercased() == prefix }
    }

    /// RFC 5322 §4.3: a two-digit year below 50 is 20xx, otherwise 19xx; a
    /// three-digit year is offset from 1900.
    private static func fullYear(_ text: Substring) -> Int? {
        guard let year = number(text, digits: 2...4) else { return nil }
        switch text.count {
        case 2: return year < 50 ? 2000 + year : 1900 + year
        case 3: return 1900 + year
        default: return year
        }
    }

    /// `HH:mm` or `HH:mm:ss`, respelled as zero-padded `HH:mm:ss`.
    private static func time(_ text: Substring) -> String? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let values = fields.compactMap { number($0, digits: 1...2) }
        guard values.count == fields.count,
              values[0] <= 23, values[1] <= 59, values.count == 2 || values[2] <= 60
        else { return nil }
        let seconds = values.count == 3 ? values[2] : 0
        return [values[0], values[1], seconds]
            .map { $0 < 10 ? "0\($0)" : "\($0)" }
            .joined(separator: ":")
    }

    /// `+hhmm` / `-hhmm` (a `+hh:mm` colon is tolerated), or a zone name.
    /// RFC 5322 §4.3: an unknown alphabetic zone (military letters included)
    /// is treated as `-0000`, i.e. UTC.
    private static func numericZone(_ text: Substring) -> String? {
        if let sign = text.first, sign == "+" || sign == "-" {
            let digits = text.dropFirst().filter { $0 != ":" }
            guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return String(sign) + digits
        }
        let name = text.uppercased()
        if let offset = obsoleteZoneOffsets[name] { return offset }
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return "-0000"
    }
}
