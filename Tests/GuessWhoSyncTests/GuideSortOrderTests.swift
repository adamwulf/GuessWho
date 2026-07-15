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
    func rawValuesAreStable() {
        // Persisted in UserDefaults by the app — renaming a case is a
        // breaking change, so pin the strings.
        #expect(GuideSortOrder.nameAscending.rawValue == "nameAscending")
        #expect(GuideSortOrder.nameDescending.rawValue == "nameDescending")
        #expect(GuideSortOrder.recentlyAdded.rawValue == "recentlyAdded")
        #expect(GuideSortOrder.lastViewed.rawValue == "lastViewed")
    }
}
