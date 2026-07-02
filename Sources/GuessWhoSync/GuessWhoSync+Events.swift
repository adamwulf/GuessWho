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
    ///
    /// `internal` (not `public`) — no UI may call this. Per the product
    /// principle (see CLAUDE.md) the sidecar / EventKit boundary is never
    /// user-visible; adoption happens automatically on first read. Kept so
    /// existing tests still exercise the write path.
    func linkExistingSidecar(at key: SidecarKey, toEventKitID ekid: String) throws {
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
    ///
    /// `internal` (not `public`) — same rationale as `linkExistingSidecar`:
    /// the user never sees a "linked vs unlinked" concept. Kept so existing
    /// tests still exercise the write path.
    func unlinkEvent(at key: SidecarKey) throws {
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

    /// Async overload of `eventsWindow(from:to:includeEventKit:)` that hops
    /// the read to a background queue. The window read is EventKit's
    /// synchronous `events(matching:)` PLUS a coordinated read of every event
    /// sidecar — both scale with data size and must not block the caller's
    /// actor / main thread. Same continuation-hop pattern (and `self` capture
    /// rationale) as `recentEvents(matchingEmails:)` below. Sync callers (and
    /// the tests) keep the synchronous overload.
    public func eventsWindow(
        from: Date,
        to: Date,
        includeEventKit: Bool = true
    ) async throws -> [Event] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [Event] = try self.eventsWindow(
                        from: from, to: to, includeEventKit: includeEventKit
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Attendee lookup (contact detail "Recent Events")

    /// Async wrapper around `events.eventsWithAttendee(...)` for the contact
    /// detail "Recent Events" section. Builds a window of `[asOf - 10y, asOf
    /// + 1y]` and hops the EventKit scan to a background queue via
    /// `withCheckedThrowingContinuation`: EventKit's `events(matching:)` is
    /// synchronous and scales with the window's calendar size, so it must NOT
    /// block the caller's actor / main thread. Returns events sorted
    /// most-recent-first, capped at `limit`.
    public func recentEvents(
        matchingEmails emails: Set<String>,
        asOf now: Date = Date(),
        limit: Int = 10
    ) async throws -> [Event] {
        guard !emails.isEmpty, limit > 0 else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .year, value: -10, to: now) ?? now
        let end = calendar.date(byAdding: .year, value: 1, to: now) ?? now
        let interval = DateInterval(start: start, end: end)
        // Capture `self` (which is `@unchecked Sendable`) rather than `events`
        // directly — `EventStoreProtocol` doesn't conform to `Sendable`, so a
        // bare capture would trip the `SendableClosureCaptures` warning even
        // though every conforming adapter is internally thread-safe.
        return try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.events.eventsWithAttendee(
                        matchingEmails: emails,
                        in: interval,
                        limit: limit
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Write one §5.2 cell at a fixed cell key (vs. the minted-UUID keys used
    /// by field-instance cells). Mirrors `addField`'s cell-construction shape so
    /// `SidecarField.decode` still reads it, under the per-key
    /// `sidecarLocks.withLock` discipline. `softDelete == true` stamps
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

    /// Overlay the EventKit-live values onto a cached `Event`, preserving the
    /// sidecar UUID as `id` and the EventKit pointer. Attendees and the calendar
    /// name + color are always taken from the live EKEvent — none are cached in
    /// the sidecar, so they must be carried through here, else an adopted/linked
    /// event loses them the moment it resolves through this overlay.
    private func overlay(live: Event, onto cached: Event, ekid: String) -> Event {
        Event(
            id: cached.id,
            eventKitID: ekid,
            title: live.title,
            startDate: live.startDate,
            endDate: live.endDate,
            isAllDay: live.isAllDay,
            location: live.location,
            eventKitNotes: live.eventKitNotes,
            attendees: live.attendees,
            calendarName: live.calendarName,
            calendarColorHex: live.calendarColorHex
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

    // MARK: - Migration (E5)

    /// One-shot pre-pivot → post-pivot event-sidecar migration. Idempotent;
    /// safe to call at every launch until it converges. Does NOT require
    /// Contacts or EventKit permission (the EventKit fetch is best-effort;
    /// the dead-pointer branch handles the unauthorized case the same as
    /// the gone-event case).
    ///
    /// Step 1: for every not-yet-UUID-keyed `events/<legacyEventIdentifier>.json`
    /// sidecar, mint a new event UUID, translate the legacy identifier to a
    /// `calendarItemExternalIdentifier` via the adapter's
    /// `fetch(legacyEventIdentifier:)`, write a new envelope at the UUID key
    /// (with `eventKitID` cell + cache seeded from the resolved EKEvent, or the
    /// original legacy id as a dead pointer when unresolved), preserving any
    /// pre-existing field-instance cells (notes, tags), then delete the legacy
    /// file.
    ///
    /// Step 2: rewrite every contact↔event `Link` whose `.event` endpoint
    /// still points at a legacy identifier to point at the freshly-minted
    /// UUID instead. One envelope write per link.
    @discardableResult
    public func migrateEventsToSidecarFirst() throws -> EventMigrationReport {
        // (originalCase, lowercased) pairs collected from listKeys. Order is
        // arbitrary; the migration is per-key independent.
        var legacyKeys: [(original: String, lowered: String)] = []
        var skipped: [String] = []
        var migrated: [(oldExternalID: String, newUUID: UUID)] = []

        // The mapping passed to `rewriteEventLinkEndpoints` is keyed by the
        // lowercased legacy id because `Link.decodeEndpoint` routes through
        // `SidecarKey.init`'s `.event` lowercasing branch — so any decoded
        // endpoint id we compare against has already been lowercased.
        var mapping: [String: UUID] = [:]

        for key in try sidecars.allKeys() where key.kind == .event {
            // Any UUID-keyed event sidecar is post-pivot (legacy
            // `eventIdentifier` strings are never UUID-shaped), so skip it —
            // whether or not it has an `eventKitID` cell. This also spares
            // manual events (UUID key, no `eventKitID` cell) from re-migration.
            if UUID(uuidString: key.id) != nil {
                skipped.append(key.id)
                continue
            }
            // Treat key.id as a legacy `eventIdentifier`. `listKeys`'s
            // percent-decode path preserves the original case; we must keep
            // it for the case-sensitive EventKit lookup, AND keep a
            // lowercased copy for the map / the new UUID-keyed write.
            legacyKeys.append((original: key.id, lowered: key.id.lowercased()))
        }

        for legacy in legacyKeys {
            let newUUID = UUID()
            // SidecarKey for the legacy file. The .event branch lowercases
            // unconditionally per E1.4, so keys built from the original-case id
            // and from the lowercased id are equal — but the FS store names the
            // file with original-case bytes via the percent-decode path, while
            // the in-memory store hashes the lowercased id consistently.
            let oldKey = SidecarKey(kind: .event, id: legacy.original)
            let newKey = SidecarKey(kind: .event, id: newUUID.uuidString)

            // Read the legacy envelope first so we preserve any pre-existing
            // field-instance cells (notes, tags) the user attached.
            let oldEnvelope = try sidecars.read(oldKey)

            // Translate identifier via the migration-only resolver. The
            // EKEvent lookup is fed the ORIGINAL-case id (EventKit is
            // case-sensitive).
            let resolved = try? events.fetch(legacyEventIdentifier: legacy.original)

            // Choose what goes in the `eventKitID` cell.
            let pointerValue: String
            let cacheSeed: Event?
            if let resolved, let ekid = resolved.eventKitID {
                pointerValue = ekid
                cacheSeed = resolved
            } else {
                // Dead pointer: keep the original-case legacy identifier so
                // the dual-namespace `fetch(eventKitID:)` may still resolve
                // it later if the EKEvent reappears.
                pointerValue = legacy.original
                cacheSeed = nil
            }

            // Build the new envelope cells.
            let now = Date()
            var newFields: [String: SidecarCell] = [:]

            // Preserve any pre-existing field-instance cells (notes, tags).
            // Field-instance keys are UUIDs; well-known event cell keys are
            // human-readable strings. Carry forward verbatim anything whose key
            // parses as a UUID; the well-known cells (`eventKitID`, `titleCache`,
            // …) are rewritten from scratch below.
            if let oldEnvelope {
                for (cellKey, cell) in oldEnvelope.fields {
                    if UUID(uuidString: cellKey) != nil {
                        newFields[cellKey] = cell
                    }
                }
            }

            // eventKitID cell.
            newFields[Self.eventKitIDCellKey] = SidecarCell(
                value: SidecarField.makeInnerValue(
                    field: Self.eventKitIDCellKey,
                    type: .note,
                    value: .string(pointerValue),
                    createdAt: now
                ),
                modifiedAt: now,
                modifiedBy: deviceID,
                deletedAt: nil
            )

            // Cache cells.
            if let seed = cacheSeed {
                newFields[Self.eventTitleCacheKey] = makeCellCell(
                    fieldName: Self.eventTitleCacheKey,
                    type: .note,
                    value: .string(seed.title),
                    now: now
                )
                newFields[Self.eventStartCacheKey] = makeCellCell(
                    fieldName: Self.eventStartCacheKey,
                    type: .date,
                    value: .string(SidecarISO8601.string(from: seed.startDate)),
                    now: now
                )
                newFields[Self.eventEndCacheKey] = makeCellCell(
                    fieldName: Self.eventEndCacheKey,
                    type: .date,
                    value: .string(SidecarISO8601.string(from: seed.endDate)),
                    now: now
                )
                newFields[Self.eventIsAllDayCacheKey] = makeCellCell(
                    fieldName: Self.eventIsAllDayCacheKey,
                    type: .checkbox,
                    value: .bool(seed.isAllDay),
                    now: now
                )
                newFields[Self.eventLocationCacheKey] = makeCellCell(
                    fieldName: Self.eventLocationCacheKey,
                    type: .note,
                    value: .string(seed.location ?? ""),
                    now: now
                )
                newFields[Self.eventNotesCacheKey] = makeCellCell(
                    fieldName: Self.eventNotesCacheKey,
                    type: .note,
                    value: .string(seed.eventKitNotes ?? ""),
                    now: now
                )
            }

            let newEnvelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: newKey.id,
                fields: newFields
            )

            try sidecarLocks.withLock(forKey: newKey) {
                try sidecars.write(newEnvelope, at: newKey)
            }
            try sidecarLocks.withLock(forKey: oldKey) {
                try sidecars.delete(oldKey)
            }

            migrated.append((oldExternalID: legacy.original, newUUID: newUUID))
            mapping[legacy.lowered] = newUUID
        }

        // Step 2: rewrite link endpoints. Uses the lowercased map (matches
        // what `Link.decodeEndpoint` produces after SidecarKey.init's .event
        // lowercasing).
        let rewrittenLinkIDs = try rewriteEventLinkEndpoints(mapping: mapping)

        return EventMigrationReport(
            migratedEvents: migrated,
            rewrittenLinkIDs: rewrittenLinkIDs,
            skipped: skipped
        )
    }

    /// Migration-only helper. Like `rewriteLinkEndpoints` in
    /// `GuessWhoSync.swift`, but matches `.event` endpoints whose id appears in
    /// `mapping`. One envelope write per affected link, under the per-key
    /// `sidecarLocks` discipline. The mapping is keyed by the **lowercased**
    /// legacy `eventIdentifier` to line up with `Link.decodeEndpoint`'s
    /// lowercased output. Returns the link UUIDs whose endpoint A and/or B was
    /// rewritten.
    private func rewriteEventLinkEndpoints(mapping: [String: UUID]) throws -> [UUID] {
        guard !mapping.isEmpty else { return [] }

        var rewritten: [UUID] = []
        for key in try sidecars.allKeys() where key.kind == .link {
            // Cheap pre-screen. The authoritative read happens inside the
            // lock below; this read may be a moment stale.
            guard let pre = try sidecars.read(key) else { continue }
            guard let preA = pre.fields[Link.endpointAKey],
                  let preB = pre.fields[Link.endpointBKey],
                  let preAEnd = Link.decodeEndpoint(preA.value),
                  let preBEnd = Link.decodeEndpoint(preB.value) else { continue }
            let preAMatches = preAEnd.kind == .event && mapping[preAEnd.id] != nil
            let preBMatches = preBEnd.kind == .event && mapping[preBEnd.id] != nil
            guard preAMatches || preBMatches else { continue }

            try sidecarLocks.withLock(forKey: key) {
                // Re-read inside the lock: a concurrent setLinkNote or
                // removeLink may have written between the pre-screen and now.
                guard let envelope = try sidecars.read(key) else { return }
                guard let aCell = envelope.fields[Link.endpointAKey],
                      let bCell = envelope.fields[Link.endpointBKey],
                      let aEnd = Link.decodeEndpoint(aCell.value),
                      let bEnd = Link.decodeEndpoint(bCell.value) else { return }
                let aWinner = aEnd.kind == .event ? mapping[aEnd.id] : nil
                let bWinner = bEnd.kind == .event ? mapping[bEnd.id] : nil
                guard aWinner != nil || bWinner != nil else { return }

                let now = Date()
                var fields = envelope.fields
                if let w = aWinner {
                    fields[Link.endpointAKey] = SidecarCell(
                        value: Link.encodeEndpoint(SidecarKey(kind: .event, id: w.uuidString)),
                        modifiedAt: now,
                        modifiedBy: deviceID
                    )
                }
                if let w = bWinner {
                    fields[Link.endpointBKey] = SidecarCell(
                        value: Link.encodeEndpoint(SidecarKey(kind: .event, id: w.uuidString)),
                        modifiedAt: now,
                        modifiedBy: deviceID
                    )
                }
                try sidecars.write(
                    SidecarEnvelope(schemaVersion: 1, entityID: envelope.entityID, fields: fields),
                    at: key
                )

                if let linkID = UUID(uuidString: key.id) {
                    rewritten.append(linkID)
                }
            }
        }
        return rewritten
    }

    private func makeCellCell(
        fieldName: String,
        type: SidecarFieldType,
        value: JSONValue,
        now: Date
    ) -> SidecarCell {
        SidecarCell(
            value: SidecarField.makeInnerValue(
                field: fieldName,
                type: type,
                value: value,
                createdAt: now
            ),
            modifiedAt: now,
            modifiedBy: deviceID,
            deletedAt: nil
        )
    }
}
