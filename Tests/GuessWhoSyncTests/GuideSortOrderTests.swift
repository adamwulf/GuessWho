import Foundation
import Testing
@testable import GuessWhoSync

@Suite("GuideSortOrder")
struct GuideSortOrderTests {
    /// Fixed UUIDs so tiebreak assertions are deterministic.
    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let idC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!

    private func guide(
        id: UUID,
        name: String,
        createdAt: TimeInterval? = nil,
        lastViewedAt: TimeInterval? = nil
    ) -> MapsGuide {
        MapsGuide(
            id: id,
            name: name,
            createdAt: createdAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            lastViewedAt: lastViewedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    @Test
    func nameAscendingSortsAToZCaseInsensitively() {
        let guides = [
            guide(id: idA, name: "berlin"),
            guide(id: idB, name: "Amsterdam"),
            guide(id: idC, name: "Cairo"),
        ]
        let sorted = GuideSortOrder.nameAscending.sorted(guides)
        #expect(sorted.map(\.name) == ["Amsterdam", "berlin", "Cairo"])
    }

    @Test
    func nameDescendingSortsZToACaseInsensitively() {
        let guides = [
            guide(id: idA, name: "berlin"),
            guide(id: idB, name: "Amsterdam"),
            guide(id: idC, name: "Cairo"),
        ]
        let sorted = GuideSortOrder.nameDescending.sorted(guides)
        #expect(sorted.map(\.name) == ["Cairo", "berlin", "Amsterdam"])
    }

    @Test
    func recentlyAddedSortsNewestFirstWithNilsLast() {
        let guides = [
            guide(id: idA, name: "A", createdAt: 50),
            guide(id: idB, name: "B", createdAt: nil),
            guide(id: idC, name: "C", createdAt: 90),
        ]
        let sorted = GuideSortOrder.recentlyAdded.sorted(guides)
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func lastViewedSortsMostRecentFirstWithNeverViewedLast() {
        let guides = [
            guide(id: idA, name: "A", lastViewedAt: nil),
            guide(id: idB, name: "B", lastViewedAt: 90),
            guide(id: idC, name: "C", lastViewedAt: 50),
        ]
        let sorted = GuideSortOrder.lastViewed.sorted(guides)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func timeOrderTiesFallBackToNameThenID() {
        // Same lastViewed stamp → name decides; same name too → UUID string
        // decides, so repeat sorts can't shuffle rows.
        let guides = [
            guide(id: idB, name: "same", lastViewedAt: 70),
            guide(id: idC, name: "alpha", lastViewedAt: 70),
            guide(id: idA, name: "same", lastViewedAt: 70),
        ]
        let sorted = GuideSortOrder.lastViewed.sorted(guides)
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func placeCountSortsMostPlacesFirst() {
        let guides = [
            guide(id: idA, name: "A"),
            guide(id: idB, name: "B"),
            guide(id: idC, name: "C"),
        ]
        let counts: [UUID: Int] = [idA: 3, idB: 12, idC: 7]
        let sorted = GuideSortOrder.placeCount.sorted(guides) { counts[$0] ?? 0 }
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func placeCountTiesFallBackToNameThenID() {
        // Equal counts → name decides; same name too → UUID string decides,
        // so repeat sorts of equal-count guides can't shuffle rows.
        let guides = [
            guide(id: idB, name: "same"),
            guide(id: idC, name: "alpha"),
            guide(id: idA, name: "same"),
        ]
        let counts: [UUID: Int] = [idA: 5, idB: 5, idC: 5]
        let sorted = GuideSortOrder.placeCount.sorted(guides) { counts[$0] ?? 0 }
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func placeCountConvenienceSortTreatsEveryCountAsZero() {
        // The no-lookup convenience overload can't know counts, so under
        // `.placeCount` every guide ties at 0 and the name→UUID tiebreak
        // orders them — matching the documented degrade behavior.
        let guides = [
            guide(id: idA, name: "berlin"),
            guide(id: idB, name: "Amsterdam"),
            guide(id: idC, name: "Cairo"),
        ]
        let sorted = GuideSortOrder.placeCount.sorted(guides)
        #expect(sorted.map(\.name) == ["Amsterdam", "berlin", "Cairo"])
    }

    @Test
    func rawValuesAreStable() {
        // Persisted in UserDefaults by the app — renaming a case is a
        // breaking change, so pin the strings.
        #expect(GuideSortOrder.nameAscending.rawValue == "nameAscending")
        #expect(GuideSortOrder.nameDescending.rawValue == "nameDescending")
        #expect(GuideSortOrder.recentlyAdded.rawValue == "recentlyAdded")
        #expect(GuideSortOrder.lastViewed.rawValue == "lastViewed")
        #expect(GuideSortOrder.placeCount.rawValue == "placeCount")
    }
}
