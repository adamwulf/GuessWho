import Foundation

extension GuessWhoSync {
    // MARK: - Well-known guide / place cell keys

    public static let guideNameCacheKey       = "nameCache"
    public static let guideSourceURLCellKey   = "sourceURL"
    public static let guideDeletedAtCellKey   = "deletedAt"
    public static let guideLastViewedCellKey  = "lastViewed"

    public static let placeGuideIDCellKey     = "guideID"
    public static let placeNameCacheKey       = "nameCache"
    public static let placeAddressCacheKey    = "addressCache"
    public static let placeLatitudeCellKey    = "latitudeCache"
    public static let placeLongitudeCellKey   = "longitudeCache"
    public static let placeMapsPlaceIDCellKey = "mapsPlaceID"
    public static let placeResolvedAtCellKey  = "resolvedAt"
    public static let placeSortOrderCellKey   = "orderCache"
    public static let placeDeletedAtCellKey   = "deletedAt"
    public static let placeLastViewedCellKey  = "lastViewed"

    // MARK: - Lifecycle

    /// Create a guide (plus one place sidecar per entry) from a decoded share
    /// link. Mints the guide UUID and a place UUID per entry; entry order is
    /// preserved via each place's `orderCache` cell. Returns the guide UUID.
    ///
    /// Place-ID entries land unresolved (`resolvedAt` unset) — the app's
    /// MapKit pass fills name/address/coordinate later via
    /// `markPlaceResolved`. Address entries carry everything they'll ever
    /// have and never resolve.
    @discardableResult
    public func createGuide(
        from snapshot: MapsGuideURL.Snapshot,
        sourceURL: String?
    ) throws -> UUID {
        let guideID = UUID()
        let guideKey = SidecarKey(kind: .guide, id: guideID.uuidString)
        try writeWellKnownCell(
            at: guideKey,
            cellKey: Self.guideNameCacheKey,
            fieldName: Self.guideNameCacheKey,
            type: .note,
            value: .string(snapshot.name),
            softDelete: false
        )
        if let sourceURL, !sourceURL.isEmpty {
            try writeWellKnownCell(
                at: guideKey,
                cellKey: Self.guideSourceURLCellKey,
                fieldName: Self.guideSourceURLCellKey,
                type: .note,
                value: .string(sourceURL),
                softDelete: false
            )
        }

        for (index, entry) in snapshot.entries.enumerated() {
            try createPlace(entry: entry, guideID: guideID, sortOrder: index)
        }
        return guideID
    }

    /// Replace an existing guide's imported snapshot while keeping the
    /// guide's local UUID and any unchanged places' local UUIDs. The fetched
    /// guide is authoritative for its name and membership: entries no longer
    /// present are soft-deleted and new entries are minted. Existing places
    /// keep their user-defined relative order; newly discovered entries append
    /// at the end in their order from the fetched snapshot.
    ///
    /// Unchanged place-ID entries retain their resolved MapKit fields. Address
    /// entries are matched by normalized address (or coordinate when they have
    /// no address), so a coordinate correction can update the existing place
    /// instead of creating a visually duplicate row. Duplicate entries are
    /// matched one-for-one in their existing order.
    ///
    /// Returns false when `key` does not name a live guide, which can happen if
    /// the guide is deleted while its network refresh is in flight.
    @discardableResult
    public func refreshGuide(
        at key: SidecarKey,
        from snapshot: MapsGuideURL.Snapshot,
        sourceURL: String?
    ) throws -> Bool {
        guard key.kind == .guide,
              let guideID = UUID(uuidString: key.id),
              try guide(at: key) != nil
        else { return false }

        try writeWellKnownCell(
            at: key,
            cellKey: Self.guideNameCacheKey,
            fieldName: Self.guideNameCacheKey,
            type: .note,
            value: .string(snapshot.name),
            softDelete: false
        )
        if let sourceURL, !sourceURL.isEmpty {
            try writeWellKnownCell(
                at: key,
                cellKey: Self.guideSourceURLCellKey,
                fieldName: Self.guideSourceURLCellKey,
                type: .note,
                value: .string(sourceURL),
                softDelete: false
            )
        }

        let existingPlaces = try places(inGuide: guideID)
        var available: [GuideEntryIdentity: [MapsPlace]] = [:]
        for place in existingPlaces {
            available[GuideEntryIdentity(place: place), default: []].append(place)
        }

        var retainedIDs: Set<UUID> = []
        var newEntries: [MapsGuideURL.Entry] = []
        for entry in snapshot.entries {
            let identity = GuideEntryIdentity(entry: entry)
            if var candidates = available[identity], !candidates.isEmpty {
                let place = candidates.removeFirst()
                available[identity] = candidates
                retainedIDs.insert(place.id)
                try refreshPlace(place, from: entry)
            } else {
                newEntries.append(entry)
            }
        }

        for place in existingPlaces where !retainedIDs.contains(place.id) {
            try deletePlace(at: SidecarKey(kind: .place, id: place.id.uuidString))
        }

        // `existingPlaces` is already in the locally persisted guide order.
        // Compact surviving rows without changing their relative order, then
        // append newly fetched entries so refresh never discards a user drag.
        var nextSortOrder = 0
        for place in existingPlaces where retainedIDs.contains(place.id) {
            try updatePlaceSortOrder(place, to: nextSortOrder)
            nextSortOrder += 1
        }
        for entry in newEntries {
            _ = try createPlace(
                entry: entry,
                guideID: guideID,
                sortOrder: nextSortOrder
            )
            nextSortOrder += 1
        }
        return true
    }

    /// Mint one place sidecar for `entry` inside `guideID` at `sortOrder`.
    @discardableResult
    func createPlace(entry: MapsGuideURL.Entry, guideID: UUID, sortOrder: Int) throws -> UUID {
        let placeID = UUID()
        let key = SidecarKey(kind: .place, id: placeID.uuidString)

        func write(_ cellKey: String, type: SidecarFieldType = .note, _ value: JSONValue) throws {
            try writeWellKnownCell(
                at: key,
                cellKey: cellKey,
                fieldName: cellKey,
                type: type,
                value: value,
                softDelete: false
            )
        }

        try write(Self.placeGuideIDCellKey, .string(guideID.uuidString.lowercased()))
        try write(Self.placeSortOrderCellKey, .string(String(sortOrder)))
        if let mapsPlaceID = entry.mapsPlaceID {
            try write(Self.placeMapsPlaceIDCellKey, .string(mapsPlaceID))
        }
        if let address = entry.address, !address.isEmpty {
            try write(Self.placeAddressCacheKey, .string(address))
        }
        if let latitude = entry.latitude, let longitude = entry.longitude {
            try write(Self.placeLatitudeCellKey, .string(String(latitude)))
            try write(Self.placeLongitudeCellKey, .string(String(longitude)))
        }
        return placeID
    }

    /// Update the snapshot-owned cells of a retained place. For place-ID
    /// entries this deliberately leaves name/address/coordinate/resolvedAt
    /// alone: those are MapKit resolution results, not fields in the guide
    /// payload. Address entries refresh their inline address and coordinate.
    private func refreshPlace(
        _ place: MapsPlace,
        from entry: MapsGuideURL.Entry
    ) throws {
        let key = SidecarKey(kind: .place, id: place.id.uuidString)

        func write(_ cellKey: String, _ value: JSONValue) throws {
            try writeWellKnownCell(
                at: key,
                cellKey: cellKey,
                fieldName: cellKey,
                type: .note,
                value: value,
                softDelete: false
            )
        }

        guard entry.mapsPlaceID == nil else { return }
        if let address = entry.address, !address.isEmpty, address != place.address {
            try write(Self.placeAddressCacheKey, .string(address))
        }
        if let latitude = entry.latitude,
           let longitude = entry.longitude,
           latitude != place.latitude || longitude != place.longitude
        {
            try write(Self.placeLatitudeCellKey, .string(String(latitude)))
            try write(Self.placeLongitudeCellKey, .string(String(longitude)))
        }
    }

    private func updatePlaceSortOrder(_ place: MapsPlace, to sortOrder: Int) throws {
        guard place.sortOrder != sortOrder else { return }
        let key = SidecarKey(kind: .place, id: place.id.uuidString)
        try writeWellKnownCell(
            at: key,
            cellKey: Self.placeSortOrderCellKey,
            fieldName: Self.placeSortOrderCellKey,
            type: .note,
            value: .string(String(sortOrder)),
            softDelete: false
        )
    }

    /// Fill a place's display fields from a MapKit place-ID resolution and
    /// stamp `resolvedAt`, so the pass never re-runs for this place. Only
    /// non-nil fields are written (a resolution that carries no address keeps
    /// whatever the sidecar already had).
    public func markPlaceResolved(
        at key: SidecarKey,
        name: String,
        address: String?,
        latitude: Double?,
        longitude: Double?,
        now: Date = Date()
    ) throws {
        guard try sidecars.read(key) != nil else { return }

        func write(_ cellKey: String, type: SidecarFieldType = .note, _ value: JSONValue) throws {
            try writeWellKnownCell(
                at: key,
                cellKey: cellKey,
                fieldName: cellKey,
                type: type,
                value: value,
                softDelete: false
            )
        }

        try write(Self.placeNameCacheKey, .string(name))
        if let address, !address.isEmpty {
            try write(Self.placeAddressCacheKey, .string(address))
        }
        if let latitude, let longitude {
            try write(Self.placeLatitudeCellKey, .string(String(latitude)))
            try write(Self.placeLongitudeCellKey, .string(String(longitude)))
        }
        try write(Self.placeResolvedAtCellKey, type: .date, .string(SidecarISO8601.string(from: now)))
    }

    /// Whole-guide soft-delete: stamps the guide envelope's `deletedAt` cell
    /// AND every live place belonging to it, so neither the guide nor its
    /// places surface in any read again.
    public func deleteGuide(at key: SidecarKey) throws {
        let now = Date()
        try writeWellKnownCell(
            at: key,
            cellKey: Self.guideDeletedAtCellKey,
            fieldName: Self.guideDeletedAtCellKey,
            type: .note,
            value: .string(SidecarISO8601.string(from: now)),
            softDelete: false
        )
        guard let guideID = UUID(uuidString: key.id) else { return }
        for place in try places(inGuide: guideID) {
            try deletePlace(at: SidecarKey(kind: .place, id: place.id.uuidString))
        }
    }

    /// Stamp `lastViewed = now` on the guide envelope at `key`. ADDITIVE and
    /// schema-stable, like the event view stamp: only the one cell changes,
    /// every other cell (name cache, source URL) is preserved. No-op when no
    /// envelope exists yet — a view stamp must never mint a sidecar on its own.
    /// Mirrors `stampEventViewed(at:)`.
    public func stampGuideViewed(at key: SidecarKey, now: Date = Date()) throws {
        guard try sidecars.read(key) != nil else { return }
        try writeWellKnownCell(
            at: key,
            cellKey: Self.guideLastViewedCellKey,
            fieldName: Self.guideLastViewedCellKey,
            type: .date,
            value: .string(SidecarISO8601.string(from: now)),
            softDelete: false
        )
    }

    /// Stamp `lastViewed = now` on the place envelope at `key`. ADDITIVE and
    /// schema-stable, like `stampGuideViewed`: only the one cell changes, every
    /// other cell (name/address caches, coordinate, order) is preserved. No-op
    /// when no envelope exists yet.
    public func stampPlaceViewed(at key: SidecarKey, now: Date = Date()) throws {
        guard try sidecars.read(key) != nil else { return }
        try writeWellKnownCell(
            at: key,
            cellKey: Self.placeLastViewedCellKey,
            fieldName: Self.placeLastViewedCellKey,
            type: .date,
            value: .string(SidecarISO8601.string(from: now)),
            softDelete: false
        )
    }

    /// Rewrite `guideID`'s places into `orderedIDs` order by stamping each
    /// place's `orderCache` cell to its new index (0-based). `orderedIDs` must
    /// be the guide's full place set in the desired order; entries with no live
    /// sidecar are skipped. Only places whose index actually changed are
    /// written, so a small drag touches only the shifted rows. Backs the
    /// drag-to-reorder affordance in the places list — the "Guide Order" sort
    /// IS this cell, so reordering here is what that sort reflects.
    public func reorderPlaces(inGuide guideID: UUID, orderedIDs: [UUID]) throws {
        var currentOrder: [UUID: Int] = [:]
        for place in try places(inGuide: guideID) {
            currentOrder[place.id] = place.sortOrder
        }
        for (index, placeID) in orderedIDs.enumerated() {
            if currentOrder[placeID] == index { continue }
            let key = SidecarKey(kind: .place, id: placeID.uuidString)
            guard try sidecars.read(key) != nil else { continue }
            try writeWellKnownCell(
                at: key,
                cellKey: Self.placeSortOrderCellKey,
                fieldName: Self.placeSortOrderCellKey,
                type: .note,
                value: .string(String(index)),
                softDelete: false
            )
        }
    }

    /// Whole-place soft-delete (removing a single row from a guide).
    public func deletePlace(at key: SidecarKey) throws {
        try writeWellKnownCell(
            at: key,
            cellKey: Self.placeDeletedAtCellKey,
            fieldName: Self.placeDeletedAtCellKey,
            type: .note,
            value: .string(SidecarISO8601.string(from: Date())),
            softDelete: false
        )
    }

    // MARK: - Read / project

    /// Decode the guide at `key`, or nil when missing / soft-deleted.
    public func guide(at key: SidecarKey) throws -> MapsGuide? {
        guard let envelope = try sidecars.read(key) else { return nil }
        return decodeGuide(envelope: envelope, key: key)
    }

    /// Every live guide. O(N) over guide sidecars; unordered — display
    /// ordering is the caller's choice.
    public func allGuides() throws -> [MapsGuide] {
        var result: [MapsGuide] = []
        for key in try sidecars.allKeys() where key.kind == .guide {
            guard let envelope = try sidecars.read(key) else { continue }
            if let guide = decodeGuide(envelope: envelope, key: key) {
                result.append(guide)
            }
        }
        return result
    }

    /// Async overload of `allGuides()` — a coordinated read + decode of every
    /// guide sidecar, so it hops to a background queue rather than blocking
    /// the caller's actor. Same continuation pattern as `allEvents()`.
    public func allGuides() async throws -> [MapsGuide] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [MapsGuide] = try self.allGuides()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Every live place, across all guides. Backs the guides list's per-guide
    /// place counts with ONE sidecar walk instead of one per guide.
    public func allPlaces() throws -> [MapsPlace] {
        var result: [MapsPlace] = []
        for key in try sidecars.allKeys() where key.kind == .place {
            guard let envelope = try sidecars.read(key) else { continue }
            if let place = decodePlace(envelope: envelope, key: key) {
                result.append(place)
            }
        }
        return result
    }

    /// Async overload of `allPlaces()` — same background-hop rationale as
    /// `allGuides()`.
    public func allPlaces() async throws -> [MapsPlace] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [MapsPlace] = try self.allPlaces()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The live places belonging to `guideID`, in the guide's entry order
    /// (`orderCache`, place UUID as a deterministic tiebreak).
    public func places(inGuide guideID: UUID) throws -> [MapsPlace] {
        try allPlaces()
            .filter { $0.guideID == guideID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// Async overload of `places(inGuide:)` — same background-hop rationale
    /// as `allGuides()`.
    public func places(inGuide guideID: UUID) async throws -> [MapsPlace] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [MapsPlace] = try self.places(inGuide: guideID)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private decode helpers
    //
    // Cell-decode helpers mirror the private ones in GuessWhoSync+Events.swift
    // (they're deliberately file-private there; the duplication keeps each
    // record family's decode self-contained).

    private func decodeGuide(envelope: SidecarEnvelope, key: SidecarKey) -> MapsGuide? {
        guard key.kind == .guide, let id = UUID(uuidString: key.id) else { return nil }
        if isCellLive(envelope: envelope, cellKey: Self.guideDeletedAtCellKey) { return nil }
        return MapsGuide(
            id: id,
            name: decodeGuideStringValue(envelope: envelope, cellKey: Self.guideNameCacheKey) ?? "",
            sourceURL: decodeGuideStringValue(envelope: envelope, cellKey: Self.guideSourceURLCellKey),
            createdAt: earliestGuideCellCreatedAt(envelope: envelope),
            lastViewedAt: decodeGuideStringValue(envelope: envelope, cellKey: Self.guideLastViewedCellKey)
                .flatMap(SidecarISO8601.date(from:))
        )
    }

    private func decodePlace(envelope: SidecarEnvelope, key: SidecarKey) -> MapsPlace? {
        guard key.kind == .place, let id = UUID(uuidString: key.id) else { return nil }
        if isCellLive(envelope: envelope, cellKey: Self.placeDeletedAtCellKey) { return nil }
        guard let guideRaw = decodeGuideStringValue(envelope: envelope, cellKey: Self.placeGuideIDCellKey),
              let guideID = UUID(uuidString: guideRaw)
        else { return nil }

        let latitude = decodeGuideStringValue(envelope: envelope, cellKey: Self.placeLatitudeCellKey)
            .flatMap(Double.init)
        let longitude = decodeGuideStringValue(envelope: envelope, cellKey: Self.placeLongitudeCellKey)
            .flatMap(Double.init)
        let addressRaw = decodeGuideStringValue(envelope: envelope, cellKey: Self.placeAddressCacheKey)
        let resolvedAtRaw = decodeGuideStringValue(envelope: envelope, cellKey: Self.placeResolvedAtCellKey)
        let sortOrder = decodeGuideStringValue(envelope: envelope, cellKey: Self.placeSortOrderCellKey)
            .flatMap(Int.init) ?? 0

        return MapsPlace(
            id: id,
            guideID: guideID,
            name: decodeGuideStringValue(envelope: envelope, cellKey: Self.placeNameCacheKey) ?? "",
            address: (addressRaw?.isEmpty ?? true) ? nil : addressRaw,
            latitude: latitude,
            longitude: longitude,
            mapsPlaceID: decodeGuideStringValue(envelope: envelope, cellKey: Self.placeMapsPlaceIDCellKey),
            resolvedAt: resolvedAtRaw.flatMap(SidecarISO8601.date(from:)),
            sortOrder: sortOrder,
            createdAt: earliestGuideCellCreatedAt(envelope: envelope),
            lastViewedAt: decodeGuideStringValue(envelope: envelope, cellKey: Self.placeLastViewedCellKey)
                .flatMap(SidecarISO8601.date(from:))
        )
    }

    /// True when the cell at `cellKey` exists and is not itself soft-deleted —
    /// the same "live deletedAt cell" convention events use for whole-record
    /// deletion.
    private func isCellLive(envelope: SidecarEnvelope, cellKey: String) -> Bool {
        guard let cell = envelope.fields[cellKey] else { return false }
        return cell.deletedAt == nil
    }

    private func decodeGuideStringValue(envelope: SidecarEnvelope, cellKey: String) -> String? {
        guard let cell = envelope.fields[cellKey] else { return nil }
        guard case .object(let inner) = cell.value,
              case .string(let value) = inner[SidecarField.innerValueKey] ?? .null
        else { return nil }
        return value
    }

    /// The earliest inner `createdAt` stamp across the envelope's cells —
    /// same derivation as the events extension's `earliestCellCreatedAt`.
    private func earliestGuideCellCreatedAt(envelope: SidecarEnvelope) -> Date? {
        var earliest: Date?
        for cell in envelope.fields.values {
            guard case .object(let inner) = cell.value,
                  case .string(let raw) = inner[SidecarField.innerCreatedAtKey] ?? .null,
                  let stamp = SidecarISO8601.date(from: raw)
            else { continue }
            if earliest == nil || stamp < earliest! {
                earliest = stamp
            }
        }
        return earliest
    }
}

/// The strongest identity available inside an Apple Maps guide payload. The
/// payload has no observed guide-level identifier; place-ID entries do carry a
/// durable MapKit identifier, while address entries only carry address and
/// coordinate data.
private enum GuideEntryIdentity: Hashable {
    case placeID(String)
    case address(String)
    case coordinate(latitudeBits: UInt64, longitudeBits: UInt64)

    init(entry: MapsGuideURL.Entry) {
        if let mapsPlaceID = entry.mapsPlaceID, !mapsPlaceID.isEmpty {
            self = .placeID(mapsPlaceID.uppercased())
        } else if let address = Self.normalizedAddress(entry.address), !address.isEmpty {
            self = .address(address)
        } else {
            self = .coordinate(
                latitudeBits: (entry.latitude ?? 0).bitPattern,
                longitudeBits: (entry.longitude ?? 0).bitPattern
            )
        }
    }

    init(place: MapsPlace) {
        if let mapsPlaceID = place.mapsPlaceID, !mapsPlaceID.isEmpty {
            self = .placeID(mapsPlaceID.uppercased())
        } else if let address = Self.normalizedAddress(place.address), !address.isEmpty {
            self = .address(address)
        } else {
            self = .coordinate(
                latitudeBits: (place.latitude ?? 0).bitPattern,
                longitudeBits: (place.longitude ?? 0).bitPattern
            )
        }
    }

    private static func normalizedAddress(_ address: String?) -> String? {
        address?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
