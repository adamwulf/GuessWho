/// Pure projection of an ordered favorites list into the rows displayed by the
/// Catalyst sidebar. Generic ids keep the ordering rules independent of UIKit
/// and of `FavoriteListItem.ID`, whose initializer intentionally is not visible
/// to the app target.
struct SidebarFavoriteHierarchy<SectionID: Hashable, FavoriteID: Hashable, OrganizationID: Hashable> {
    enum Row: Hashable {
        case favorite(FavoriteID)
        /// An organization inferred from one or more department favorites. It
        /// has no favorite of its own and therefore represents no stored id.
        case organization(OrganizationID)
    }

    enum Role {
        case regular
        /// A contact favorite that is known to be an organization.
        case organization(OrganizationID)
        /// Nil is an unresolved department, which remains a plain row directly
        /// under the Organizations section.
        case department(OrganizationID?)
    }

    struct Entry {
        let id: FavoriteID
        let section: SectionID
        let role: Role
    }

    enum Parent: Hashable {
        case section(SectionID)
        case row(Row)
    }

    private var rootsBySection: [SectionID: [Row]] = [:]
    private var childrenByParent: [Row: [Row]] = [:]
    private var parentByFavorite: [FavoriteID: Parent] = [:]
    private var favoriteCounts: [SectionID: Int] = [:]

    init(entries: [Entry]) {
        // Decide every organization's row identity before walking global order.
        // If its contact favorite occurs after its first department favorite,
        // the departments still belong under that favorite row rather than an
        // earlier structural duplicate.
        var favoritedOrganizations: [OrganizationID: Row] = [:]
        for entry in entries {
            if case .organization(let organizationID) = entry.role {
                favoritedOrganizations[organizationID] = .favorite(entry.id)
            }
        }

        var insertedRoots: [SectionID: Set<Row>] = [:]
        for entry in entries {
            favoriteCounts[entry.section, default: 0] += 1
            let favoriteRow = Row.favorite(entry.id)

            switch entry.role {
            case .regular, .organization:
                appendRoot(
                    favoriteRow,
                    in: entry.section,
                    insertedRoots: &insertedRoots
                )
                parentByFavorite[entry.id] = .section(entry.section)

            case .department(nil):
                // There is no organization to hang this row under. Keeping the
                // favorite itself at section depth leaves it visible and
                // selectable so the user can remove it.
                appendRoot(
                    favoriteRow,
                    in: entry.section,
                    insertedRoots: &insertedRoots
                )
                parentByFavorite[entry.id] = .section(entry.section)

            case .department(.some(let organizationID)):
                let parent = favoritedOrganizations[organizationID]
                    ?? .organization(organizationID)
                if case .organization = parent {
                    // A structural parent occupies the first global-order slot
                    // at which one of its departments appears.
                    appendRoot(
                        parent,
                        in: entry.section,
                        insertedRoots: &insertedRoots
                    )
                }
                childrenByParent[parent, default: []].append(favoriteRow)
                parentByFavorite[entry.id] = .row(parent)
            }
        }
    }

    func roots(in section: SectionID) -> [Row] {
        rootsBySection[section] ?? []
    }

    func children(of row: Row) -> [Row] {
        childrenByParent[row] ?? []
    }

    func parent(of favoriteID: FavoriteID) -> Parent? {
        parentByFavorite[favoriteID]
    }

    func favoriteCount(in section: SectionID) -> Int {
        favoriteCounts[section] ?? 0
    }

    /// Stored favorite ids represented by one visible row and its descendants.
    /// A structural organization contributes only its department children; a
    /// favorited organization contributes its own id followed by those children.
    func favoriteIDs(in row: Row) -> [FavoriteID] {
        var ids: [FavoriteID] = []
        if case .favorite(let id) = row {
            ids.append(id)
        }
        ids.append(contentsOf: children(of: row).compactMap { child in
            guard case .favorite(let id) = child else { return nil }
            return id
        })
        return ids
    }

    /// The depth-first favorite order represented by a list of sibling rows.
    /// Used when a root row moves as a block so any nested departments stay with
    /// their organization while `FavoritesOrder` refills the same global slots.
    func flattenedFavoriteIDs(in rows: [Row]) -> [FavoriteID] {
        rows.flatMap(favoriteIDs(in:))
    }

    private mutating func appendRoot(
        _ row: Row,
        in section: SectionID,
        insertedRoots: inout [SectionID: Set<Row>]
    ) {
        guard insertedRoots[section, default: []].insert(row).inserted else { return }
        rootsBySection[section, default: []].append(row)
    }
}
