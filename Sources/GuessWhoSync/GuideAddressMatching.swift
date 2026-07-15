import Foundation

/// Best-effort matcher that answers "which imported guides does this address
/// appear in?" — the reverse of `GuidePlaceDetailView`'s "who/what is here"
/// associations. Backs the guide rows shown under a contact's postal address
/// and an event's location.
///
/// Matching reuses `EventLocationMatcher`'s street-line token logic: a needle
/// must appear as a contiguous run of ≥2 words inside the haystack, so a
/// shared city/state alone never sweeps in unrelated guides. Only the
/// direction of the needle/haystack differs between the two entry points:
///
/// * a **contact** carries a structured street line, matched as the needle
///   against each place's formatted `address` (the haystack);
/// * an **event** carries a free-text `location`, treated as the haystack that
///   each place's street line (the needle) must appear inside.
public enum GuideAddressMatcher {
    /// A guide surfaced because one of its places matched the queried address,
    /// paired with that matching place (the first one, in the guide's entry
    /// order) so the row can caption the match.
    public struct Match: Hashable, Sendable {
        public let guide: MapsGuide
        public let place: MapsPlace

        public init(guide: MapsGuide, place: MapsPlace) {
            self.guide = guide
            self.place = place
        }
    }

    /// The street-line needle for one guide place: parse the street component
    /// out of its formatted `address` (MapKit's `placemark.title`), falling
    /// back to the first comma-delimited segment (conventionally the street
    /// line). Returns nil for a place with no address — an unresolved place-ID
    /// entry, which matches nothing until its row fills in. `EventLocationMatcher`
    /// ignores needles under two words, so a bare city never leaks through.
    public static func streetNeedle(for place: MapsPlace) -> String? {
        guard let address = place.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else { return nil }
        if let parsed = PostalAddress.parse(fromFullAddress: address), !parsed.street.isEmpty {
            return parsed.street
        }
        let firstSegment = address
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? address
        return firstSegment.isEmpty ? nil : firstSegment
    }

    /// Guides whose places' addresses contain any of `streetLines` (a contact's
    /// structured street lines) as a contiguous run of words — the
    /// contact-detail direction. One `Match` per guide (the first matching
    /// place in entry order); guides in `guides` order.
    public static func guides(
        containingAnyOf streetLines: Set<String>,
        guides: [MapsGuide],
        places: [MapsPlace]
    ) -> [Match] {
        let needles = Set(
            streetLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !needles.isEmpty else { return [] }
        return matches(guides: guides, places: places) { place in
            EventLocationMatcher.matches(location: place.address, anyOf: needles)
        }
    }

    /// Guides whose places' street lines appear inside `location` (an event's
    /// free-text location) — the event-detail direction. One `Match` per guide
    /// (the first matching place in entry order); guides in `guides` order.
    public static func guides(
        appearingIn location: String?,
        guides: [MapsGuide],
        places: [MapsPlace]
    ) -> [Match] {
        guard let location,
              !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return matches(guides: guides, places: places) { place in
            guard let needle = streetNeedle(for: place) else { return false }
            return EventLocationMatcher.matches(location: location, anyOf: [needle])
        }
    }

    /// Shared reducer: bucket `places` by guide (in each guide's entry order),
    /// then for every guide (in `guides` order) emit one `Match` for the first
    /// place that satisfies `isMatch`. Guides with no matching place are
    /// dropped.
    private static func matches(
        guides: [MapsGuide],
        places: [MapsPlace],
        isMatch: (MapsPlace) -> Bool
    ) -> [Match] {
        var placesByGuide: [UUID: [MapsPlace]] = [:]
        for place in places {
            placesByGuide[place.guideID, default: []].append(place)
        }
        for guideID in placesByGuide.keys {
            placesByGuide[guideID]?.sort { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        var result: [Match] = []
        for guide in guides {
            guard let hit = placesByGuide[guide.id]?.first(where: isMatch) else { continue }
            result.append(Match(guide: guide, place: hit))
        }
        return result
    }
}
