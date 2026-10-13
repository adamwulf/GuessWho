import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

@Suite("Contact photo rendering")
struct ContactPhotoRenderingTests {
    #if targetEnvironment(macCatalyst)
    @Test func largeOriginalHasBoundedMailThumbnailBeforeAndAfterCropReset() throws {
        let side = 1024
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var random: UInt64 = 1
        for index in stride(from: 0, to: pixels.count, by: 4) {
            random = random &* 6364136223846793005 &+ 1
            pixels[index] = UInt8(truncatingIfNeeded: random >> 32)
            pixels[index + 1] = UInt8(truncatingIfNeeded: random >> 40)
            pixels[index + 2] = UInt8(truncatingIfNeeded: random >> 48)
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let original = try #require(UIImage(cgImage: cgImage).pngData())
        #expect(original.count > MailContactSnapshotBuilder.maximumThumbnailByteCount)
        let crop = try #require(ContactPhotoCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let selections: [ContactPhotoCrop?] = [crop, nil]
        for selection in selections {
            let photo = ContactPhoto(data: original, kind: .fullSize, crop: selection)
            let thumbnail = try #require(photo.mailThumbnailData())
            #expect(thumbnail.count < MailContactSnapshotBuilder.maximumThumbnailByteCount)
            let rendered = try #require(UIImage(data: thumbnail))
            #expect(rendered.size.width == 256)
            #expect(rendered.size.height == 256)
            #expect(photo.data == original)
        }
    }
    #endif
}
