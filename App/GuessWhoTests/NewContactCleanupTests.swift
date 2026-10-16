import Testing
import UIKit
@testable import GuessWho

@MainActor
@Suite("New contact cleanup")
struct NewContactCleanupTests {
    @Test
    func cancelDeletesOnceAndClosesTheCard() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.cancel()
        #expect(probe.deletes == 1)
        #expect(probe.closes == 1)

        // Closing releases the card; that and a second Cancel add nothing.
        cleanup.cardDidEnd()
        cleanup.cancel()
        cleanup.discard()
        #expect(probe.deletes == 1)
        #expect(probe.closes == 1)
    }

    @Test
    func discardDeletesAndLeavesTheCardToTheNavigation() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.discard()
        cleanup.cardDidEnd()

        #expect(probe.deletes == 1)
        #expect(probe.closes == 0)
    }

    @Test
    func cardGoingAwayUnsavedDeletes() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.cardDidEnd()

        #expect(probe.deletes == 1)
        #expect(probe.closes == 0)
    }

    @Test
    func savedRecordIsNeverDeleted() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: true)
        // A later Edit, Save and Cancel, then the card going away.
        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: false)
        cleanup.cancel()
        cleanup.discard()
        cleanup.cardDidEnd()

        #expect(probe.deletes == 0)
        #expect(probe.closes == 0)
    }

    @Test
    func doneWithNothingToSaveKeepsTheRecord() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.keep()
        cleanup.cancel()
        cleanup.cardDidEnd()

        #expect(probe.deletes == 0)
    }

    @Test
    func failedSaveKeepsTheRecordUntilTheEditorEnds() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.saveDidEnd(succeeded: false)
        #expect(probe.deletes == 0)

        cleanup.cancel()
        #expect(probe.deletes == 1)
    }

    @Test
    func cardGoingAwayDuringASaveWaitsForItsOutcome() {
        let saved = CleanupProbe()
        let keeps = saved.makeCleanup()
        keeps.writeDidBegin()
        keeps.cardDidEnd()
        #expect(saved.deletes == 0)
        keeps.saveDidEnd(succeeded: true)
        #expect(saved.deletes == 0)

        let failed = CleanupProbe()
        let deletes = failed.makeCleanup()
        deletes.writeDidBegin()
        deletes.cardDidEnd()
        #expect(failed.deletes == 0)
        deletes.saveDidEnd(succeeded: false)
        #expect(failed.deletes == 1)
    }

    @Test
    func recordTheUserDeletedIsNotDeletedAgain() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.cardDidEnd()
        cleanup.deleteDidEnd(succeeded: true)
        cleanup.cancel()

        #expect(probe.deletes == 0)
    }

    @Test
    func failedUserDeleteLeavesTheRecordUnsaved() {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        cleanup.writeDidBegin()
        cleanup.deleteDidEnd(succeeded: false)
        #expect(probe.deletes == 0)

        cleanup.cardDidEnd()
        #expect(probe.deletes == 1)
    }

    @Test
    func releasingTheWatchedCardDeletes() async {
        let probe = CleanupProbe()
        let cleanup = probe.makeCleanup()

        autoreleasepool {
            let card = UIViewController()
            cleanup.watch(card)
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

    func makeCleanup() -> NewContactCleanup {
        let cleanup = NewContactCleanup { [unowned self] in deletes += 1 }
        cleanup.close = { [unowned self] in closes += 1 }
        return cleanup
    }
}
