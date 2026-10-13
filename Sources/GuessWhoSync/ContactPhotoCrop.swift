import Foundation
import CoreGraphics

/// Rectangle in the upright original image, with a top-left origin and unit dimensions.
/// A missing crop means the entire original image.
public struct ContactPhotoCrop: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, x < 1, y < 1, width > 0, height > 0,
              x + width <= 1.000000001, y + height <= 1.000000001 else { return nil }
        self.x = x
        self.y = y
        self.width = min(width, 1 - x)
        self.height = min(height, 1 - y)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let crop = try Self(
            x: values.decode(Double.self, forKey: .x),
            y: values.decode(Double.self, forKey: .y),
            width: values.decode(Double.self, forKey: .width),
            height: values.decode(Double.self, forKey: .height)
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid photo crop"))
        }
        self = crop
    }

    /// A square crop in image pixels, clamped so the circular mask is always filled.
    public static func square(imageSize: CGSize, zoom: Double = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Self? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0, zoom.isFinite,
              center.x.isFinite, center.y.isFinite else { return nil }
        let side = Double(min(imageSize.width, imageSize.height)) / max(1, zoom)
        let width = side / Double(imageSize.width)
        let height = side / Double(imageSize.height)
        return Self(x: min(max(0, Double(center.x) - width / 2), 1 - width),
                    y: min(max(0, Double(center.y) - height / 2), 1 - height),
                    width: width, height: height)
    }

    public func rectangle(in imageSize: CGSize) -> CGRect {
        let origin = CGPoint(x: CGFloat(x) * imageSize.width, y: CGFloat(y) * imageSize.height)
        let size = CGSize(width: CGFloat(width) * imageSize.width, height: CGFloat(height) * imageSize.height)
        return CGRect(origin: origin, size: size)
    }
}
