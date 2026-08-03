import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

/// Stands in for a store error with no user-facing text of its own — its
/// `localizedDescription` is the framework's generic "operation couldn't be
/// completed" wrapper, naming the type. Nothing like that may reach an alert.
private struct OpaqueFrameworkError: Error {}

/// The pure logic behind the contact lists' "Add to Group" context menu: which
/// rows a menu acts on, and what the user is told when a batch doesn't fully
/// land. Both are decided without a table view or a repository, so both are
/// testable here — see `SelectionRecencyTrackerTests` for the same split.
@Suite("Add to Group menu targets")
struct ContactContextMenuTargetsTests {
    /// String ids stand in for rows: the rule is identity-agnostic, and
    /// `ContactID` has no app-visible initializer (`docs/contact-identity.md`).
    private func targets(hit: String?, selection: [String]) -> [String] {
        ContactContextMenuTargets.targets(hitRow: hit, selection: selection, id: { $0 })
    }

    @Test
    func aRowInsideTheSelectionActsOnTheWholeSelection() {
        #expect(targets(hit: "B", selection: ["C", "B", "A"]) == ["C", "B", "A"])
    }

    @Test
    func selectionOrderIsPreservedForTheBatch() {
        // The lists hand over selection-recency order; the menu must not
        // re-order or de-duplicate it on its own.
        #expect(targets(hit: "A", selection: ["C", "A", "B"]) == ["C", "A", "B"])
    }

    @Test
    func aRowOutsideTheSelectionActsOnThatRowAlone() {
        // Right-clicking an unselected row must not sweep in what happens to be
        // selected elsewhere in the list.
        #expect(targets(hit: "D", selection: ["A", "B", "C"]) == ["D"])
    }

    @Test
    func withNothingSelectedTheHitRowIsTheTarget() {
        #expect(targets(hit: "A", selection: []) == ["A"])
    }

    @Test
    func aSingleSelectionOfTheHitRowStaysASingleTarget() {
        #expect(targets(hit: "A", selection: ["A"]) == ["A"])
    }

    @Test
    func anUnresolvableRowYieldsNoTargets() {
        // A stale index path mid-apply resolves to no contact: no targets, and
        // therefore no menu at all — never a menu that silently acts on the
        // selection the user didn't click.
        #expect(targets(hit: nil, selection: ["A", "B"]).isEmpty)
    }
}

@MainActor
@Suite("Add to Group menu copy")
struct AddToGroupCopyTests {
    private let group = ContactGroup(localID: "group-id", name: "Family")

    private func contact(_ given: String, _ family: String) -> Contact {
        Contact(givenName: given, familyName: family)
    }

    private func partialFailure(
        applied: [Contact],
        failed: [Contact],
        error: Error = ContactNotSavedError()
    ) -> GroupMembershipPartialFailureError {
        GroupMembershipPartialFailureError(
            change: .addition,
            group: group,
            applied: applied,
            failures: failed.map { .init(contact: $0, error: error) }
        )
    }

    private func partialCopy(
        applied: [Contact],
        failed: [Contact],
        error: Error = ContactNotSavedError(),
        authorization: StoreAuthorizationStatus = .authorized
    ) -> AddToGroupAlertCopy {
        .partialFailure(
            partialFailure(applied: applied, failed: failed, error: error),
            authorization: authorization
        )
    }

    // MARK: - Titles

    @Test
    func aSingleTargetIsNamedRatherThanCounted() {
        #expect(AddToGroupMenu.scopeTitle(for: [contact("Ada", "Lovelace")]) == "Ada Lovelace")
        #expect(AddToGroupMenu.addToGroupTitle(for: [contact("Ada", "Lovelace")]) == "Add to Group")
    }

    /// A selection can reach OFFSCREEN rows, so a small one is named outright
    /// rather than counted — the user must see that the contact scrolled out of
    /// view is coming along.
    @Test
    func aSmallSelectionIsNamedInBothTitles() {
        let two = [contact("Ada", "Lovelace"), contact("Alan", "Turing")]
        #expect(AddToGroupMenu.scopeTitle(for: two) == "Ada Lovelace and Alan Turing")
        #expect(AddToGroupMenu.addToGroupTitle(for: two)
            == "Add Ada Lovelace and Alan Turing to Group")

        let three = two + [contact("Grace", "Hopper")]
        #expect(AddToGroupMenu.scopeTitle(for: three).contains("Grace Hopper"))
        #expect(AddToGroupMenu.addToGroupTitle(for: three).hasPrefix("Add Ada Lovelace"))
        #expect(AddToGroupMenu.addToGroupTitle(for: three).hasSuffix("to Group"))
    }

    @Test
    func aSelectionPastTheNamingThresholdIsCounted() {
        let contacts = (1...4).map { contact("Contact", "\($0)") }
        #expect(AddToGroupMenu.scopeTitle(for: contacts) == "4 Contacts")
        // Repeated on the action itself: a menu header isn't guaranteed to be
        // visible on every platform, and the scope must never be a guess.
        #expect(AddToGroupMenu.addToGroupTitle(for: contacts) == "Add 4 Contacts to Group")
        // No half-named list: past the threshold the count stands alone.
        #expect(!AddToGroupMenu.addToGroupTitle(for: contacts).contains("Contact 1"))
    }

    // MARK: - Partial failure (the batch RAN)

    @Test
    func aPartialFailureSaysHowManyEndedInTheGroupAndNamesTheOnesThatDidnt() {
        let copy = partialCopy(
            applied: [contact("Ada", "Lovelace"), contact("Alan", "Turing")],
            failed: [contact("Grace", "Hopper")]
        )

        #expect(copy.title == "Couldn’t Add Every Contact")
        #expect(copy.message.contains("2 of 3 contacts are in “Family.”"))
        #expect(copy.message.contains("Grace Hopper"))
    }

    /// `applied` counts contacts that were ALREADY members and needed no write,
    /// so the copy must describe the resulting state instead of claiming credit
    /// for adds that never happened.
    @Test
    func anAlreadyMemberIsNotClaimedAsANewAdd() {
        // Ada was already in Family, Alan was genuinely added, Grace failed.
        let copy = partialCopy(
            applied: [contact("Ada", "Lovelace"), contact("Alan", "Turing")],
            failed: [contact("Grace", "Hopper")]
        )

        #expect(copy.message.contains("are in"))
        #expect(!copy.message.contains("were added to “Family"))
    }

    @Test
    func anAllFailedBatchSaysNoneAreInTheGroupRatherThanZeroOfThree() {
        let copy = partialCopy(
            applied: [],
            failed: [contact("Ada", "Lovelace"), contact("Alan", "Turing")]
        )

        #expect(copy.message.contains("None of these 2 contacts are in “Family.”"))
        #expect(!copy.message.contains("0 of 2"))
    }

    @Test
    func aOneContactBatchReportsWhatStoppedItInsteadOfCounting() {
        let copy = partialCopy(applied: [], failed: [contact("Ada", "Lovelace")])

        #expect(copy.title == "Couldn’t Add to “Family”")
        // The package's own product copy for a never-saved contact — it says
        // something the generic mapper can't — and never "0 of 1 contacts…".
        #expect(copy.message == ContactNotSavedError().localizedDescription)
        #expect(!copy.message.contains("0 of 1"))
    }

    /// A store error's `localizedDescription` can be raw framework text, so
    /// anything that isn't package-authored user copy goes through the same
    /// mapper the Groups tab uses.
    @Test
    func aOneContactBatchNeverPrintsRawFrameworkText() {
        let copy = partialCopy(
            applied: [],
            failed: [contact("Ada", "Lovelace")],
            error: OpaqueFrameworkError()
        )

        #expect(!copy.message.contains("OpaqueFrameworkError"))
        #expect(copy.message == "Contacts couldn’t complete this change. Please try again.")
    }

    @Test
    func aOneContactBatchDirectsToSettingsWhenAccessIsDenied() {
        let copy = partialCopy(
            applied: [],
            failed: [contact("Ada", "Lovelace")],
            error: OpaqueFrameworkError(),
            authorization: .denied
        )

        #expect(copy.message.contains("Settings"))
    }

    @Test
    func aLongFailureListIsCapped() {
        let failed = (1...7).map { contact("Contact", "\($0)") }
        let copy = partialCopy(applied: [], failed: failed)

        #expect(copy.message.contains("Contact 1"))
        #expect(copy.message.contains("2 more"))
        #expect(!copy.message.contains("Contact 7"))
    }

    // MARK: - Pre-flight failure (NOTHING was attempted)

    @Test
    func aPreflightFailureSaysNothingWasAdded() {
        let copy = AddToGroupAlertCopy.nothingAttempted(
            contactCount: 3,
            groupName: "Family",
            reason: "This group was already removed."
        )

        #expect(copy.title == "Couldn’t Add to “Family”")
        #expect(copy.message.contains("This group was already removed."))
        #expect(copy.message.contains("None of these 3 contacts were added."))
    }

    @Test
    func aPreflightFailureForOneContactReadsSingular() {
        let copy = AddToGroupAlertCopy.nothingAttempted(
            contactCount: 1,
            groupName: "Family",
            reason: "Contacts couldn’t complete this change. Please try again."
        )

        #expect(copy.message.contains("This contact wasn’t added."))
    }

    @Test
    func aFailedGroupCreationIsReportedAsSuch() {
        let copy = AddToGroupAlertCopy.groupCreationFailed(reason: "Please try again.")

        #expect(copy.title == "Couldn’t Create Group")
        #expect(copy.message == "Please try again.")
    }

    // MARK: - Product vocabulary

    @Test
    func noCopyLeaksInternalVocabulary() {
        let copies: [AddToGroupAlertCopy] = [
            partialCopy(
                applied: [contact("Ada", "Lovelace")],
                failed: [contact("Alan", "Turing")]
            ),
            .nothingAttempted(contactCount: 2, groupName: "Family", reason: "Please try again."),
            .groupCreationFailed(reason: "Please try again."),
        ]
        let forbidden = ["sidecar", "reconcile", "EventKit", "localID", "unlink", "GuessWho"]

        for copy in copies {
            let text = "\(copy.title) \(copy.message)"
            for term in forbidden {
                #expect(!text.localizedCaseInsensitiveContains(term), "\(term) leaked into: \(text)")
            }
        }
    }

    // MARK: - Group naming

    @Test
    func anUnnamedGroupStillReadsAsAGroup() {
        #expect(ContactGroup(localID: "id", name: "  ").displayName == "(Unnamed Group)")
        #expect(ContactGroup(localID: "id", name: " Family ").displayName == "Family")
    }
}
