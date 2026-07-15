import Foundation
import Testing
@testable import GuessWhoSync

@Suite("GuideAddressMatcher (pure)")
struct GuideAddressMatcherTests {
    private func guide(_ name: String) -> MapsGuide {
        MapsGuide(id: UUID(), name: name)
    }

    private func place(
        guide: MapsGuide,
        address: String?,
        name: String = "",
        sortOrder: Int = 0
    ) -> MapsPlace {
        MapsPlace(id: UUID(), guideID: guide.id, name: name, address: address, sortOrder: sortOrder)
    }

    // MARK: - Contact direction: contact street line inside place address

    @Test
    func contactStreetLineMatchesPlaceAddress() {
        let berlin = guide("Berlin")
        let places = [place(guide: berlin, address: "1 Infinite Loop, Cupertino, CA 95014", name: "Apple")]
        let matches = GuideAddressMatcher.guides(
            containingAnyOf: ["1 Infinite Loop"], guides: [berlin], places: places
        )
        #expect(matches.map(\.guide.id) == [berlin.id])
        #expect(matches.first?.place.name == "Apple")
    }

    @Test
    func contactMatchIgnoresCityOnly() {
        // A one-word / city-only needle must not sweep the guide in.
        let berlin = guide("Berlin")
        let places = [place(guide: berlin, address: "1 Infinite Loop, Cupertino, CA")]
        #expect(GuideAddressMatcher.guides(
            containingAnyOf: ["Cupertino"], guides: [berlin], places: places
        ).isEmpty)
    }

    @Test
    func contactEmptyNeedlesMatchNothing() {
        let berlin = guide("Berlin")
        let places = [place(guide: berlin, address: "1 Infinite Loop")]
        #expect(GuideAddressMatcher.guides(
            containingAnyOf: ["", "   "], guides: [berlin], places: places
        ).isEmpty)
    }

    // MARK: - Event direction: place street line inside event location

    @Test
    func placeStreetLineAppearsInEventLocation() {
        let sf = guide("SF")
        let places = [place(guide: sf, address: "500 Terry A Francois Blvd, San Francisco, CA")]
        let matches = GuideAddressMatcher.guides(
            appearingIn: "Standup — 500 Terry A Francois Blvd", guides: [sf], places: places
        )
        #expect(matches.map(\.guide.id) == [sf.id])
    }

    @Test
    func eventLocationNilOrEmptyMatchesNothing() {
        let sf = guide("SF")
        let places = [place(guide: sf, address: "500 Terry A Francois Blvd")]
        #expect(GuideAddressMatcher.guides(appearingIn: nil, guides: [sf], places: places).isEmpty)
        #expect(GuideAddressMatcher.guides(appearingIn: "  ", guides: [sf], places: places).isEmpty)
    }

    @Test
    func unresolvedPlaceWithNoAddressMatchesNothing() {
        // A place-ID entry not yet resolved has no address — no street needle,
        // so it can't appear in any event location.
        let sf = guide("SF")
        let places = [place(guide: sf, address: nil)]
        #expect(GuideAddressMatcher.guides(
            appearingIn: "meeting at 1 Infinite Loop", guides: [sf], places: places
        ).isEmpty)
    }

    // MARK: - Dedup + ordering

    @Test
    func oneMatchPerGuideEvenWithMultipleMatchingPlaces() {
        let berlin = guide("Berlin")
        // Two matching places; the guide surfaces once, on the first in entry
        // order (sortOrder 0).
        let places = [
            place(guide: berlin, address: "1 Infinite Loop, Cupertino", name: "second", sortOrder: 1),
            place(guide: berlin, address: "1 Infinite Loop, Cupertino", name: "first", sortOrder: 0),
        ]
        let matches = GuideAddressMatcher.guides(
            containingAnyOf: ["1 Infinite Loop"], guides: [berlin], places: places
        )
        #expect(matches.count == 1)
        #expect(matches.first?.place.name == "first")
    }

    @Test
    func resultsFollowGuideOrder() {
        let a = guide("A")
        let b = guide("B")
        let places = [
            place(guide: b, address: "1 Infinite Loop"),
            place(guide: a, address: "1 Infinite Loop"),
        ]
        let matches = GuideAddressMatcher.guides(
            containingAnyOf: ["1 Infinite Loop"], guides: [a, b], places: places
        )
        #expect(matches.map(\.guide.id) == [a.id, b.id])
    }
}
