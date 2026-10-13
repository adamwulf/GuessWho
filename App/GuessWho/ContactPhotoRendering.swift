import UIKit
import GuessWhoSync

extension ContactPhoto {
    /// Drawing applies EXIF orientation before interpreting the normalized rectangle.
    /// The result is only a display image; the stored bytes are never replaced.
    nonisolated func displayImage(maxDimension: CGFloat? = nil) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        guard crop != nil || maxDimension != nil else { return image }
        let rect = crop?.rectangle(in: image.size) ?? CGRect(origin: .zero, size: image.size)
        let ratio = min(1, (maxDimension ?? max(rect.width, rect.height)) / max(rect.width, rect.height))
        let size = CGSize(width: rect.width * ratio, height: rect.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: -rect.minX * ratio, y: -rect.minY * ratio,
                                  width: image.size.width * ratio, height: image.size.height * ratio))
        }
    }
}
