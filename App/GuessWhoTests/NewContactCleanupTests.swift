import Testing
import UIKit
@testable import GuessWho

@MainActor
@Suite("New contact cleanup")
struct NewContactCleanupTests {
    @Test
    func cancelClosesTheCardAndTheRecordGoesWithIt() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.cancel()
        #expect(probe.closes == 1)
        #expect(probe.deletes == 0)

        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 1)

        // Nothing after the end adds a second delete or close.
        cleanup.cancel()
        cleanup.discard()
        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 1)
        #expect(probe.closes == 1)
    }

    @Test
    func discardDeletesOnceTheNavigationReplacesTheCard() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.discard()
        #expect(cleanup.isDiscarded)
        #expect(probe.deletes == 0)

        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 1)
        #expect(probe.closes == 0)
    }

    @Test
    func discardTakesTheUserAdditionsWithTheRecord() async {
        let probe = CleanupProbe()
        probe.isBlank = false
        let cleanup = probe.makeCleanup()

        cleanup.recordDidGetUserData()
        #expect(cleanup.hasUnsavedAdditions)

        cleanup.discard()
        #expect(!cleanup.hasUnsavedAdditions)
        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 1)
    }

    @Test
    func untouchedCardGoingAwayDeletesTheBlankRecord() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.cardDidEnd()
        await cleanup.settled()

        #expect(probe.deletes == 1)
        #expect(probe.closes == 0)
    }

    @Test
    func cardGoingAwayKeepsARecordChangedElsewhere() async {
        let probe = CleanupProbe()
        probe.isBlank = false
        let cleanup = probe.makeCleanup()

        cleanup.cardDidEnd()
        await cleanup.settled()

        #expect(probe.deletes == 0)
    }

    @Test
    func cardGoingAwayKeepsWhatTheUserAdded() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.recordDidGetUserData()
        cleanup.cardDidEnd()
        await cleanup.settled()

        #expect(probe.deletes == 0)
    }

    @Test
    func recordAnotherCardShowsIsNeverDeleted() async {
        let untouched = CleanupProbe()
        untouched.isShownElsewhere = true
        let replaced = untouched.makeCleanup()
        replaced.cardDidEnd()
        await replaced.settled()
        #expect(untouched.deletes == 0)

        let discardedProbe = CleanupProbe()
        discardedProbe.isShownElsewhere = true
        let discarded = discardedProbe.makeCleanup()
        discarded.discard()
        discarded.cardDidEnd()
        await discarded.settled()
        #expect(discardedProbe.deletes == 0)
    }

    @Test
    func savedRecordIsNeverDeleted() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: true)
        #expect(probe.keeps == 1)

        // A later Edit, failed Save, an addition and Cancel, then the card
        // going away.
        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: false)
        cleanup.recordDidGetUserData()
        #expect(!cleanup.hasUnsavedAdditions)
        cleanup.cancel()
        cleanup.discard()
        cleanup.cardDidEnd()
        await cleanup.settled()

        #expect(probe.deletes == 0)
        #expect(probe.closes == 0)
        #expect(probe.keeps == 1)
    }

    @Test
    func doneWithNothingToSaveKeepsTheRecord() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.keep()
        cleanup.cancel()
        cleanup.cardDidEnd()
        await cleanup.settled()

        #expect(probe.keeps == 1)
        #expect(probe.deletes == 0)
    }

    @Test
    func failedSaveKeepsTheRecordUntilTheEditorEnds() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: false)
        #expect(probe.keeps == 0)

        cleanup.cancel()
        #expect(probe.closes == 1)
        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 1)
    }

    @Test
    func editingAgainAfterDiscardCountsAgain() async {
        let probe = CleanupProbe()
        probe.isBlank = false
        let cleanup = probe.makeCleanup()

        // The card stayed after Discard; the user edits and the save fails.
        cleanup.discard()
        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: false)
        #expect(!cleanup.isDiscarded)

        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 0)
    }

    @Test
    func cardGoingAwayDuringASaveWaitsForItsOutcome() async {
        let saved = CleanupProbe()
        let keeps = saved.makeCleanup()
        keeps.writeDidBegin()
        keeps.cardDidEnd()
        keeps.saveDidEnd(succeeded: true)
        await keeps.settled()
        #expect(saved.deletes == 0)
        #expect(saved.keeps == 1)

        let failed = CleanupProbe()
        let deletes = failed.makeCleanup()
        deletes.writeDidBegin()
        deletes.cardDidEnd()
        await deletes.settled()
        #expect(failed.deletes == 0)
        deletes.saveDidEnd(succeeded: false)
        await deletes.settled()
        #expect(failed.deletes == 1)
    }

    @Test
    func recordTheUserDeletedIsNotDeletedAgain() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.cardDidEnd()
        cleanup.deleteDidEnd(succeeded: true)
        cleanup.cancel()
        await cleanup.settled()

        #expect(probe.deletes == 0)
    }

    @Test
    func failedUserDeleteLeavesTheRecordUnsaved() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.deleteDidEnd(succeeded: false)
        #expect(probe.deletes == 0)

        cleanup.cardDidEnd()
        await cleanup.settled()
        #expect(probe.deletes == 1)
    }

    @Test
    func releasingTheWatchedCardDecides() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        autoreleasepool {
            let card = UIViewController()
            cleanup.watch(card)
            #expect(NewContactCleanup.watching(card) === cleanup)
            #expect(NewContactCleanup.watching(UIViewController()) == nil)
            #expect(probe.deletes == 0)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.deletes == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.deletes == 1)
    }
}

@MainActor
private final class CleanupProbe {
    var deletes = 0
    var closes = 0
    var keeps = 0
    var isBlank = true
    var isShownElsewhere = false

    func makeCleanup() -> NewContactCleanup {
        let cleanup = NewContactCleanup(
            isStillBlank: { [unowned self] in isBlank },
            deleteRecord: { [unowned self] in deletes += 1 }
        )
        cleanup.close = { [unowned self] in closes += 1 }
        cleanup.isShownElsewhere = { [unowned self] in isShownElsewhere }
        cleanup.didKeep = { [unowned self] in keeps += 1 }
        return cleanup
    }
}
