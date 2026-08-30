import Testing
@testable import GuessWho

@MainActor
@Suite("Contact viewed stamp scheduler")
struct ContactViewedStampSchedulerTests {
    @Test
    func schedulesAfterLoadSettlesAndOnlyOnce() async {
        let scheduler = ContactViewedStampScheduler()
        let probe = ViewedStampProbe()

        scheduler.schedule {
            #expect(probe.visibleLoadSettled)
            probe.invocationCount += 1
        }
        scheduler.schedule {
            probe.invocationCount += 100
        }

        // schedule() itself never awaits the stamp: while this main-actor turn
        // remains active, the utility task cannot have entered the operation.
        #expect(probe.invocationCount == 0)
        #expect(scheduler.hasScheduled)

        probe.visibleLoadSettled = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.invocationCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(probe.invocationCount == 1)
    }
}

@MainActor
private final class ViewedStampProbe {
    var visibleLoadSettled = false
    var invocationCount = 0
}
