import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

private struct InjectedGroupUIFailure: Error {}

/// The shared group-mutation building blocks — `GroupDeletionOperation` (now
/// owned by `GroupContextMenu`), and the `GroupPresentation` helpers
/// (`GroupMutationErrorPresentation`, `GroupNamePrompt`, `GroupNameInput`). These
/// used to live on `GroupsListViewController`; the coordinator that now backs the
/// Groups list, the Favorites list, and the sidebar reuses them.
@MainActor
@Suite("Group mutation logic")
struct GroupMutationLogicTests {
    @Test
    func deletionAlwaysRemovesPersistentFavoriteWithoutConsultingCache() async throws {
        let group = ContactGroup(localID: "group-id", name: "Family")
        var calls: [String] = []
        let operation = GroupDeletionOperation<String>(
            deleteFromContacts: { _ in
                calls.append("delete")
                return nil
            },
            removeFromFavorites: { _ in calls.append("favorite") },
            finishFolderCleanup: { _ in calls.append("folder") }
        )

        let outcome = try await operation.delete(group)

        #expect(outcome.favoriteCleanupError == nil)
        #expect(outcome.pendingFolderCleanup == nil)
        #expect(calls == ["delete", "favorite"])
    }

    @Test
    func favoriteCleanupFailureIsReportedAfterSuccessfulDeletion() async throws {
        let group = ContactGroup(localID: "group-id", name: "Family")
        var deleted = false
        let operation = GroupDeletionOperation<String>(
            deleteFromContacts: { _ in
                deleted = true
                return nil
            },
            removeFromFavorites: { _ in throw InjectedGroupUIFailure() },
            finishFolderCleanup: { _ in }
        )

        let outcome = try await operation.delete(group)

        #expect(deleted)
        #expect(outcome.favoriteCleanupError is InjectedGroupUIFailure)
    }

    /// The group IS deleted; taking it out of its folder is what is still owed.
    /// That is an outcome of a successful delete, never a thrown failure — and
    /// retrying it must not delete anything again.
    @Test
    func owedFolderCleanupIsReportedAfterSuccessfulDeletionAndRetriedWithoutDeletingAgain() async throws {
        let group = ContactGroup(localID: "group-id", name: "Family")
        var calls: [String] = []
        var cleanupSucceeds = false
        let operation = GroupDeletionOperation<String>(
            deleteFromContacts: { _ in
                calls.append("delete")
                return "owed"
            },
            removeFromFavorites: { _ in calls.append("favorite") },
            finishFolderCleanup: { token in
                calls.append("folder:\(token)")
                if !cleanupSucceeds { throw InjectedGroupUIFailure() }
            }
        )

        let outcome = try await operation.delete(group)
        let pending = try #require(outcome.pendingFolderCleanup)
        #expect(outcome.favoriteCleanupError == nil)

        #expect(await operation.retryFolderCleanup(pending) == "owed")
        cleanupSucceeds = true
        #expect(await operation.retryFolderCleanup(pending) == nil)
        #expect(calls == ["delete", "favorite", "folder:owed", "folder:owed"])
    }

    @Test
    func failedDeletionThrowsAndCleansUpNothing() async {
        let group = ContactGroup(localID: "group-id", name: "Family")
        var calls: [String] = []
        let operation = GroupDeletionOperation<String>(
            deleteFromContacts: { _ in throw InjectedGroupUIFailure() },
            removeFromFavorites: { _ in calls.append("favorite") },
            finishFolderCleanup: { _ in calls.append("folder") }
        )

        await #expect(throws: InjectedGroupUIFailure.self) {
            _ = try await operation.delete(group)
        }
        #expect(calls.isEmpty)
    }

    @Test(arguments: [StoreAuthorizationStatus.denied, .restricted])
    func authorizationErrorsDirectUsersToSettings(_ status: StoreAuthorizationStatus) {
        let presentation = GroupMutationErrorPresentation.make(
            error: InjectedGroupUIFailure(),
            authorization: status
        )
        #expect(presentation.message.contains("Settings"))
        #expect(!presentation.shouldRefreshGroups)
    }

    @Test
    func missingGroupRefreshesInsteadOfBlamingAuthorization() {
        let presentation = GroupMutationErrorPresentation.make(
            error: ContactStoreError.groupNotFound(localID: "gone"),
            authorization: .denied
        )
        #expect(presentation.message.contains("already removed"))
        #expect(presentation.shouldRefreshGroups)
    }

    @Test
    func unknownAuthorizedFailureUsesNeutralRetryGuidance() {
        let presentation = GroupMutationErrorPresentation.make(
            error: InjectedGroupUIFailure(),
            authorization: .authorized
        )
        #expect(presentation.message == "Contacts couldn’t complete this change. Please try again.")
        #expect(!presentation.shouldRefreshGroups)
    }

    @Test(arguments: [("New Group", "Add", nil), ("Rename Group", "Rename", "Family")] as [(String, String, String?)])
    func namePromptMakesConfirmTheDefaultButton(title: String, actionTitle: String, initialName: String?) {
        let alert = GroupNamePrompt.makeAlert(
            title: title,
            actionTitle: actionTitle,
            initialName: initialName,
            completion: { _ in }
        )

        // Return-key binding and the emphasized button style both hang off
        // `preferredAction`; without it the two buttons read as interchangeable
        // and a hardware keyboard can't confirm the prompt.
        #expect(alert.preferredAction?.title == actionTitle)
        #expect(alert.actions.contains { $0.style == .cancel })
    }

    @Test
    func groupNameValidationTrimsAndRejectsBlankInput() {
        #expect(GroupNameInput.normalized("  Friends \n") == "Friends")
        #expect(GroupNameInput.normalized(" \n\t") == nil)
        #expect(GroupNameInput.normalized(nil) == nil)
    }
}
