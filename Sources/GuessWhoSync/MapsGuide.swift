import Foundation

/// A saved Apple Maps guide imported from a share link (`maps.apple/ug/…`).
/// GuessWho-owned data: unlike contacts/events there is no external
/// source-of-truth store to link back to — the share link is a one-shot
/// snapshot, so the sidecar IS the record.
public struct MapsGuide: Hashable, Sendable, Codable {
    /// GuessWho guide UUID — the sidecar key. Minted at import.
    public var id: UUID

    /// The guide's name as it appeared in the share link (e.g. "Berlin").
    public var name: String

    /// The share URL the guide was imported from, kept so a future re-import /
    /// refresh flow can re-fetch the same guide. Display-optional.
    public var sourceURL: String?

    /// When the guide was imported, derived from the earliest cell `createdAt`
    /// on the guide's envelope (same derivation as `Event.createdAt` for
    /// manual events). Backs newest-first ordering in the guides list.
    public var createdAt: Date?

    /// When the guide was last opened, stamped once per open by the app.
    /// nil until first opened; backs the "Last Viewed" guide sort order.
    /// Mirrors `Event.lastViewedAt`.
    public var lastViewedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        sourceURL: String? = nil,
        createdAt: Date? = nil,
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.lastViewedAt = lastViewedAt
    }
}

/// One place inside an imported guide. Two shapes exist, mirroring what an
/// Apple Maps guide share link actually carries per entry:
///
/// * a **place-ID entry** — only an Apple Maps place identifier
///   (`mapsPlaceID`, the `"I" + hex` form MapKit's `MKMapItem.Identifier`
///   uses). Name/address/coordinate start empty and are filled in by the
///   app's MapKit resolution pass, which stamps `resolvedAt`.
/// * an **address entry** — a saved address with no place of business
///   attached: the link carries the address string + coordinate directly and
///   there is nothing further to resolve (`mapsPlaceID` is nil).
public struct MapsPlace: Hashable, Sendable, Codable {
    /// GuessWho place UUID — the sidecar key. Minted at import.
    public var id: UUID

    /// The guide this place belongs to.
    public var guideID: UUID

    /// Display name (business name once resolved; empty until then for
    /// place-ID entries; empty for address entries, which display `address`).
    public var name: String

    public var address: String?
    public var latitude: Double?
    public var longitude: Double?

    /// Apple Maps place identifier in MapKit's raw form (`"I" + uppercase
    /// hex of the 64-bit place id`), decodable by `MKMapItem.Identifier`.
    /// nil for address entries.
    public var mapsPlaceID: String?

    /// When the MapKit resolution pass last filled name/address/coordinate
    /// from `mapsPlaceID`. nil until resolved (and always nil for address
    /// entries, which never need resolution).
    public var resolvedAt: Date?

    /// Position within the guide (the share link's entry order).
    public var sortOrder: Int

    /// When the place record was imported. Same derivation as
    /// `MapsGuide.createdAt`.
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        guideID: UUID,
        name: String = "",
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        mapsPlaceID: String? = nil,
        resolvedAt: Date? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.guideID = guideID
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mapsPlaceID = mapsPlaceID
        self.resolvedAt = resolvedAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

extension MapsPlace {
    /// True iff this place still needs the MapKit resolution pass: it carries
    /// a place ID but has never been resolved.
    public var needsResolution: Bool {
        mapsPlaceID != nil && resolvedAt == nil
    }
}
