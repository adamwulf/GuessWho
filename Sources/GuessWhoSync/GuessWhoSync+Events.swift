import Foundation

extension GuessWhoSync {
    // MARK: - Well-known event cell keys (E1.2 group a)

    public static let eventKitIDCellKey       = "eventKitID"
    public static let eventTitleCacheKey      = "titleCache"
    public static let eventStartCacheKey      = "startCache"
    public static let eventEndCacheKey        = "endCache"
    public static let eventIsAllDayCacheKey   = "isAllDayCache"
    public static let eventLocationCacheKey   = "locationCache"
    public static let eventNotesCacheKey      = "eventKitNotesCache"
    public static let eventDeletedAtCellKey   = "deletedAt"

    /// Well-known field name for event tag instances (E1.2 group b).
    public static let eventTagFieldName       = "tag"

    // MARK: - Lifecycle

    /// Create a sidecar-only (manual) event. Mints an event UUID and writes
    /// the cache cells from the supplied fields; leaves `eventKitID` unset.
    /// Returns the event UUID (the SidecarKey id).
    @discardableResult
    public func createManualEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> UUID {
        let id = UUID()
        let key = SidecarKey(kind: .event, id: id.uuidString)
        try writeEventCacheCells(
            at: key,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            eventKitNotes: nil,
            includeOnlyChanged: false
        )
        return id
    }

    /// Create a sidecar event linked to a freshly-created EventKit event.
    /// Calls `events.createEvent(...)`, then writes the sidecar with
    /// `eventKitID` + cache cells seeded from the returned `Event`.
    @discardableResult
    public func createLinkedEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> UUID {
        let created = try events.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location
        )
        guard let ekid = created.eventKitID else {
            throw EventStoreError.eventNotFound(eventKitID: "")
        }
        let id = UUID()
        let key = SidecarKey(kind: .event, id: id.uuidString)
        try writeWellKnownCell(
            at: key,
            cellKey: Self.eventKitIDCellKey,
            fieldName: Self.eventKitIDCellKey,
            type: .note,
            value: .string(ekid),
            softDelete: false
        )
        try writeEventCacheCells(
            at: key,
            title: created.title,
            startDate: created.startDate,
            endDate: created.endDate,
            isAllDay: created.isAllDay,
            location: created.location,
            eventKitNotes: created.eventKitNotes,
            includeOnlyChanged: false
        )
        return id
    }

    /// Mint a sidecar pointing at an existing EventKit event. Writes the
    /// `eventKitID` cell and cache cells from the snapshot. Does NOT dedup;
    /// callers wanting edit-existing behavior should consult
    /// `eventUUID(forEventKitID:)` first.
    @discardableResult
    public func linkEvent(
        toEventKitID ekid: String,
        snapshot ekEvent: Event
    ) throws -> UUID {
        let id = UUID()
        let key = SidecarKey(kind: .event, id: id.uuidString)
        try writeWellKnownCell(
            at: key,
            cellKey: Self.eventKitIDCellKey,
            fieldName: Self.eventKitIDCellKey,
            type: .note,
            value: .string(ekid),
            softDelete: false
        )
        try writeEventCacheCells(
            at: key,
            title: ekEvent.title,
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            isAllDay: ekEvent.isAllDay,
            location: ekEvent.location,
            eventKitNotes: ekEvent.eventKitNotes,
            includeOnlyChanged: false
        )
        return id
    }

    /// Adopt an existing manual sidecar by attaching it to an EventKit event.
    /// Writes the `eventKitID` cell on the existing sidecar then refreshes
    /// the cache from EventKit so live values overwrite the manual cache
    /// (Option C live-wins-when-linked).
    public func linkExistingSidecar(at key: SidecarKey, toEventKitID ekid: String) throws {
        guard try sidecars.read(key) != nil else {
            throw EventStoreError.eventNotFound(eventKitID: ekid)
        }
        try writeWellKnownCell(
            at: key,
            cellKey: Self.eventKitIDCellKey,
            fieldName: Self.eventKitIDCellKey,
            type: .note,
            value: .string(ekid),
            softDelete: false
        )
        _ = try refreshEventCache(at: key)
    }

    /// Soft-delete the `eventKitID` cell so the event is no longer linked.
    /// Bumps the cell's stamps and writes `deletedAt = now`; the cell's
    /// `value` string is retained. Cache cells are NOT touched.
    public func unlinkEvent(at key: SidecarKey) throws {
        guard let envelope = try sidecars.read(key) else { return }
        guard let cell = envelope.fields[Self.eventKitIDCellKey] else { return }
        guard let existingType = SidecarField.type(of: cell) else { return }
        guard case .object(let inner) = cell.value,
              let valuePayload = inner[SidecarField.innerValueKey]
        else { return }
        try writeWellKnownCell(
            at: key,
            cellKey: Self.eventKitIDCellKey,
            fieldName: Self.eventKitIDCellKey,
            type: existingType,
            value: valuePayload,
            softDelete: true
        )
    }

    /// Whole-event soft-delete. Writes the envelope-level `deletedAt`
    /// well-known cell. The EKEvent in the user's calendar is NOT deleted.
    public func deleteEvent(at key: SidecarKey) throws {
        let now = Date()
        try writeWellKnownCell(
            at: key,
            cellKey: Self.eventDeletedAtCellKey,
            fieldName: Self.eventDeletedAtCellKey,
            type: .note,
            value: .string(SidecarISO8601.string(from: now)),
            softDelete: false
        )
    }

    // MARK: - Read / project

    /// Project a sidecar event UUID into a displayable `Event` via Option C:
    /// when linked AND `events.fetch(eventKitID:)` returns a live event,
    /// overlay the live values onto the cached `Event` (preserving sidecar
    /// UUID as `id`). Returns nil if no sidecar or whole-event-deleted.
    public func event(at key: SidecarKey) throws -> Event? {
        guard let envelope = try sidecars.read(key) else { return nil }
        if isEnvelopeWholeEventDeleted(envelope) { return nil }
        guard let cached = decodeCachedEvent(envelope: envelope, key: key) else { return nil }
        guard let ekid = liveEventKitID(envelope: envelope) else { return cached }
        guard let live = try events.fetch(eventKitID: ekid) else { return cached }
        return overlay(live: live, onto: cached, ekid: ekid)
    }

    /// Every sidecar event (`events/<uuid>.json`) projected via Option C.
    /// O(N) + per-linked fetch. Whole-event-deleted envelopes are filtered.
    public func allEvents() throws -> [Event] {
        var result: [Event] = []
        for key in try sidecars.allKeys() where key.kind == .event {
            if let event = try event(at: key) {
                result.append(event)
            }
        }
        return result
    }

    /// Reverse lookup: the sidecar event UUID currently pointing at `ekid`,
    /// or nil. O(N) over event sidecars. Soft-deleted `eventKitID` cells and
    /// whole-event-deleted envelopes are excluded. When multiple sidecars
    /// share `ekid`, returns the lexicographically-smallest event UUID so
    /// independent device scans converge.
    public func eventUUID(forEventKitID ekid: String) throws -> UUID? {
        var matches: [UUID] = []
        for key in try sidecars.allKeys() where key.kind == .event {
            guard let envelope = try sidecars.read(key) else { continue }
            if isEnvelopeWholeEventDeleted(envelope) { continue }
            guard let cellEKID = liveEventKitID(envelope: envelope), cellEKID == ekid else { continue }
            guard let id = UUID(uuidString: key.id) else { continue }
            matches.append(id)
        }
        guard !matches.isEmpty else { return nil }
        return matches.min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }

    // MARK: - Edit (Option C write routing)

    /// Edit title/start/end/isAllDay/location. Decision tree per E1.7:
    /// 1. No `eventKitID` or soft-deleted → write cache cells.
    /// 2. Linked but `fetch(eventKitID:)` returns nil → write cache cells only
    ///    (do NOT unlink).
    /// 3. Live → call `events.updateEvent(...)` then refresh the cache from
    ///    the post-write EventKit read.
    public func updateEventFields(
        at key: SidecarKey,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws {
        let envelope = try sidecars.read(key)
        let ekid = envelope.flatMap { liveEventKitID(envelope: $0) }

        if let ekid {
            if let _ = try events.fetch(eventKitID: ekid) {
                try events.updateEvent(
                    eventKitID: ekid,
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: isAllDay,
                    location: location
                )
                _ = try refreshEventCache(at: key)
                return
            }
        }

        try writeEventCacheCells(
            at: key,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            eventKitNotes: nil,
            includeOnlyChanged: false,
            includeEventKitNotes: false
        )
    }

    /// Silent best-effort refresh of cache cells from EventKit for a linked
    /// event. No-op for unlinked / soft-deleted / EventKit-gone. Writes only
    /// the cells whose current decoded value differs from the EventKit value.
    /// Returns the live-projected `Event` when refreshed, the cached `Event`
    /// otherwise, or nil if the sidecar is missing.
    @discardableResult
    public func refreshEventCache(at key: SidecarKey) throws -> Event? {
        guard let envelope = try sidecars.read(key) else { return nil }
        guard let cached = decodeCachedEvent(envelope: envelope, key: key) else { return nil }
        guard let ekid = liveEventKitID(envelope: envelope) else { return cached }
        guard let live = try events.fetch(eventKitID: ekid) else { return cached }
        try writeEventCacheCells(
            at: key,
            title: live.title,
            startDate: live.startDate,
            endDate: live.endDate,
            isAllDay: live.isAllDay,
            location: live.location,
            eventKitNotes: live.eventKitNotes,
            includeOnlyChanged: true,
            includeEventKitNotes: true,
            existingEnvelope: envelope
        )
        return overlay(live: live, onto: cached, ekid: ekid)
    }

    // MARK: - Tags

    @discardableResult
    public func addTag(at key: SidecarKey, text: String) throws -> UUID {
        try addField(
            at: key,
            field: Self.eventTagFieldName,
            type: .note,
            value: .string(text)
        )
    }

    public func editTag(at key: SidecarKey, id: UUID, text: String) throws {
        try setField(
            at: key,
            id: id,
            field: Self.eventTagFieldName,
            value: .string(text)
        )
    }

    public func deleteTag(at key: SidecarKey, id: UUID) throws {
        try deleteField(at: key, id: id)
    }

    public func tags(at key: SidecarKey) throws -> [EventTag] {
        let raw = try fields(at: key)
        let live = raw.compactMap { field -> EventTag? in
            guard field.type == .note,
                  field.field == Self.eventTagFieldName,
                  field.deletedAt == nil,
                  case .string(let text) = field.value
            else { return nil }
            return EventTag(
                id: field.id,
                text: text,
                createdAt: field.createdAt,
                deletedAt: nil
            )
        }
        return live.sorted { lhs, rhs in
            let lhsStamp = lhs.createdAt ?? .distantPast
            let rhsStamp = rhs.createdAt ?? .distantPast
            if lhsStamp != rhsStamp { return lhsStamp < rhsStamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Windowed list read (E2.2)

    /// Events to display for a date window: the union of sidecar events
    /// whose effective `startDate` falls in `[from, to]` (manual + linked,
    /// projected via Option C using a single in-window EventKit batch) and,
    /// when `includeEventKit` is true, EventKit events in the same window
    /// that have no matching sidecar (emitted as ephemeral unlinked rows
    /// with a stable id derived from `eventKitID`).
    ///
    /// CRITICAL: this calls `events.fetchEvents(in:)` at most once and
    /// `events.fetch(eventKitID:)` zero times.
    public func eventsWindow(
        from: Date,
        to: Date,
        includeEventKit: Bool = true
    ) throws -> [Event] {
        let interval = DateInterval(start: from, end: to)

        // 1. Single EventKit batch (or none when not requested).
        var ekIndex: [String: Event] = [:]
        if includeEventKit {
            let batch = try events.fetchEvents(in: interval)
            for event in batch {
                if let ekid = event.eventKitID {
                    ekIndex[ekid] = event
                }
            }
        }

        // 2. Walk sidecar events; overlay from the batch when possible.
        var seenEKIDs: Set<String> = []
        var result: [Event] = []
        for key in try sidecars.allKeys() where key.kind == .event {
            guard let envelope = try sidecars.read(key) else { continue }
            if isEnvelopeWholeEventDeleted(envelope) { continue }
            guard let cached = decodeCachedEvent(envelope: envelope, key: key) else { continue }

            let projected: Event
            if let ekid = liveEventKitID(envelope: envelope) {
                seenEKIDs.insert(ekid)
                if let live = ekIndex[ekid] {
                    projected = overlay(live: live, onto: cached, ekid: ekid)
                } else {
                    projected = cached
                }
            } else {
                projected = cached
            }

            if projected.startDate >= from && projected.startDate <= to {
                result.append(projected)
            }
        }

        // 3. Ephemeral rows for in-window EventKit events with no sidecar.
        if includeEventKit {
            for (ekid, live) in ekIndex where !seenEKIDs.contains(ekid) {
                var ephemeral = live
                ephemeral.id = Event.stableID(forEventKitID: ekid)
                if ephemeral.startDate >= from && ephemeral.startDate <= to {
                    result.append(ephemeral)
                }
            }
        }

        return result.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Private helpers

    /// Write one §5.2 cell at a fixed cell key (vs. the minted-UUID keys
    /// used by field-instance cells). Mirrors `addField`'s cell-construction
    /// shape so `SidecarField.decode` still reads it; under the per-key
    /// `sidecarLocks.withLock` discipline. When `softDelete == true`, stamps
    /// `deletedAt = now` on the cell.
    internal func writeWellKnownCell(
        at key: SidecarKey,
        cellKey: String,
        fieldName: String,
        type: SidecarFieldType,
        value: JSONValue,
        softDelete: Bool
    ) throws {
        try SidecarField.validate(value: value, against: type)
        try sidecarLocks.withLock(forKey: key) {
            let existing = try sidecars.read(key)
            let now = Date()
            let createdAt: Date = {
                if let cell = existing?.fields[cellKey],
                   case .object(let inner) = cell.value,
                   case .string(let raw) = inner[SidecarField.innerCreatedAtKey] ?? .null,
                   let parsed = SidecarISO8601.date(from: raw)
                {
                    return parsed
                }
                return now
            }()
            let inner = SidecarField.makeInnerValue(
                field: fieldName,
                type: type,
                value: value,
                createdAt: createdAt
            )
            let cell = SidecarCell(
                value: inner,
                modifiedAt: now,
                modifiedBy: deviceID,
                deletedAt: softDelete ? now : nil
            )
            var fields = existing?.fields ?? [:]
            fields[cellKey] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
        }
    }

    /// Write the group-(a) cache cells. When `includeOnlyChanged` is true,
    /// only the cells whose decoded current value differs from the new one
    /// are written (used by `refreshEventCache` to avoid stamp churn).
    private func writeEventCacheCells(
        at key: SidecarKey,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        eventKitNotes: String?,
        includeOnlyChanged: Bool,
        includeEventKitNotes: Bool = true,
        existingEnvelope: SidecarEnvelope? = nil
    ) throws {
        let envelopeForCompare: SidecarEnvelope?
        if includeOnlyChanged {
            if let provided = existingEnvelope {
                envelopeForCompare = provided
            } else {
                envelopeForCompare = try sidecars.read(key)
            }
        } else {
            envelopeForCompare = nil
        }

        func shouldWrite(cellKey: String, newValue: JSONValue) -> Bool {
            guard includeOnlyChanged else { return true }
            guard let envelope = envelopeForCompare,
                  let cell = envelope.fields[cellKey],
                  case .object(let inner) = cell.value,
                  let current = inner[SidecarField.innerValueKey]
            else { return true }
            return current != newValue
        }

        let titleValue: JSONValue = .string(title)
        if shouldWrite(cellKey: Self.eventTitleCacheKey, newValue: titleValue) {
            try writeWellKnownCell(
                at: key,
                cellKey: Self.eventTitleCacheKey,
                fieldName: Self.eventTitleCacheKey,
                type: .note,
                value: titleValue,
                softDelete: false
            )
        }

        let startValue: JSONValue = .string(SidecarISO8601.string(from: startDate))
        if shouldWrite(cellKey: Self.eventStartCacheKey, newValue: startValue) {
            try writeWellKnownCell(
                at: key,
                cellKey: Self.eventStartCacheKey,
                fieldName: Self.eventStartCacheKey,
                type: .date,
                value: startValue,
                softDelete: false
            )
        }

        let endValue: JSONValue = .string(SidecarISO8601.string(from: endDate))
        if shouldWrite(cellKey: Self.eventEndCacheKey, newValue: endValue) {
            try writeWellKnownCell(
                at: key,
                cellKey: Self.eventEndCacheKey,
                fieldName: Self.eventEndCacheKey,
                type: .date,
                value: endValue,
                softDelete: false
            )
        }

        let isAllDayValue: JSONValue = .bool(isAllDay)
        if shouldWrite(cellKey: Self.eventIsAllDayCacheKey, newValue: isAllDayValue) {
            try writeWellKnownCell(
                at: key,
                cellKey: Self.eventIsAllDayCacheKey,
                fieldName: Self.eventIsAllDayCacheKey,
                type: .checkbox,
                value: isAllDayValue,
                softDelete: false
            )
        }

        let locationValue: JSONValue = .string(location ?? "")
        if shouldWrite(cellKey: Self.eventLocationCacheKey, newValue: locationValue) {
            try writeWellKnownCell(
                at: key,
                cellKey: Self.eventLocationCacheKey,
                fieldName: Self.eventLocationCacheKey,
                type: .note,
                value: locationValue,
                softDelete: false
            )
        }

        if includeEventKitNotes {
            let notesValue: JSONValue = .string(eventKitNotes ?? "")
            if shouldWrite(cellKey: Self.eventNotesCacheKey, newValue: notesValue) {
                try writeWellKnownCell(
                    at: key,
                    cellKey: Self.eventNotesCacheKey,
                    fieldName: Self.eventNotesCacheKey,
                    type: .note,
                    value: notesValue,
                    softDelete: false
                )
            }
        }
    }

    /// Decode the well-known group-(a) cells of an event sidecar into an
    /// `Event` populated from the cache. `id` is derived from the sidecar
    /// key. `eventKitID` is populated only when the cell is live (not
    /// soft-deleted).
    private func decodeCachedEvent(envelope: SidecarEnvelope, key: SidecarKey) -> Event? {
        guard let id = UUID(uuidString: key.id) else { return nil }
        let ekid = liveEventKitID(envelope: envelope)
        let title = decodeStringValue(envelope: envelope, cellKey: Self.eventTitleCacheKey) ?? ""
        let start = decodeDateValue(envelope: envelope, cellKey: Self.eventStartCacheKey)
            ?? Date(timeIntervalSinceReferenceDate: 0)
        let end = decodeDateValue(envelope: envelope, cellKey: Self.eventEndCacheKey)
            ?? start
        let isAllDay = decodeBoolValue(envelope: envelope, cellKey: Self.eventIsAllDayCacheKey) ?? false
        let locationRaw = decodeStringValue(envelope: envelope, cellKey: Self.eventLocationCacheKey)
        let location = (locationRaw?.isEmpty ?? true) ? nil : locationRaw
        let eventKitNotesRaw = decodeStringValue(envelope: envelope, cellKey: Self.eventNotesCacheKey)
        let eventKitNotes = (eventKitNotesRaw?.isEmpty ?? true) ? nil : eventKitNotesRaw
        return Event(
            id: id,
            eventKitID: ekid,
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            location: location,
            eventKitNotes: eventKitNotes
        )
    }

    /// Overlay the EventKit-live values onto a cached `Event`, preserving
    /// the sidecar UUID as `id` and the EventKit pointer.
    private func overlay(live: Event, onto cached: Event, ekid: String) -> Event {
        Event(
            id: cached.id,
            eventKitID: ekid,
            title: live.title,
            startDate: live.startDate,
            endDate: live.endDate,
            isAllDay: live.isAllDay,
            location: live.location,
            eventKitNotes: live.eventKitNotes
        )
    }

    /// True when the envelope-level `deletedAt` cell is live (not absent
    /// and not itself soft-deleted).
    private func isEnvelopeWholeEventDeleted(_ envelope: SidecarEnvelope) -> Bool {
        guard let cell = envelope.fields[Self.eventDeletedAtCellKey] else { return false }
        if cell.deletedAt != nil { return false }
        return true
    }

    /// Returns the `eventKitID` string when the cell is present and live
    /// (not soft-deleted); nil otherwise.
    private func liveEventKitID(envelope: SidecarEnvelope) -> String? {
        guard let cell = envelope.fields[Self.eventKitIDCellKey] else { return nil }
        if cell.deletedAt != nil { return nil }
        guard case .object(let inner) = cell.value,
              case .string(let value) = inner[SidecarField.innerValueKey] ?? .null
        else { return nil }
        return value
    }

    private func decodeStringValue(envelope: SidecarEnvelope, cellKey: String) -> String? {
        guard let cell = envelope.fields[cellKey] else { return nil }
        guard case .object(let inner) = cell.value,
              case .string(let value) = inner[SidecarField.innerValueKey] ?? .null
        else { return nil }
        return value
    }

    private func decodeDateValue(envelope: SidecarEnvelope, cellKey: String) -> Date? {
        guard let raw = decodeStringValue(envelope: envelope, cellKey: cellKey) else { return nil }
        return SidecarISO8601.date(from: raw)
    }

    private func decodeBoolValue(envelope: SidecarEnvelope, cellKey: String) -> Bool? {
        guard let cell = envelope.fields[cellKey] else { return nil }
        guard case .object(let inner) = cell.value,
              case .bool(let value) = inner[SidecarField.innerValueKey] ?? .null
        else { return nil }
        return value
    }
}
