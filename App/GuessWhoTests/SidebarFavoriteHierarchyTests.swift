import Testing
@testable import GuessWho

@Suite("Sidebar favorite hierarchy")
struct SidebarFavoriteHierarchyTests {
    private enum Section: Hashable {
        case organizations
        case people
    }

    private typealias Hierarchy = SidebarFavoriteHierarchy<Section, String, String>

    @Test
    func departmentsAttachToFavoritedOrganizationRegardlessOfGlobalOrder() {
        let hierarchy = Hierarchy(entries: [
            .init(id: "dept-lilie", section: .organizations, role: .department("rice")),
            .init(id: "person", section: .people, role: .regular),
            .init(id: "org-rice", section: .organizations, role: .organization("rice")),
            .init(id: "dept-mba", section: .organizations, role: .department("rice")),
        ])

        let parent = Hierarchy.Row.favorite("org-rice")
        #expect(hierarchy.roots(in: .organizations) == [parent])
        #expect(hierarchy.children(of: parent) == [
            .favorite("dept-lilie"),
            .favorite("dept-mba"),
        ])
        #expect(hierarchy.parent(of: "dept-lilie") == .row(parent))
    }

    @Test
    func structuralOrganizationUsesFirstDepartmentPositionAndUnavailableStaysPlain() {
        let hierarchy = Hierarchy(entries: [
            .init(id: "org-b", section: .organizations, role: .organization("b")),
            .init(id: "dept-a-1", section: .organizations, role: .department("a")),
            .init(id: "unavailable", section: .organizations, role: .department(nil)),
            .init(id: "dept-a-2", section: .organizations, role: .department("a")),
        ])

        let structural = Hierarchy.Row.organization("a")
        #expect(hierarchy.roots(in: .organizations) == [
            .favorite("org-b"),
            structural,
            .favorite("unavailable"),
        ])
        #expect(hierarchy.children(of: structural) == [
            .favorite("dept-a-1"),
            .favorite("dept-a-2"),
        ])
        #expect(hierarchy.parent(of: "unavailable") == .section(.organizations))
    }

    @Test
    func favoriteCountIncludesNestedDepartmentsButNotStructuralRows() {
        let hierarchy = Hierarchy(entries: [
            .init(id: "dept-a", section: .organizations, role: .department("a")),
            .init(id: "dept-b", section: .organizations, role: .department("b")),
            .init(id: "org-b", section: .organizations, role: .organization("b")),
        ])

        #expect(hierarchy.favoriteCount(in: .organizations) == 3)
        #expect(hierarchy.favoriteCount(in: .people) == 0)
    }

    @Test
    func flatteningRootBlocksKeepsDepartmentsWithTheirOrganization() {
        let hierarchy = Hierarchy(entries: [
            .init(id: "org-a", section: .organizations, role: .organization("a")),
            .init(id: "dept-a", section: .organizations, role: .department("a")),
            .init(id: "dept-b-1", section: .organizations, role: .department("b")),
            .init(id: "dept-b-2", section: .organizations, role: .department("b")),
            .init(id: "unavailable", section: .organizations, role: .department(nil)),
        ])

        let roots = hierarchy.roots(in: .organizations)
        #expect(hierarchy.flattenedFavoriteIDs(in: roots) == [
            "org-a", "dept-a", "dept-b-1", "dept-b-2", "unavailable",
        ])

        let moved = [roots[1], roots[0], roots[2]]
        #expect(hierarchy.flattenedFavoriteIDs(in: moved) == [
            "dept-b-1", "dept-b-2", "org-a", "dept-a", "unavailable",
        ])
    }

    // MARK: - rowsAfterMoving (the pure drop-index math)
    //
    // Three root organizations whose visible starts are NON-contiguous because
    // the first root owns two department children. The section header sits at
    // visible index 0, so the roots start at 1, 4, 5 and root 0's children fill
    // visible indices 2 and 3.
    private static let nestedRoots: [Hierarchy.Row] = [
        .favorite("org-a"), .favorite("org-b"), .favorite("org-c"),
    ]
    private static let nestedRowStarts = [1, 4, 5]

    private func movingNestedRoot(
        from source: Int, toVisibleIndex visible: Int
    ) -> [Hierarchy.Row] {
        Hierarchy.rowsAfterMoving(
            Self.nestedRoots, from: source, rowStarts: Self.nestedRowStarts,
            toVisibleIndex: visible)
    }

    @Test
    func droppingAtAFirstRootsOwnIndexLandsAtPositionZero() {
        // Visible index 1 is root 0's own start; whichever row is dragged there
        // lands at the head of the sibling list.
        #expect(movingNestedRoot(from: 2, toVisibleIndex: 1) == [
            .favorite("org-c"), .favorite("org-a"), .favorite("org-b"),
        ])
        #expect(movingNestedRoot(from: 1, toVisibleIndex: 1) == [
            .favorite("org-b"), .favorite("org-a"), .favorite("org-c"),
        ])
    }

    @Test
    func droppingAtALaterRootsStartLandsBeforeThatRoot() {
        // Visible index 4 is root 1's start: an upward move of root 2 lands just
        // before root 1.
        #expect(movingNestedRoot(from: 2, toVisibleIndex: 4) == [
            .favorite("org-a"), .favorite("org-c"), .favorite("org-b"),
        ])
    }

    @Test
    func droppingInsideARootsSubtreeCountsAsAfterThatRoot() {
        // Root 0 owns visible indices 2 and 3. A drop at EITHER lands the dragged
        // row immediately after root 0, never between its children.
        let atFirstChild = movingNestedRoot(from: 2, toVisibleIndex: 2)
        let atSecondChild = movingNestedRoot(from: 2, toVisibleIndex: 3)
        #expect(atFirstChild == [.favorite("org-a"), .favorite("org-c"), .favorite("org-b")])
        #expect(atSecondChild == atFirstChild)
    }

    @Test
    func droppingAfterTheLastRootLandsAtTheEnd() {
        // The empty space below the list resolves to last-visible + 1 (root 2 has
        // no children, so 5 + 1 = 6); a downward move parks at the tail.
        #expect(movingNestedRoot(from: 0, toVisibleIndex: 6) == [
            .favorite("org-b"), .favorite("org-c"), .favorite("org-a"),
        ])
    }

    @Test
    func downwardAndUpwardMovesLandWhereThePointerIndicates() {
        // Downward: root 0 dragged to after root 1 (visible index 5, root 2's
        // start) lands between roots 1 and 2 — UIKit's pre-removal index is
        // corrected by one.
        #expect(movingNestedRoot(from: 0, toVisibleIndex: 5) == [
            .favorite("org-b"), .favorite("org-a"), .favorite("org-c"),
        ])
        // Upward: root 2 dragged before root 0 (visible index 1) lands at the head
        // with no off-by-one, because an upward move needs no removal correction.
        #expect(movingNestedRoot(from: 2, toVisibleIndex: 1) == [
            .favorite("org-c"), .favorite("org-a"), .favorite("org-b"),
        ])
    }

    @Test
    func droppingARowOntoItsOwnStartLeavesTheOrderUnchanged() {
        let unchanged: [Hierarchy.Row] = [.favorite("org-a"), .favorite("org-b"), .favorite("org-c")]
        // Each root dropped onto its own visible start is a no-op, whatever the
        // starts' spacing.
        #expect(movingNestedRoot(from: 0, toVisibleIndex: 1) == unchanged)
        #expect(movingNestedRoot(from: 1, toVisibleIndex: 4) == unchanged)
        #expect(movingNestedRoot(from: 2, toVisibleIndex: 5) == unchanged)
    }

    @Test
    func aDepartmentLevelSiblingListWithContiguousStartsMovesLikeFlatCode() {
        // Department children of one organization occupy contiguous visible
        // indices, so the translation reduces to `visible - firstStart` — exactly
        // the old flat reorder. Prove it against a plain array move.
        let departments: [Hierarchy.Row] = [.favorite("d1"), .favorite("d2"), .favorite("d3")]
        let starts = [2, 3, 4]

        func flatMove(from source: Int, to insertion: Int) -> [Hierarchy.Row] {
            var rows = departments
            let moved = rows.remove(at: source)
            let adjusted = insertion > source ? insertion - 1 : insertion
            rows.insert(moved, at: min(max(adjusted, 0), rows.count))
            return rows
        }

        for source in departments.indices {
            for visible in starts.first!...(starts.last! + 1) {
                let insertion = visible - starts.first!  // contiguous ⇒ direct offset
                #expect(
                    Hierarchy.rowsAfterMoving(
                        departments, from: source, rowStarts: starts,
                        toVisibleIndex: visible)
                        == flatMove(from: source, to: insertion))
            }
        }
    }
}
