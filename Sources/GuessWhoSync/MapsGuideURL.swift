import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Decoding for Apple Maps guide share links.
///
/// A shared guide travels as a short link (`https://maps.apple/ug/<token>`)
/// that 301-redirects to `https://maps.apple.com/guides?user=<base64>`. The
/// `user` parameter is the guide itself: a small binary-protobuf payload
/// carrying the guide's name plus one entry per saved place — no scraping of
/// the rendered web page is needed. Observed message shape:
///
/// ```
/// message Guide {
///   string name = 1;              // e.g. "Berlin"
///   repeated Entry entries = 2;
/// }
/// message Entry {
///   uint64 unknown = 1;           // constant (9902) — space/version marker
///   uint64 muid = 2;              // Apple Maps place id; "I" + uppercase hex
///                                 // == MapKit's MKMapItem.Identifier rawValue
///   string address = 3;           // address entries only
///   Coordinate coordinate = 4;    // address entries only
/// }
/// message Coordinate {
///   double latitude = 1;
///   double longitude = 2;
/// }
/// ```
///
/// See docs/maps-guides.md for the end-to-end import flow.
public enum MapsGuideURL {
    // MARK: - Snapshot types

    /// A decoded guide share link: the guide's name plus its entries in the
    /// link's order.
    public struct Snapshot: Hashable, Sendable {
        public var name: String
        public var entries: [Entry]

        public init(name: String, entries: [Entry]) {
            self.name = name
            self.entries = entries
        }
    }

    /// One place entry. `mapsPlaceID` is the MapKit-compatible `"I" + hex`
    /// form; address entries carry `address`/`latitude`/`longitude` instead.
    public struct Entry: Hashable, Sendable {
        public var mapsPlaceID: String?
        public var address: String?
        public var latitude: Double?
        public var longitude: Double?

        public init(
            mapsPlaceID: String? = nil,
            address: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil
        ) {
            self.mapsPlaceID = mapsPlaceID
            self.address = address
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public enum FetchError: Error, Equatable {
        /// The URL isn't recognizably an Apple Maps guide share link.
        case notAGuideURL
        /// A short link stopped redirecting before reaching a decodable
        /// `guides?user=` URL.
        case redirectChainEnded
        /// A `user=` payload was present but couldn't be decoded.
        case undecodablePayload
    }

    // MARK: - URL recognition

    private static let shortHost = "maps.apple"
    private static let webHost = "maps.apple.com"

    /// True if `url` looks like an Apple Maps guide share link — either the
    /// short form (`maps.apple/ug/<token>`) or the expanded web form
    /// (`maps.apple.com/guides?user=…`). Recognition only; a `true` here does
    /// not guarantee the payload decodes.
    public static func isGuideShareURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return false }
        let path = components.path
        if host == shortHost || host == "www.\(shortHost)" {
            return path.hasPrefix("/ug")
        }
        if host == webHost || host == "www.\(webHost)" {
            return path.hasPrefix("/ug") || path.hasPrefix("/guides")
        }
        return false
    }

    // MARK: - Decoding (pure, no network)

    /// Decode a guide snapshot straight from a URL that carries the
    /// `user=<base64>` payload (the expanded `maps.apple.com/guides` form).
    /// Returns nil when the URL has no decodable payload — e.g. the short
    /// `maps.apple/ug/…` form, which needs `fetchSnapshot` to follow the
    /// redirect first.
    public static func decodeSnapshot(from url: URL) -> Snapshot? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              host == webHost || host == "www.\(webHost)" || host == shortHost || host == "www.\(shortHost)",
              let payload = components.queryItems?.first(where: { $0.name == "user" })?.value
        else { return nil }
        return decodeSnapshot(fromUserParameter: payload)
    }

    /// Decode the `user` query parameter's base64-protobuf payload. Exposed
    /// internally for tests; app code goes through the URL entry points.
    static func decodeSnapshot(fromUserParameter parameter: String) -> Snapshot? {
        // URLComponents percent-decodes the query value but does NOT translate
        // '+' — if an upstream layer form-decoded it to a space, undo that,
        // and re-pad in case trailing '=' was stripped along the way.
        var base64 = parameter.replacingOccurrences(of: " ", with: "+")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return decodeSnapshot(fromProtobuf: data)
    }

    /// The MapKit `MKMapItem.Identifier`-compatible form of a raw 64-bit
    /// Apple Maps place id ("muid"): `"I"` + uppercase hex, no padding.
    static func placeID(fromMUID muid: UInt64) -> String {
        "I" + String(muid, radix: 16, uppercase: true)
    }

    private static func decodeSnapshot(fromProtobuf data: Data) -> Snapshot? {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var name = ""
        var entries: [Entry] = []
        while !reader.isAtEnd {
            guard let (field, wireType) = reader.readTag() else { return nil }
            switch (field, wireType) {
            case (1, .lengthDelimited):
                guard let bytes = reader.readLengthDelimited(),
                      let value = String(bytes: bytes, encoding: .utf8)
                else { return nil }
                name = value
            case (2, .lengthDelimited):
                guard let bytes = reader.readLengthDelimited(),
                      let entry = decodeEntry(fromProtobuf: bytes)
                else { return nil }
                entries.append(entry)
            default:
                guard reader.skipValue(wireType: wireType) else { return nil }
            }
        }
        // A payload with no name AND no entries is not a guide (e.g. an
        // unrelated base64 blob that happened to parse as empty protobuf).
        guard !name.isEmpty || !entries.isEmpty else { return nil }
        return Snapshot(name: name, entries: entries)
    }

    private static func decodeEntry(fromProtobuf bytes: [UInt8]) -> Entry? {
        var reader = ProtobufReader(bytes: bytes)
        var entry = Entry()
        while !reader.isAtEnd {
            guard let (field, wireType) = reader.readTag() else { return nil }
            switch (field, wireType) {
            case (2, .varint):
                guard let muid = reader.readVarint() else { return nil }
                entry.mapsPlaceID = placeID(fromMUID: muid)
            case (3, .lengthDelimited):
                guard let addressBytes = reader.readLengthDelimited(),
                      let address = String(bytes: addressBytes, encoding: .utf8)
                else { return nil }
                entry.address = address
            case (4, .lengthDelimited):
                guard let coordBytes = reader.readLengthDelimited(),
                      let coordinate = decodeCoordinate(fromProtobuf: coordBytes)
                else { return nil }
                entry.latitude = coordinate.latitude
                entry.longitude = coordinate.longitude
            default:
                guard reader.skipValue(wireType: wireType) else { return nil }
            }
        }
        // An entry must carry SOMETHING addressable — a place id, an address,
        // or a coordinate. Reject empty entries rather than storing husks.
        guard entry.mapsPlaceID != nil || entry.address != nil || entry.latitude != nil else { return nil }
        return entry
    }

    private static func decodeCoordinate(
        fromProtobuf bytes: [UInt8]
    ) -> (latitude: Double, longitude: Double)? {
        var reader = ProtobufReader(bytes: bytes)
        var latitude: Double?
        var longitude: Double?
        while !reader.isAtEnd {
            guard let (field, wireType) = reader.readTag() else { return nil }
            switch (field, wireType) {
            case (1, .fixed64):
                latitude = reader.readDouble()
            case (2, .fixed64):
                longitude = reader.readDouble()
            default:
                guard reader.skipValue(wireType: wireType) else { return nil }
            }
        }
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    // MARK: - Fetching (redirect resolution for short links)

    /// Resolve `url` to a decodable guide snapshot, following the short link's
    /// redirect chain when needed. The redirect target itself carries the full
    /// payload in its `user=` parameter, so at most a handful of tiny requests
    /// run and the rendered guide page's HTML is never downloaded.
    public static func fetchSnapshot(from url: URL) async throws -> Snapshot {
        if let snapshot = decodeSnapshot(from: url) { return snapshot }
        guard isGuideShareURL(url) else { throw FetchError.notAGuideURL }

        var current = upgradedToHTTPS(url)
        // A well-formed short link resolves in one hop; a small cap tolerates
        // an extra www./host-normalization hop without ever chasing a loop.
        for _ in 0..<4 {
            guard let next = try await redirectTarget(of: current) else {
                throw FetchError.redirectChainEnded
            }
            if let snapshot = decodeSnapshot(from: next) { return snapshot }
            current = next
        }
        throw FetchError.undecodablePayload
    }

    private static func upgradedToHTTPS(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http"
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// One redirect hop: request `url` without following redirects and return
    /// the absolute `Location` target, or nil when the response isn't a
    /// redirect.
    private static func redirectTarget(of url: URL) async throws -> URL? {
        let delegate = RedirectStopper()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)
        else { return nil }
        return target.absoluteURL
    }

    /// Task delegate that refuses every redirect so the 3xx response itself
    /// (with its `Location` header) is returned to the caller.
    private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

// MARK: - Minimal protobuf reader

/// Just enough of the protobuf wire format to walk the guide payload:
/// varints, length-delimited fields, and fixed64 doubles. Unknown fields are
/// skipped by wire type; anything malformed (truncation, an over-long varint,
/// a deprecated group tag) surfaces as nil so the caller rejects the payload
/// instead of mis-reading it.
private struct ProtobufReader {
    enum WireType: UInt8 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    let bytes: [UInt8]
    private(set) var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readTag() -> (field: UInt64, wireType: WireType)? {
        guard let key = readVarint() else { return nil }
        guard let wireType = WireType(rawValue: UInt8(key & 0x7)) else { return nil }
        return (key >> 3, wireType)
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard shift < 64 else { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil   // truncated
    }

    mutating func readLengthDelimited() -> [UInt8]? {
        guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return nil }
        let start = index
        index += Int(length)
        return Array(bytes[start..<index])
    }

    mutating func readDouble() -> Double? {
        guard index + 8 <= bytes.count else { return nil }
        var raw: UInt64 = 0
        for offset in (0..<8).reversed() {
            raw = (raw << 8) | UInt64(bytes[index + offset])
        }
        index += 8
        return Double(bitPattern: raw)
    }

    mutating func skipValue(wireType: WireType) -> Bool {
        switch wireType {
        case .varint:
            return readVarint() != nil
        case .fixed64:
            guard index + 8 <= bytes.count else { return false }
            index += 8
            return true
        case .lengthDelimited:
            return readLengthDelimited() != nil
        case .fixed32:
            guard index + 4 <= bytes.count else { return false }
            index += 4
            return true
        }
    }
}
