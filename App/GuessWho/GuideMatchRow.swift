import SwiftUI
import GuessWhoSync

/// One "this address appears in an imported guide" row, shown directly under a
/// contact's postal address or an event's location. Tapping it opens the
/// guide's places on the same nav stack (via the injected `pushGuideReference`
/// closure). Mirrors the recent-event / associated-organization row pattern: a
/// plain button laid out with `ActivityRowLayout`, leading map glyph, guide
/// name tinted with the matched place as a caption.
struct GuideMatchRow: View {
    let match: GuideAddressMatcher.Match

    @Environment(\.pushGuideReference) private var pushGuideReference

    var body: some View {
        Button {
            pushGuideReference(GuideReference(guide: match.guide))
        } label: {
            ActivityRowLayout(systemImage: "map") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(guideName)
                        .font(.body)
                        .foregroundStyle(.tint)
                    if let caption = placeCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// The guide's name, falling back to the same "(Unnamed Guide)" placeholder
    /// the Guides list uses for a nameless import.
    private var guideName: String {
        let name = match.guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "(Unnamed Guide)" : name
    }

    /// The place inside the guide that triggered the match, so the row shows why
    /// it surfaced: the place name when resolved, else its address.
    private var placeCaption: String? {
        let name = match.place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let address = match.place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? nil : address
    }
}
