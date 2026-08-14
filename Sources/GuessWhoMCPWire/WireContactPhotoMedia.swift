import Foundation

/// Shared contact-photo format rules for wire clients and the app-side
/// dispatcher. Detection is byte-based so callers do not have to trust a file
/// extension or a user-supplied media type.
public enum WireContactPhotoMedia {
    public static let supportedMediaTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/heic", "image/webp",
    ]

    public static func mediaType(for data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.count >= 12,
           String(decoding: data.prefix(4), as: UTF8.self) == "RIFF",
           String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self) == "WEBP" {
            return "image/webp"
        }
        if data.count >= 12,
           String(decoding: data.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp" {
            let brand = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
            if [
                "heic", "heix", "hevc", "hevx",
                "heim", "heis", "hevm", "hevs",
                "mif1", "msf1",
            ].contains(brand) {
                return "image/heic"
            }
        }
        return nil
    }
}
