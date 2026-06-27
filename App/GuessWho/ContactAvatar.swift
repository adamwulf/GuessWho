import SwiftUI
import GuessWhoSync

/// Shared circular contact avatar for SwiftUI surfaces. Renders the cached
/// thumbnail when one exists, otherwise an initials monogram on a
/// deterministic background color.
///
/// The placeholder *index* is the enforced shared thing: both this path and the
/// UIKit `ContactAvatarImage` resolve their color slot through
/// `ContactAvatarPalette.index(for:)` (seeded on
/// `"\(contact.contactType)-\(contact.displayName)"` — never on
/// `ContactID.hashValue`), so the same contact always lands on the same slot.
/// This path then maps that index to the matching system color via
/// `Color(uiColor:)` from the same `UIColor` list the UIKit path uses, so the
/// two placeholders render the identical system color rather than two
/// independently-named SwiftUI/UIKit colors that merely intend to match.
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
        // The avatar is decorative next to the contact name, so hide it from
        // VoiceOver — the initials/photo would otherwise be announced before the
        // name. This matches the UIKit list cells, whose plain `UIImageView`
        // avatar is not an accessibility element either.
        .accessibilityHidden(true)
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
        // Stale-load protection lives in `.task(id: contact.contactID)`: when the
        // row is recycled onto a different contact, SwiftUI cancels this task and
        // restarts it for the new id, so a late result can't land on the wrong
        // row. (`id` is a value-type copy of `contact.contactID`, so a post-await
        // equality check against it would be tautological — there's nothing to
        // re-verify here.)
        guard let loaded = await photoLoader.image(for: id, kind: .thumbnail) else { return }
        image = loaded
    }

    /// Deterministic placeholder background. The index comes from the shared
    /// `ContactAvatarPalette`, and the color is the same `UIColor` system color
    /// the UIKit `ContactAvatarImage` path uses — wrapped via `Color(uiColor:)`
    /// — so both placeholders resolve to the identical system color. This
    /// palette MUST keep the same order/length as `ContactAvatarPalette.count`.
    static func avatarColor(for contact: Contact) -> Color {
        let palette: [UIColor] = [
            .systemBlue,
            .systemGreen,
            .systemIndigo,
            .systemOrange,
            .systemPink,
            .systemPurple,
            .systemRed,
            .systemTeal,
        ]
        return Color(uiColor: palette[ContactAvatarPalette.index(for: contact)])
    }
}

/// Placeholder avatar for rows whose contact can't be resolved. Occupies the
/// same circular `diameter` footprint as `ContactAvatar` so known and unknown
/// rows stay aligned, and is likewise hidden from VoiceOver (decorative).
@MainActor
struct UnknownContactAvatar: View {
    let diameter: CGFloat

    var body: some View {
        Image(systemName: "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}
