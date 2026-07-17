import Foundation
import Testing
@testable import GuessWhoSync

@Suite("AllPlacesSortOrder")
struct AllPlacesSortOrderTests {
    /// Fixed UUIDs so tiebreak assertions are deterministic.
    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let idC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!
    private let guideOne = UUID(uuidString: "11111111-0000-0000-0000-000000000000")!
    private let guideTwo = UUID(uuidString: "22222222-0000-0000-0000-000000000000")!

    private func place(
        id: UUID,
        guideID: UUID? = nil,
        name: String = "",
        address: String? = nil,
        sortOrder: Int = 0,
        createdAt: TimeInterval? = nil,
        lastViewedAt: TimeInterval? = nil
    ) -> MapsPlace {
        MapsPlace(
            id: id,
            guideID: guideID ?? guideOne,
            name: name,
            address: address,
            sortOrder: sortOrder,
            createdAt: createdAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            lastViewedAt: lastViewedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    @Test
    func byGuideSortsOneGuidesPlacesByEntryOrder() {
        // Callers pass one guide's places at a time; the grouping into
        // sections is the app's job.
        let places = [
            place(id: idA, name: "Zoo", sortOrder: 2),
            place(id: idB, name: "Aquarium", sortOrder: 0),
            place(id: idC, name: "Museum", sortOrder: 1),
        ]
        let sorted = AllPlacesSortOrder.byGuide.sorted(places)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func nameAscendingIsFlatAcrossGuidesAndUsesDisplayKey() {
        // idB has no name → its address is the display key ("Bakery Lane"),
        // and its different guide must not affect the flat order.
        let places = [
            place(id: idA, guideID: guideTwo, name: "Cafe"),
            place(id: idB, guideID: guideOne, name: "", address: "Bakery Lane 1"),
            place(id: idC, guideID: guideTwo, name: "aquarium"),
        ]
        let sorted = AllPlacesSortOrder.nameAscending.sorted(places)
        #expect(sorted.map(\.id) == [idC, idB, idA])
    }

    @Test
    func nameDescendingReversesTheNameOrder() {
        let places = [
            place(id: idA, name: "Cafe"),
            place(id: idB, name: "Bakery"),
            place(id: idC, name: "aquarium"),
        ]
        let sorted = AllPlacesSortOrder.nameDescending.sorted(places)
        #expect(sorted.map(\.id) == [idA, idB, idC])
    }

    @Test
    func recentlyAddedSortsNewestFirstWithUndatedLast() {
        let places = [
            place(id: idA, name: "A", createdAt: nil),
            place(id: idB, name: "B", createdAt: 50),
            place(id: idC, name: "C", createdAt: 90),
        ]
        let sorted = AllPlacesSortOrder.recentlyAdded.sorted(places)
        #expect(sorted.map(\.id) == [idC, idB, idA])
    }

    @Test
    func lastViewedSortsMostRecentFirstWithNeverViewedLast() {
        let places = [
            place(id: idA, lastViewedAt: nil),
            place(id: idB, lastViewedAt: 90),
            place(id: idC, lastViewedAt: 50),
        ]
        let sorted = AllPlacesSortOrder.lastViewed.sorted(places)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func flatTiesIgnoreEntryOrderAndFallBackToDisplayKeyThenID() {
        // Same (nil) stamp → display key decides, NOT the per-guide entry
        // position (cross-guide entry positions are unrelated). idB and idA
        // then share a name, so the UUID string breaks that tie.
        let places = [
            place(id: idB, guideID: guideTwo, name: "Same", sortOrder: 0, lastViewedAt: nil),
            place(id: idC, guideID: guideOne, name: "Different", sortOrder: 9, lastViewedAt: nil),
            place(id: idA, guideID: guideOne, name: "Same", sortOrder: 5, lastViewedAt: nil),
        ]
        let sorted = AllPlacesSortOrder.lastViewed.sorted(places)
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func onlyByGuideIsGrouped() {
        #expect(!AllPlacesSortOrder.byGuide.isFlat)
        #expect(AllPlacesSortOrder.nameAscending.isFlat)
        #expect(AllPlacesSortOrder.nameDescending.isFlat)
        #expect(AllPlacesSortOrder.recentlyAdded.isFlat)
        #expect(AllPlacesSortOrder.lastViewed.isFlat)
    }

    @Test
    func rawValuesAreStable() {
        // Persisted in UserDefaults by the app — renaming a case is a
        // breaking change, so pin the strings.
        #expect(AllPlacesSortOrder.byGuide.rawValue == "byGuide")
        #expect(AllPlacesSortOrder.nameAscending.rawValue == "nameAscending")
        #expect(AllPlacesSortOrder.nameDescending.rawValue == "nameDescending")
        #expect(AllPlacesSortOrder.recentlyAdded.rawValue == "recentlyAdded")
        #expect(AllPlacesSortOrder.lastViewed.rawValue == "lastViewed")
    }
}
