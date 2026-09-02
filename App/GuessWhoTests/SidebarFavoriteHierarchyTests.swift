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
}
