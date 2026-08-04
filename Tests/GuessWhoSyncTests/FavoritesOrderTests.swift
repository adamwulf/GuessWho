import Foundation
import Testing
@testable import GuessWhoSync

/// Covers the slice-reorder the Catalyst sidebar performs when a favorite is
/// dragged among its siblings: one section's subsequence is rewritten, and the
/// single global cross-kind array keeps every other favorite where it was.
@Suite("FavoritesOrder")
struct FavoritesOrderTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func favorite(_ kind: FavoriteKind, _ digit: Int) -> Favorite {
        let block = String(repeating: "\(digit)", count: 8)
        return Favorite(
            kind: kind,
            id: "\(block)-\(String(repeating: "\(digit)", count: 4))-4000-8000-\(String(repeating: "\(digit)", count: 12))",
            addedAt: epoch
        )
    }

    private func id(of favorite: Favorite) -> FavoriteListItem.ID {
        FavoriteListItem.ID(favorite.stableID)
    }

    @Test
    func movingWithinASectionLeavesEveryOtherKindInPlace() {
        let personA = favorite(.contact, 1)
        let event = favorite(.event, 2)
        let personB = favorite(.contact, 3)
        let group = favorite(.group, 4)
        let personC = favorite(.contact, 5)
        let global = [personA, event, personB, group, personC]

        // Drag the third person to the front of the People section.
        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [personC, personA, personB].map(id(of:))
        )

        // People occupied slots 0, 2, 4 — the same slots, refilled in the new
        // order. The event and the group never move.
        #expect(reordered.map(\.id) == [personC.id, event.id, personA.id, group.id, personB.id])
    }

    @Test
    func movingToTheEndOfASectionKeepsTheSameSlots() {
        let personA = favorite(.contact, 1)
        let personB = favorite(.contact, 2)
        let event = favorite(.event, 3)
        let personC = favorite(.contact, 4)
        let global = [personA, personB, event, personC]

        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [personB, personC, personA].map(id(of:))
        )

        #expect(reordered.map(\.id) == [personB.id, personC.id, event.id, personA.id])
        // The untouched event is still at its original global index.
        #expect(reordered[2] == event)
    }

    @Test
    func reorderingOneSectionDoesNotDisturbAnother() {
        let personA = favorite(.contact, 1)
        let eventA = favorite(.event, 2)
        let eventB = favorite(.event, 3)
        let personB = favorite(.contact, 4)
        let global = [personA, eventA, eventB, personB]

        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [eventB, eventA].map(id(of:))
        )

        #expect(reordered.map(\.id) == [personA.id, eventB.id, eventA.id, personB.id])
    }

    @Test
    func sameKindDifferentSectionsStayIndependent() {
        // People and Organizations are both `.contact` favorites; the sidebar
        // hands over only the section it dragged, so the other section's
        // contacts must keep their slots even though they share a kind.
        let person = favorite(.contact, 1)
        let organizationA = favorite(.contact, 2)
        let organizationB = favorite(.contact, 3)
        let global = [organizationA, person, organizationB]

        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [organizationB, organizationA].map(id(of:))
        )

        #expect(reordered.map(\.id) == [organizationB.id, person.id, organizationA.id])
    }

    @Test
    func anEmptySectionOrderChangesNothing() {
        let global = [favorite(.contact, 1), favorite(.event, 2)]
        #expect(FavoritesOrder.reordered(global, sectionOrder: []) == global)
    }

    @Test
    func anIdThatIsNoLongerFavoritedIsIgnored() {
        // Racing an unfavorite: the vanished row contributes no slot and no
        // occupant, so the surviving rows still take the dragged order.
        let personA = favorite(.contact, 1)
        let personB = favorite(.contact, 2)
        let event = favorite(.event, 3)
        let unfavorited = favorite(.contact, 9)
        let global = [personA, event, personB]

        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [personB, unfavorited, personA].map(id(of:))
        )

        #expect(reordered.map(\.id) == [personB.id, event.id, personA.id])
    }

    @Test
    func aRepeatedIdIsRefused() {
        let personA = favorite(.contact, 1)
        let personB = favorite(.contact, 2)
        let global = [personA, personB]

        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [personA, personA].map(id(of:))
        )

        #expect(reordered == global)
    }

    @Test
    func kindIsPartOfTheMatchSoASharedUuidCannotCrossSections() {
        // `stableID` is "kind:id", so a contact and an event that somehow carry
        // the same UUID stay distinct rows and only the named kind moves.
        let contact = Favorite(kind: .contact, id: "11111111-1111-4111-8111-111111111111", addedAt: epoch)
        let event = Favorite(kind: .event, id: "11111111-1111-4111-8111-111111111111", addedAt: epoch)
        let otherContact = favorite(.contact, 2)
        let global = [contact, event, otherContact]

        let reordered = FavoritesOrder.reordered(
            global,
            sectionOrder: [otherContact, contact].map(id(of:))
        )

        #expect(reordered.map(\.stableID) == [otherContact.stableID, event.stableID, contact.stableID])
    }

    @Test
    func aSingleMemberSectionIsANoOp() {
        let person = favorite(.contact, 1)
        let event = favorite(.event, 2)
        let global = [person, event]

        #expect(FavoritesOrder.reordered(global, sectionOrder: [id(of: person)]) == global)
    }
}
