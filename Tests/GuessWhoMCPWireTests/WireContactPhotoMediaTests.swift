import Foundation
import XCTest
import GuessWhoMCPWire

final class WireContactPhotoMediaTests: XCTestCase {
    func testDetectsEverySupportedPhotoFormatFromBytes() {
        let fixtures: [(Data, String)] = [
            (Data([0xFF, 0xD8, 0xFF, 0x00]), "image/jpeg"),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "image/png"),
            (Data("GIF89a".utf8), "image/gif"),
            (Data("RIFF\0\0\0\0WEBP".utf8), "image/webp"),
            (Data([0, 0, 0, 0]) + Data("ftypheic".utf8), "image/heic"),
        ]

        for (data, expected) in fixtures {
            XCTAssertEqual(WireContactPhotoMedia.mediaType(for: data), expected)
        }
    }

    func testRecognizesAllSupportedHEICBrands() {
        let brands = [
            "heic", "heix", "hevc", "hevx",
            "heim", "heis", "hevm", "hevs",
            "mif1", "msf1",
        ]

        for brand in brands {
            let data = Data([0, 0, 0, 0]) + Data("ftyp\(brand)".utf8)
            XCTAssertEqual(WireContactPhotoMedia.mediaType(for: data), "image/heic")
        }
    }

    func testRejectsUnknownAndTruncatedData() {
        XCTAssertNil(WireContactPhotoMedia.mediaType(for: Data()))
        XCTAssertNil(WireContactPhotoMedia.mediaType(for: Data("not an image".utf8)))
        XCTAssertNil(WireContactPhotoMedia.mediaType(for: Data("RIFF".utf8)))
        XCTAssertNil(WireContactPhotoMedia.mediaType(for: Data("ftypheic".utf8)))
    }

    func testSupportedSetMatchesDetectorOutputs() {
        XCTAssertEqual(
            WireContactPhotoMedia.supportedMediaTypes,
            ["image/jpeg", "image/png", "image/gif", "image/heic", "image/webp"])
    }
}
