import Foundation
import Testing
@testable import GuessWho

/// Exercises the ordering rules behind the multi-selection contact stack: the
/// front card is the contact the user most recently added to the selection.
///
/// Uses `String` ids rather than `ContactID` — the tracker is generic precisely
/// because `ContactID` has no app-visible initializer (its stored properties are
/// `package`; see `docs/contact-identity.md`), and the ordering rules under test
/// are identity-agnostic.
@MainActor
@Suite("Selection recency ordering")
struct SelectionRecencyTrackerTests {
    private func tracker(selecting ids: [String]) -> SelectionRecencyTracker<String> {
        let tracker = SelectionRecencyTracker<String>()
        for id in ids {
            tracker.recordSelection(of: id)
        }
        return tracker
    }

    @Test
    func mostRecentlySelectedSortsFirst() {
        let tracker = tracker(selecting: ["A", "B", "C"])

        // The table reports its rows in list order; the stack wants the reverse
        // of the pick order.
        #expect(tracker.order(["A", "B", "C"]) == ["C", "B", "A"])
    }

    @Test
    func reselectingARowMovesItBackToTheFront() {
        let tracker = tracker(selecting: ["A", "B", "C"])

        tracker.recordDeselection(of: "A")
        #expect(tracker.order(["B", "C"]) == ["C", "B"])

        tracker.recordSelection(of: "A")
        #expect(tracker.order(["A", "B", "C"]) == ["A", "C", "B"])
    }

    @Test
    func untrackedIDsKeepListOrderBehindTheTrackedOnes() {
        // Only B came through a selection callback — A and C were selected
        // programmatically (or before this tracker existed), so they keep their
        // (section, row) order at the end instead of being dropped.
        let tracker = tracker(selecting: ["B"])

        #expect(tracker.order(["A", "B", "C"]) == ["B", "A", "C"])
    }

    @Test
    func orderingIsAlwaysAPermutationOfTheReportedSelection() {
        let tracker = tracker(selecting: ["A", "B", "C"])

        // The table is the source of truth for membership: an id the tracker
        // knows about but the table no longer reports must not come back...
        #expect(tracker.order(["B", "C"]) == ["C", "B"])
        // ...and an id the table reports but the tracker never saw must not be
        // dropped.
        #expect(tracker.order(["B", "C", "D"]) == ["C", "B", "D"])
    }

    @Test
    func duplicateSelectionsAreNotDuplicatedInTheResult() {
        let tracker = tracker(selecting: ["A", "B", "A"])

        // Re-recording A only re-stamps it — the result still carries one entry
        // per reported id.
        #expect(tracker.order(["A", "B"]) == ["A", "B"])
    }

    @Test
    func stampsAreDroppedForRowsTheTableStoppedReporting() {
        let tracker = tracker(selecting: ["A", "B"])

        // A diffable apply removes B's row: the table drops the selection
        // without a deselect callback, so the prune has to happen here.
        #expect(tracker.order(["A"]) == ["A"])

        // B comes back (a reload re-inserts the row and something reselects it
        // programmatically). Its old stamp is gone, so it sorts as untracked
        // behind A rather than resurrecting its stale "newer than A" position.
        #expect(tracker.order(["A", "B"]) == ["A", "B"])
    }

    @Test
    func clearingTheSelectionForgetsEverything() {
        let tracker = tracker(selecting: ["A", "B", "C"])

        #expect(tracker.order([]).isEmpty)

        // Fresh start: the stack order comes only from picks made after the
        // clear, not from anything remembered across it.
        tracker.recordSelection(of: "C")
        #expect(tracker.order(["A", "B", "C"]) == ["C", "A", "B"])
    }
}
