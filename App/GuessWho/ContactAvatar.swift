import SwiftUI
import GuessWhoSync

/// Shared circular contact avatar for SwiftUI surfaces. Renders the cached
/// thumbnail when one exists, otherwise an initials monogram on a
/// deterministic background color.
///
/// The placeholder color seed and palette MUST stay byte-for-byte identical to
/// the UIKit `ContactAvatarImage` so list rows and SwiftUI rows look the same.
/// Color is seeded on `"\(contact.contactType)-\(contact.displayName)"` — never
/// on `ContactID.hashValue` — so the same contact always draws the same color
/// across both rendering paths.
///
/// Photo loading goes exclusively through `ContactPhotoLoader` + `ContactID`;
/// this view never imports Contacts or resolves a `localID`.
@MainActor
struct ContactAvatar: View {
    let contact: Contact
    let diameter: CGFloat

    @Environment(ContactPhotoLoader.self) private var photoLoader

    // The resolved thumbnail, once loaded. Nil renders the initials circle, so
    // the row paints initials-first and swaps in the photo when it arrives.
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Self.avatarColor(for: contact))
                Text(contact.initials)
                    .font(.system(size: max(11, diameter * 0.42), weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        // A fixed frame + clip keeps row height stable whether the photo is
        // present or not, so a late image arrival never reflows the row.
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        // Keyed on the opaque ContactID so SwiftUI cancels a stale load when the
        // row is recycled onto a different contact. The loader/decoder already
        // runs off the main actor; only the final assignment happens here.
        .task(id: contact.contactID) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let id = contact.contactID
        if let cached = photoLoader.cachedImage(for: id, kind: .thumbnail) {
            image = cached
            return
        }
        // Reset to the initials placeholder while the (possibly recycled) row
        // loads its new contact's photo.
        image = nil
        guard let loaded = await photoLoader.image(for: id, kind: .thumbnail) else { return }
        guard contact.contactID == id else { return }
        image = loaded
    }

    /// Deterministic placeholder background. Mirrors
    /// `ContactAvatarImage.backgroundColor(for:)` exactly — same seed string,
    /// same 8-color palette, same index math — so UIKit and SwiftUI
    /// placeholders are visually identical.
    static func avatarColor(for contact: Contact) -> Color {
        let seed = "\(contact.contactType)-\(contact.displayName)"
        let value = seed.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        let palette: [Color] = [
            .blue,
            .green,
            .indigo,
            .orange,
            .pink,
            .purple,
            .red,
            .teal,
        ]
        return palette[abs(value) % palette.count]
    }
}
