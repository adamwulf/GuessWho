import Foundation
import Testing
@testable import GuessWhoSync

@Suite("PlaceSortOrder")
struct PlaceSortOrderTests {
    /// Fixed UUIDs so tiebreak assertions are deterministic.
    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let idC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!
    private let guideID = UUID(uuidString: "11111111-0000-0000-0000-000000000000")!

    private func place(
        id: UUID,
        name: String = "",
        address: String? = nil,
        sortOrder: Int,
        lastViewedAt: TimeInterval? = nil
    ) -> MapsPlace {
        MapsPlace(
            id: id,
            guideID: guideID,
            name: name,
            address: address,
            sortOrder: sortOrder,
            lastViewedAt: lastViewedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    @Test
    func guideOrderSortsBySortOrder() {
        let places = [
            place(id: idA, name: "Zoo", sortOrder: 2),
            place(id: idB, name: "Aquarium", sortOrder: 0),
            place(id: idC, name: "Museum", sortOrder: 1),
        ]
        let sorted = PlaceSortOrder.guideOrder.sorted(places)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func nameAscendingUsesDisplayKeyFallingBackToAddress() {
        // idB has no name → its address is the display key ("Bakery Lane"),
        // so it sorts between "Aquarium" and "Cafe".
        let places = [
            place(id: idA, name: "Cafe", sortOrder: 0),
            place(id: idB, name: "", address: "Bakery Lane 1", sortOrder: 1),
            place(id: idC, name: "aquarium", sortOrder: 2),
        ]
        let sorted = PlaceSortOrder.nameAscending.sorted(places)
        #expect(sorted.map(\.id) == [idC, idB, idA])
    }

    @Test
    func nameDescendingReversesTheNameOrder() {
        let places = [
            place(id: idA, name: "Cafe", sortOrder: 0),
            place(id: idB, name: "Bakery", sortOrder: 1),
            place(id: idC, name: "aquarium", sortOrder: 2),
        ]
        let sorted = PlaceSortOrder.nameDescending.sorted(places)
        #expect(sorted.map(\.id) == [idA, idB, idC])
    }

    @Test
    func lastViewedSortsMostRecentFirstWithNeverViewedLast() {
        let places = [
            place(id: idA, sortOrder: 0, lastViewedAt: nil),
            place(id: idB, sortOrder: 1, lastViewedAt: 90),
            place(id: idC, sortOrder: 2, lastViewedAt: 50),
        ]
        let sorted = PlaceSortOrder.lastViewed.sorted(places)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func lastViewedTiesFallBackToGuideOrderThenID() {
        // Same (nil) stamp → guide order decides; same sortOrder too → UUID
        // string decides, so repeat sorts can't shuffle rows.
        let places = [
            place(id: idB, sortOrder: 5, lastViewedAt: nil),
            place(id: idC, sortOrder: 1, lastViewedAt: nil),
            place(id: idA, sortOrder: 5, lastViewedAt: nil),
        ]
        let sorted = PlaceSortOrder.lastViewed.sorted(places)
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func rawValuesAreStable() {
        // Persisted in UserDefaults by the app — renaming a case is a
        // breaking change, so pin the strings.
        #expect(PlaceSortOrder.guideOrder.rawValue == "guideOrder")
        #expect(PlaceSortOrder.nameAscending.rawValue == "nameAscending")
        #expect(PlaceSortOrder.nameDescending.rawValue == "nameDescending")
        #expect(PlaceSortOrder.lastViewed.rawValue == "lastViewed")
    }
}
