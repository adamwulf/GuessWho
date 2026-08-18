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
        let operation = GroupDeletionOperation(
            deleteFromContacts: { _ in calls.append("delete") },
            removeFromFavorites: { _ in calls.append("favorite") }
        )

        let cleanupError = try await operation.delete(group)

        #expect(cleanupError == nil)
        #expect(calls == ["delete", "favorite"])
    }

    @Test
    func favoriteCleanupFailureIsReportedAfterSuccessfulDeletion() async throws {
        let group = ContactGroup(localID: "group-id", name: "Family")
        var deleted = false
        let operation = GroupDeletionOperation(
            deleteFromContacts: { _ in deleted = true },
            removeFromFavorites: { _ in throw InjectedGroupUIFailure() }
        )

        let cleanupError = try await operation.delete(group)

        #expect(deleted)
        #expect(cleanupError is InjectedGroupUIFailure)
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
