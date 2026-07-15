import SwiftUI
import GuessWhoSync

/// One summary row — "This place is in N guides" — shown directly under a
/// contact's postal address or an event's location when that address appears in
/// one or more imported Apple Maps guides. Replaces the earlier
/// one-row-per-guide list: instead of jumping straight to a guide, the row opens
/// the matched place's detail (via the injected `pushPlaceReference` closure),
/// where a "Guides" section enumerates every guide the place sits in.
///
/// The first match's place is the representative handed to the place detail:
/// every match shares the queried address, so any of their place records lands
/// on an equivalent place detail, whose own guide scan re-derives the full list.
struct AddressGuidesSummaryRow: View {
    let matches: [GuideAddressMatcher.Match]

    @Environment(\.pushPlaceReference) private var pushPlaceReference

    var body: some View {
        if let place = matches.first?.place {
            Button {
                pushPlaceReference(PlaceReference(place: place))
            } label: {
                ActivityRowLayout(systemImage: "map") {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// "This place is in N guides", singular for a lone guide. `matches` holds
    /// one entry per guide (the matcher emits at most one `Match` per guide), so
    /// its count is the guide count.
    private var summary: String {
        matches.count == 1
            ? "This place is in 1 guide"
            : "This place is in \(matches.count) guides"
    }
}
