import Foundation
import GuessWhoSync

/// What a group or folder member list says about the rows it is — or is not —
/// showing. Pure, so the wording rules are testable without a table view.
///
/// A folder's members come from several fetches, and the one thing this list
/// must never do is pass a partial answer off as the whole one. So "no members"
/// is said only when every group loaded and none has a member; a folder with no
/// groups says so; and when a group could not be loaded the list says THAT,
/// offers Retry, and does not guess at emptiness.
struct GroupMemberListPresentation: Equatable {
    /// Centered message, or nil when rows are showing or the first load is still
    /// in flight.
    var emptyMessage: String?
    /// The first load has not landed yet.
    var showsSpinner: Bool
    /// Some groups could not be loaded: show the banner with its Retry.
    var showsPartialBanner: Bool

    static let partialBannerMessage = "Some groups couldn’t be loaded."

    static func make(
        snapshot: GroupMemberSnapshot?,
        visibleRowCount: Int,
        searchQuery: String
    ) -> GroupMemberListPresentation {
        guard let snapshot else {
            return GroupMemberListPresentation(
                emptyMessage: nil, showsSpinner: visibleRowCount == 0, showsPartialBanner: false)
        }
        let banner = snapshot.isPartial
        guard visibleRowCount == 0 else {
            return GroupMemberListPresentation(
                emptyMessage: nil, showsSpinner: false, showsPartialBanner: banner)
        }

        let message: String
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        switch snapshot.emptiness {
        case .notEmpty:
            // There are members; the search filtered every one of them out.
            message = query.isEmpty ? "No Members" : "No members match \"\(query)\"."
        case .noGroups:
            message = "No Groups in This Folder"
        case .noMembers:
            message = "No Members"
        case .unavailable:
            message = "Couldn’t Load Members"
        }
        return GroupMemberListPresentation(
            emptyMessage: message, showsSpinner: false, showsPartialBanner: banner)
    }
}
