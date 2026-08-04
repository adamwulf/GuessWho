import Foundation

/// Maps a reorder that happened inside ONE section onto the global favorites
/// order.
///
/// `Favorites.json` persists a single ordered array spanning every kind, but
/// the sidebar shows favorites split per section (People, Organizations,
/// Events, Groups) and only ever reorders a section's rows among themselves.
/// Writing the section's new order back into the index slots that subsequence
/// already occupied leaves every other kind at its original global index — so
/// the Favorites list's relative order changes for the dragged section and for
/// nothing else.
public enum FavoritesOrder {
    /// Refill the slots held by `sectionOrder`'s members with those members in
    /// their new order.
    ///
    /// - Parameters:
    ///   - favorites: the global ordered array, as persisted.
    ///   - sectionOrder: the section's members in their NEW order.
    /// - Returns: `favorites` with the section's slots refilled; every favorite
    ///   outside the section keeps its exact index.
    ///
    /// An id that is no longer in `favorites` — the record was unfavorited
    /// while the drag was in flight — contributes neither a slot nor an
    /// occupant, so the rows that DO still exist land in the order the drag
    /// produced. A repeated id is refused outright (the whole array comes back
    /// unchanged): it can't be a permutation of the slots, and honoring it
    /// would duplicate one favorite and drop another.
    public static func reordered(
        _ favorites: [Favorite],
        sectionOrder: [FavoriteListItem.ID]
    ) -> [Favorite] {
        // The slots the section occupies today, ascending. These are the only
        // indices this rewrite is allowed to touch.
        let slots = favorites.indices.filter { index in
            sectionOrder.contains { favorites[index].matches($0) }
        }
        guard !slots.isEmpty else { return favorites }

        // Resolve each requested id against the live array rather than trusting
        // the caller's list wholesale: a stale id resolves to nil and drops out
        // of both sides, leaving the surviving rows to fill their own slots.
        let occupants = sectionOrder.compactMap { id in
            favorites.first { $0.matches(id) }
        }
        // The only way the two sides can disagree is a repeated id — refuse it
        // rather than duplicate a favorite over someone else's slot.
        guard occupants.count == slots.count else { return favorites }

        var result = favorites
        for (slot, favorite) in zip(slots, occupants) {
            result[slot] = favorite
        }
        return result
    }
}
