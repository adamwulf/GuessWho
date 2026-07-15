import Foundation
import Testing
@testable import GuessWhoSync

@Suite("MapsGuideURL")
struct MapsGuideURLTests {
    /// A real shared guide's `user` payload (percent-decoded, as
    /// `URLComponents.queryItems` delivers it): guide "Berlin" with 13
    /// entries — 11 place-ID entries and 2 address entries.
    private static let berlinUserParameter =
        "CgZCZXJsaW4SDgiuTRDak7fD46bTzdABElAaOlNhbWFyaXRlcnN0cmHDn2UgMzEsIEZyaWVkcmljaHNoYWluLCAxMDI0NyBCZXJsaW4sIEdlcm1hbnkiEgnS05FtKkJKQBFh0Ph0K+4qQBINCK5NEKXG55G22MWELBJOGjhHw7ZybGl0emVyIFN0cmHDn2UgNDBBLCBLcmV1emJlcmcsIDEwOTk3IEJlcmxpbiwgR2VybWFueSISCZznPu98P0pAEYVNU7qq4ipAEg4Irk0Q376Sus6wyp30ARIOCK5NEIzZh8ik2uvIrAESDQiuTRCtioXH0p6ujzkSDgiuTRCT6N3ZlvvTupcBEg0Irk0Q3Nvd8uynkMIPEg0Irk0Qj4Dm8OXw9oVmEg4Irk0Q3LrY9dby5IDyARIOCK5NEJGSgOyGsMXPiwESDQiuTRClhvfB8cLC7yM="

    // MARK: - Payload decoding

    @Test func decodesBerlinGuidePayload() throws {
        let snapshot = try #require(
            MapsGuideURL.decodeSnapshot(fromUserParameter: Self.berlinUserParameter)
        )
        #expect(snapshot.name == "Berlin")
        #expect(snapshot.entries.count == 13)

        let placeIDs = snapshot.entries.compactMap(\.mapsPlaceID)
        #expect(placeIDs.count == 11)
        // First and last place-ID entries, cross-checked against the
        // `place-id=` anchors on the rendered guide page.
        #expect(placeIDs.first == "ID09B4D36386DC9DA")
        #expect(placeIDs.last == "I23DF0A17183DC325")

        let addressEntries = snapshot.entries.filter { $0.address != nil }
        #expect(addressEntries.count == 2)
        let first = try #require(addressEntries.first)
        #expect(first.address == "Samariterstraße 31, Friedrichshain, 10247 Berlin, Germany")
        #expect(first.latitude != nil && abs(first.latitude! - 52.5169198) < 0.000001)
        #expect(first.longitude != nil && abs(first.longitude! - 13.4651753) < 0.000001)
        #expect(first.mapsPlaceID == nil)
    }

    @Test func decodesEntryOrderAsShared() throws {
        let snapshot = try #require(
            MapsGuideURL.decodeSnapshot(fromUserParameter: Self.berlinUserParameter)
        )
        // The two address entries sit at indices 1 and 3 in the shared link.
        #expect(snapshot.entries[0].mapsPlaceID == "ID09B4D36386DC9DA")
        #expect(snapshot.entries[1].address?.hasPrefix("Samariterstraße") == true)
        #expect(snapshot.entries[2].mapsPlaceID == "I2C0916C36239E325")
        #expect(snapshot.entries[3].address?.hasPrefix("Görlitzer") == true)
    }

    @Test func toleratesPlusDecodedAsSpaceAndStrippedPadding() throws {
        // Simulate an upstream layer that form-decoded '+' to ' ' and dropped
        // the trailing '='.
        let mangled = Self.berlinUserParameter
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let snapshot = try #require(MapsGuideURL.decodeSnapshot(fromUserParameter: mangled))
        #expect(snapshot.name == "Berlin")
        #expect(snapshot.entries.count == 13)
    }

    @Test func rejectsGarbagePayloads() {
        #expect(MapsGuideURL.decodeSnapshot(fromUserParameter: "not base64 !!!") == nil)
        // Valid base64, not a guide protobuf.
        #expect(MapsGuideURL.decodeSnapshot(fromUserParameter: "aGVsbG8gd29ybGQ=") == nil)
        #expect(MapsGuideURL.decodeSnapshot(fromUserParameter: "") == nil)
    }

    @Test func decodesFromExpandedWebURL() throws {
        var components = URLComponents(string: "https://maps.apple.com/guides")!
        components.queryItems = [URLQueryItem(name: "user", value: Self.berlinUserParameter)]
        let url = try #require(components.url)
        let snapshot = try #require(MapsGuideURL.decodeSnapshot(from: url))
        #expect(snapshot.name == "Berlin")
    }

    @Test func shortLinkDoesNotDecodeWithoutNetwork() {
        let url = URL(string: "https://maps.apple/ug/ZKe6cCJ4qAwKMVdY.raR7B")!
        #expect(MapsGuideURL.decodeSnapshot(from: url) == nil)
        #expect(MapsGuideURL.isGuideShareURL(url))
    }

    // MARK: - Place-ID formatting

    @Test func formatsMUIDAsMapKitPlaceID() {
        // 15031693076549454298 == 0xD09B4D36386DC9DA (16 hex digits).
        #expect(MapsGuideURL.placeID(fromMUID: 15_031_693_076_549_454_298) == "ID09B4D36386DC9DA")
        // 1118090345500339676 == 0xF84413ECE576DDC — 15 digits, NO zero pad,
        // matching the rendered page's place-id anchors.
        #expect(MapsGuideURL.placeID(fromMUID: 1_118_090_345_500_339_676) == "IF84413ECE576DDC")
    }

    // MARK: - URL recognition

    @Test func recognizesGuideShareURLs() {
        #expect(MapsGuideURL.isGuideShareURL(URL(string: "https://maps.apple/ug/abc")!))
        #expect(MapsGuideURL.isGuideShareURL(URL(string: "http://maps.apple/ug/abc")!))
        #expect(MapsGuideURL.isGuideShareURL(URL(string: "https://maps.apple.com/guides?user=x")!))
        #expect(MapsGuideURL.isGuideShareURL(URL(string: "https://www.maps.apple.com/guides?user=x")!))

        #expect(!MapsGuideURL.isGuideShareURL(URL(string: "https://maps.apple.com/place?place-id=I1")!))
        #expect(!MapsGuideURL.isGuideShareURL(URL(string: "https://example.com/ug/abc")!))
        #expect(!MapsGuideURL.isGuideShareURL(URL(string: "https://apple.com/guides")!))
    }
}
