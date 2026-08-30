import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

/// Regression coverage for `performInitialLoad`'s viewed-stamp arming, factored
/// into `ContactViewedStampScheduler.armViewedStamp(resolved:fallback:_:)`.
///
/// The defect this locks down: the stamp used to be armed only `if let stampID =
/// loadedContactID`. When the initial load was SUPERSEDED by a newer load, its
/// own publish was rejected by the newest-wins gate, so `loadedContactID` could
/// still be nil at the arming point — and the open went unstamped for the whole
/// appearance (the scheduler fires once per view instance and `performInitialLoad`
/// runs once). Arming is now unconditional: prefer the winning resolved identity,
/// fall back to the nav id.
@MainActor
@Suite("Viewed stamp arming")
struct ViewedStampArmingTests {
    /// Records every id handed to the stamp closure, so a test can assert the
    /// open was recorded and which identity it targeted.
    @MainActor
    private final class StampRecorder {
        var stampedIDs: [ContactID] = []
    }

    /// A distinct `ContactID` keyed on a fresh GuessWho UUID (via the contact's
    /// `guesswho://contact/<uuid>` URL), so a `resolved` and a `fallback` id
    /// compare unequal.
    private func contactID(guessWhoUUID: UUID = UUID()) -> ContactID {
        Contact(urlAddresses: [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/\(guessWhoUUID.uuidString)"),
        ]).contactID
    }

    /// Poll until the recorder has captured `target` stamps, or the deadline
    /// passes — the stamp fires on an unstructured utility task a turn later.
    private func stampCount(reaching target: Int, in recorder: StampRecorder) async -> Int {
        let deadline = ContinuousClock.now + .seconds(2)
        while recorder.stampedIDs.count < target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recorder.stampedIDs.count
    }

    /// The headline FIX 3 case: a superseded initial load (its own publish
    /// rejected, so `resolved` is still nil) MUST still record the open, using
    /// the nav-id fallback.
    @Test
    func supersededInitialLoadStampsTheOpenWithNavIDFallback() async {
        let scheduler = ContactViewedStampScheduler()
        let recorder = StampRecorder()
        let nav = contactID()

        scheduler.armViewedStamp(resolved: nil, fallback: nav) { stampID in
            recorder.stampedIDs.append(stampID)
        }

        #expect(await stampCount(reaching: 1, in: recorder) == 1)
        #expect(recorder.stampedIDs == [nav])
    }

    /// When the load DID win, the stamp targets the winning resolved identity —
    /// carrying any adopted GuessWho id — not the nav fallback.
    @Test
    func armingPrefersTheWinningResolvedIdentity() async {
        let scheduler = ContactViewedStampScheduler()
        let recorder = StampRecorder()
        let nav = contactID()
        let resolved = contactID()

        scheduler.armViewedStamp(resolved: resolved, fallback: nav) { stampID in
            recorder.stampedIDs.append(stampID)
        }

        #expect(await stampCount(reaching: 1, in: recorder) == 1)
        #expect(recorder.stampedIDs == [resolved])
        #expect(recorder.stampedIDs != [nav])
    }

    /// The stamp remains exactly-once even across a second arming (a reappearance
    /// of the same view instance).
    @Test
    func theOpenIsStampedExactlyOnce() async {
        let scheduler = ContactViewedStampScheduler()
        let recorder = StampRecorder()
        let nav = contactID()

        scheduler.armViewedStamp(resolved: nil, fallback: nav) { stampID in
            recorder.stampedIDs.append(stampID)
        }
        scheduler.armViewedStamp(resolved: nil, fallback: nav) { stampID in
            recorder.stampedIDs.append(stampID)
        }

        #expect(await stampCount(reaching: 1, in: recorder) == 1)
        // Settle, then confirm the second arming produced no second stamp.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.stampedIDs == [nav])
    }
}
