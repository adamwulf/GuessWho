import Foundation
import Testing
@testable import GuessWho

/// Regression coverage for the newest-wins gate that `ContactDetailView` shares
/// between its full contact load and its targeted `addEventLink` link re-read.
///
/// The defect this locks down: a targeted reread (the user just added an event
/// link) would publish the freshly-written links, and then a SLOWER full load
/// that had begun earlier — and had already read the PRE-edit link set — would
/// finish and republish that stale snapshot, silently dropping the new link.
/// Because both paths now mint their token from the SAME `ContactLoadGeneration`,
/// the targeted reread supersedes the older full load, so the older load's
/// guarded publish is rejected.
@MainActor
@Suite("Contact load generation newest-wins")
struct ContactLoadGenerationTests {
    /// A stand-in for the view's published event-link state, so a test can
    /// assert which load actually painted the card.
    private final class PublishedLinks {
        var eventLinkIDs: [Int] = []
    }

    /// The exact publish protocol both `loadContact` and the targeted
    /// `addEventLink` reread follow: publish the read snapshot ONLY while this
    /// token is still the newest generation. Uses the production `isCurrent`
    /// guard, so a test cannot pass while the real guard is wrong.
    private func publish(
        _ ids: [Int],
        as token: UUID,
        gate: ContactLoadGeneration,
        into published: PublishedLinks
    ) {
        guard gate.isCurrent(token) else { return }
        published.eventLinkIDs = ids
    }

    /// The headline regression: a targeted reread that begins AFTER a slower
    /// full load must win, and the slower load must not restore the pre-edit
    /// links when it finally finishes.
    @Test
    func targetedRereadWinsOverEarlierSlowerFullLoad() {
        let gate = ContactLoadGeneration()
        let published = PublishedLinks()

        // 1. A full load begins first and reads the PRE-edit link set.
        let fullLoad = gate.begin()
        let preEditLinks = [1, 2]

        // 2. While that full load is still in flight, the user adds an event
        //    link. The targeted reread begins — advancing the generation — and
        //    reads the POST-edit set including the new link (3).
        let targetedReread = gate.begin()
        let postEditLinks = [1, 2, 3]

        // 3. The targeted reread publishes first: it is the newest generation.
        publish(postEditLinks, as: targetedReread, gate: gate, into: published)
        #expect(published.eventLinkIDs == postEditLinks)

        // 4. The slower full load finally finishes and tries to publish its
        //    stale pre-edit snapshot. Newest-wins must reject it, so the new
        //    link survives on the card.
        publish(preEditLinks, as: fullLoad, gate: gate, into: published)
        #expect(published.eventLinkIDs == postEditLinks)
    }

    /// The gate's raw predicate, independent of the publish helper: a superseded
    /// token is never current; the newest one always is.
    @Test
    func beginSupersedesTheTokenStillInFlight() {
        let gate = ContactLoadGeneration()

        let older = gate.begin()
        let newer = gate.begin()

        #expect(gate.isCurrent(newer))
        #expect(!gate.isCurrent(older))
    }

    /// Symmetric guard: the reread must NOT clobber a genuinely newer full load
    /// (e.g. an observable reload that began after the reread). Newest still
    /// wins regardless of which path is newer.
    @Test
    func aFreshFullLoadAfterATargetedRereadStillWins() {
        let gate = ContactLoadGeneration()
        let published = PublishedLinks()

        let reread = gate.begin()
        let newerFullLoad = gate.begin()

        // The newer full load publishes...
        publish([9], as: newerFullLoad, gate: gate, into: published)
        // ...and the now-stale reread's publish is rejected.
        publish([1], as: reread, gate: gate, into: published)

        #expect(published.eventLinkIDs == [9])
        #expect(gate.isCurrent(newerFullLoad))
        #expect(!gate.isCurrent(reread))
    }
}
