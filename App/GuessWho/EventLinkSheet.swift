import SwiftUI
import GuessWhoSync

/// Shared event picker/create sheet. Used in two modes:
/// - `.create` — events list "+" → mint a new GuessWho event (sidecar-backed,
///               optionally also written to Calendar.app)
/// - `.link`   — contact view "Link Event" → choose an existing event or
///               create a new one, then attach it to the caller's endpoint
///
/// There is intentionally NO "adopt an EventKit event into a sidecar" mode —
/// see CLAUDE.md "Product principle: sidecar is an implementation detail."
/// Adoption happens automatically on first read of an EventKit-only row via
/// `EventDetailView.reload()`'s adopt-on-load path.
struct EventLinkSheet: View {
    enum Mode {
        /// Create a standalone event (events list "+"). Callback returns the
        /// new event's UUID so the caller can navigate to it.
        case create(onCreated: (_ eventUUID: String) -> Void)
        /// Link an existing event to something (contact, etc.). Callback
        /// returns the chosen event's UUID + note.
        case link(onLinked: (_ eventUUID: String, _ note: String) -> Void)
    }

    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var search: String = ""
    /// The event pool, grouped by start-of-day. Every load path merges here:
    /// the initial today window, the repeatable "Load older events" button
    /// (one month backward per tap), "Show more" (a year forward), the
    /// one-time ±5-year search backfill, and the sidecar walk that keeps
    /// app-created events findable. Browsing shows only the loaded window
    /// (plus sidecar-backed events); searching filters the whole pool.
    @State private var loadedDays: [Date: [Event]] = [:]
    @State private var expandedBeyondToday = false
    @State private var loadedForwardThrough: Date = Calendar.current.startOfDay(for: Date())
    @State private var loadedBackwardThrough: Date = Calendar.current.startOfDay(for: Date())
    /// Dedup keys (see `dedupKey(for:)`) of every sidecar-backed event merged
    /// into the pool. Sidecar-backed events are the user's own records
    /// (created or previously linked in the app), so they stay visible while
    /// browsing even when their day falls outside the loaded window — that's
    /// what makes a custom event reachable without paging to its month.
    @State private var sidecarEventKeys: Set<String> = []
    /// The most recently linked events, newest first (link-mode only) —
    /// rendered as a "Recently Linked" section above the day groups.
    @State private var recentlyLinked: [Event] = []
    /// `true` once the user has tapped "Add Other".
    @State private var manualEntry = false
    /// One-time ±5-year calendar backfill for search: flipped after the first
    /// non-empty search term triggers the wide window merge, so every later
    /// keystroke filters locally instead of re-walking ten years of calendar.
    @State private var didLoadSearchWindow = false
    @State private var searchWindowLoading = false

    // Manual-entry form fields.
    @State private var draftTitle: String = ""
    @State private var draftStart: Date = Date()
    @State private var draftEnd: Date = Date().addingTimeInterval(3600)
    @State private var draftLocation: String = ""
    @State private var draftAllDay: Bool = false
    /// Create-mode only. When ON and authorized, save calls
    /// `service.createLinkedEvent` instead of `createManualEvent`.
    @State private var draftAddToCalendar: Bool = false
    /// Link-mode only. Note to attach when the caller wires the link.
    @State private var draftLinkNote: String = ""

    /// Note attached to the picked event in `.link` mode (separate from the
    /// Add-Other form's `draftLinkNote`; rendered in a footer on the event
    /// picker so users can type before tapping a row).
    @State private var pickedRowNote: String = ""

    /// Guards `pick` against a double-fire: the dedup/link path awaits now,
    /// so a fast second tap on a row (or another row) could otherwise run
    /// `onCreated`/`onLinked` twice before the first `dismiss()` lands.
    /// Mirrors `EventDetailView.adoptionInFlight`. Never reset on the happy
    /// path — the sheet dismisses; reset only on the nil-UUID failure path
    /// so the user can retry.
    @State private var pickInFlight = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if manualEntry {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { saveManualEntry() }
                                .disabled(!manualFormValid)
                        }
                    }
                }
                .task { await initialLoad() }
        }
    }

    private var navigationTitle: String {
        if manualEntry {
            return "New Event"
        }
        switch mode {
        case .create: return "Add Event"
        case .link: return "Pick Event"
        }
    }

    // MARK: - Top-level content

    @ViewBuilder
    private var content: some View {
        if manualEntry {
            manualEntryForm
        } else {
            eventPickerList
        }
    }

    // MARK: - Event picker list

    @ViewBuilder
    private var eventPickerList: some View {
        List {
            if !canBrowseCalendar {
                Section {
                    Text("Enable Calendar access in Settings to link events from your calendar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Link-mode picker exposes a note field at the top so users can
            // type once, then tap a row — preserves intent across dismissal.
            if case .link = mode {
                Section("Note") {
                    TextField("Optional note", text: $pickedRowNote, axis: .vertical)
                }
            }

            if isSearching, searchWindowLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching your calendar…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Link-mode only, hidden while searching (the same events are in
            // the search pool). Rows show their date — unlike the day groups
            // below, this section spans arbitrary days.
            if case .link = mode, !isSearching, !recentlyLinked.isEmpty {
                Section("Recently Linked") {
                    ForEach(recentlyLinked, id: \.id) { event in
                        Button { Task { await pick(event) } } label: { eventRow(event, showsDate: true) }
                            .buttonStyle(.plain)
                    }
                }
            }

            // Repeatable backward paging: each tap prepends one more month.
            // Hidden while searching — the search pool already spans ±5 years.
            if canBrowseCalendar && !isSearching {
                Section {
                    Button {
                        Task { await loadOlderMonth() }
                    } label: {
                        Label("Load older events (\(previousMonthTitle))", systemImage: "chevron.up")
                    }
                }
            }

            let groups = grouped(visibleEvents)
            if groups.isEmpty {
                emptySection
            } else {
                ForEach(groups, id: \.day) { group in
                    Section(header: Text(sectionTitle(for: group.day))) {
                        ForEach(group.events, id: \.id) { event in
                            Button { Task { await pick(event) } } label: { eventRow(event) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            if canBrowseCalendar && !expandedBeyondToday && !isSearching {
                Section {
                    Button {
                        Task { await loadShowMore() }
                    } label: {
                        Label("Show more", systemImage: "chevron.down")
                    }
                }
            }

            Section {
                Button {
                    manualEntry = true
                } label: {
                    Label("Add Other", systemImage: "square.and.pencil")
                }
            }
        }
        .searchable(text: $search, prompt: "Search events")
        .refreshable { await loadOlderMonth() }
        // First non-empty search term backfills the pool with ±5 years of
        // calendar (once per sheet); afterwards every search is a local
        // filter. Debounced so a burst of keystrokes triggers one load, and
        // keyed on `search` so an abandoned term cancels the pending load.
        .task(id: search) {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, canBrowseCalendar, !didLoadSearchWindow else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await loadSearchWindow()
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            Text(isSearching ? "No matches." : "No events.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func eventRow(_ event: Event, showsDate: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title.isEmpty ? "(Untitled event)" : event.title)
                    .font(.body)
                HStack(spacing: 6) {
                    // Rows inside a day group inherit their date from the
                    // section header; rows in cross-day sections (Recently
                    // Linked) carry it themselves.
                    if showsDate {
                        Text(event.startDate, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("•").font(.caption).foregroundStyle(.secondary)
                    }
                    if event.isAllDay {
                        Text("All-day")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(event.startDate, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let location = event.location, !location.isEmpty {
                        Text("•").font(.caption).foregroundStyle(.secondary)
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Manual entry form

    @ViewBuilder
    private var manualEntryForm: some View {
        Form {
            if !canBrowseCalendar {
                Section {
                    Text("Enable Calendar access in Settings to link events from your calendar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Title") {
                TextField("Title", text: $draftTitle)
            }
            Section("When") {
                Toggle("All-day", isOn: $draftAllDay)
                DatePicker(
                    "Starts",
                    selection: $draftStart,
                    displayedComponents: draftAllDay ? [.date] : [.date, .hourAndMinute]
                )
                DatePicker(
                    "Ends",
                    selection: $draftEnd,
                    displayedComponents: draftAllDay ? [.date] : [.date, .hourAndMinute]
                )
            }
            Section("Location") {
                TextField("Location", text: $draftLocation)
            }

            // Create-mode "Add to Calendar" toggle — when enabled, save uses
            // `createLinkedEvent` so an EKEvent lands in
            // `defaultCalendarForNewEvents`.
            if case .create = mode {
                Section {
                    Toggle("Add to Calendar", isOn: $draftAddToCalendar)
                        .disabled(!canAddToCalendar)
                } footer: {
                    if !canAddToCalendar {
                        Text("Enable Calendar to add events to your calendar.")
                    }
                }
            }

            // Link-mode "Note" field — captured into the contact↔event link
            // when the caller's `onLinked` fires.
            if case .link = mode {
                Section("Note") {
                    TextField("Optional note", text: $draftLinkNote, axis: .vertical)
                }
            }

            // Allow the user to back out of manual entry to the picker when
            // calendar browsing is still available.
            if canBrowseCalendar {
                Section {
                    Button {
                        manualEntry = false
                    } label: {
                        Label("Browse calendar instead", systemImage: "calendar")
                    }
                }
            }
        }
    }

    private var manualFormValid: Bool {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && draftStart <= draftEnd
    }

    // MARK: - State helpers

    private var canBrowseCalendar: Bool {
        service.eventsAuthorization == .authorized
    }

    private var canAddToCalendar: Bool {
        service.eventsAuthorization == .authorized
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "May 2026"-style title of the month the next "Load older events" tap
    /// will prepend.
    private var previousMonthTitle: String {
        let cal = Calendar.current
        let previous = cal.date(byAdding: .month, value: -1, to: loadedBackwardThrough) ?? loadedBackwardThrough
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: previous)
    }

    // MARK: - Loading

    /// Every load goes through the sidecar-inclusive window read
    /// (`fetchEventsRange`), so app-created (manual) events surface alongside
    /// calendar ones. When calendar access is denied the picker still shows
    /// the user's own events instead of forcing manual entry — the hint
    /// section at the top explains how to enable calendar browsing.
    private func initialLoad() async {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        loadedForwardThrough = tomorrow
        loadedBackwardThrough = today
        let todays = await service.fetchEventsRange(from: today, to: tomorrow)
        mergeIntoLoadedDays(todays)
        // Sidecar-backed events join the pool unconditionally: they're the
        // user's own records, so search — and the always-visible carve-out in
        // `visibleEvents` — must reach them no matter the loaded window.
        let sidecarEvents = await service.allSidecarEvents()
        mergeIntoLoadedDays(sidecarEvents, sidecarBacked: true)
        if case .link = mode {
            recentlyLinked = await service.recentlyLinkedEvents(limit: 5)
        }
    }

    private func loadShowMore() async {
        let from = loadedForwardThrough
        let end = Calendar.current.date(byAdding: .day, value: 365, to: from) ?? from
        // Use the window read for the range; the orchestrator handles EventKit
        // gating internally and falls back gracefully when access is denied.
        let events = await service.fetchEventsRange(from: from, to: end)
        mergeIntoLoadedDays(events)
        expandedBeyondToday = true
        loadedForwardThrough = end
    }

    private func loadOlderMonth() async {
        guard canBrowseCalendar else { return }
        let to = loadedBackwardThrough
        guard let from = Calendar.current.date(byAdding: .month, value: -1, to: to) else { return }
        let events = await service.fetchEventsRange(from: from, to: to)
        mergeIntoLoadedDays(events)
        loadedBackwardThrough = from
    }

    /// One-time search backfill: merge five years back and five years ahead
    /// into the pool, then let `filteredEvents` do all the matching locally.
    /// The window read is a single chunk-safe EventKit batch plus the sidecar
    /// walk, hopped to a background queue by the service.
    private func loadSearchWindow() async {
        guard !searchWindowLoading, !didLoadSearchWindow else { return }
        searchWindowLoading = true
        defer { searchWindowLoading = false }
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = Calendar.current.date(byAdding: .year, value: -5, to: today),
              let to = Calendar.current.date(byAdding: .year, value: 5, to: today)
        else { return }
        let events = await service.fetchEventsRange(from: from, to: to)
        mergeIntoLoadedDays(events)
        didLoadSearchWindow = true
    }

    /// Stable cross-source identity for dedup. The window reads
    /// (`fetchEventsRange`/`eventsWindow`) and the sidecar walk
    /// (`allSidecarEvents`) live in two id-spaces: ephemeral EventKit-only
    /// rows carry `Event.stableID(forEventKitID:)` while sidecar-backed rows
    /// carry the real sidecar UUID. Both produce the SAME `eventKitID` for
    /// any EventKit-backed event, so it dedups across both. Manual events
    /// (no `eventKitID`) only ever carry their sidecar UUID and so can't
    /// collide; fall back to the UUID string. Do NOT "simplify" this back to
    /// `event.id` — that key silently produces duplicate rows for any
    /// user-touched (linked) EventKit event.
    private func dedupKey(for event: Event) -> String {
        event.eventKitID ?? event.id.uuidString
    }

    /// `sidecarBacked: true` marks the merged events as the user's own
    /// records (see `sidecarEventKeys`); the events themselves land in the
    /// same pool either way.
    private func mergeIntoLoadedDays(_ events: [Event], sidecarBacked: Bool = false) {
        var bucket = loadedDays
        let cal = Calendar.current
        for event in events {
            let day = cal.startOfDay(for: event.startDate)
            var existing = bucket[day] ?? []
            let key = dedupKey(for: event)
            if sidecarBacked {
                sidecarEventKeys.insert(key)
            }
            if !existing.contains(where: { dedupKey(for: $0) == key }) {
                existing.append(event)
            }
            bucket[day] = existing
        }
        loadedDays = bucket
    }

    // MARK: - Filtering + grouping

    /// What the day groups render. Browsing shows the loaded window plus the
    /// user's own (sidecar-backed) events — merged search hits from outside
    /// the window must NOT linger in the browse list after the search field
    /// clears. Searching matches the whole pool, which spans ±5 years once
    /// `loadSearchWindow` has run.
    private var visibleEvents: [Event] {
        guard !isSearching else { return filteredEvents }
        return loadedDays.values.flatMap { $0 }.filter { event in
            if sidecarEventKeys.contains(dedupKey(for: event)) { return true }
            return event.startDate >= loadedBackwardThrough && event.startDate <= loadedForwardThrough
        }
    }

    private var filteredEvents: [Event] {
        let all = loadedDays.values.flatMap { $0 }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.lowercased()
        return all.filter { event in
            if event.title.lowercased().contains(needle) { return true }
            if let location = event.location, location.lowercased().contains(needle) { return true }
            return false
        }
    }

    /// Group events by `Calendar.startOfDay`, sorted ascending by day; events
    /// within a day sorted by start time.
    private func grouped(_ events: [Event]) -> [(day: Date, events: [Event])] {
        let cal = Calendar.current
        var bucketed: [Date: [Event]] = [:]
        for event in events {
            let day = cal.startOfDay(for: event.startDate)
            bucketed[day, default: []].append(event)
        }
        return bucketed.keys.sorted().map { day in
            let sorted = (bucketed[day] ?? []).sorted { $0.startDate < $1.startDate }
            return (day, sorted)
        }
    }

    private func sectionTitle(for day: Date) -> String {
        let today = Calendar.current.startOfDay(for: Date())
        if Calendar.current.isDate(day, inSameDayAs: today) {
            return "Today"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: day)
    }

    // MARK: - Row tap / save

    private func pick(_ event: Event) async {
        guard !pickInFlight else { return }
        pickInFlight = true
        switch mode {
        case .create(let onCreated):
            guard let uuid = await dedupAndLink(event: event) else {
                pickInFlight = false
                return
            }
            onCreated(uuid)
            dismiss()
        case .link(let onLinked):
            guard let uuid = await dedupAndLink(event: event) else {
                pickInFlight = false
                return
            }
            // Partial-failure note: if `onLinked` throws (caller wraps it via
            // recordError, see SyncService.addContactEventLink path), the
            // sidecar minted by `linkEvent` exists but the contact↔event
            // link does not. The orphan sidecar is harmless and the user can
            // retry the link from the contact view.
            onLinked(uuid, pickedRowNote.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        }
    }

    /// Mandatory dedup path: first look up the sidecar already pointing at this
    /// EventKit ID; only mint when there isn't one. Returns the resulting event
    /// UUID string, or nil on failure (after recording the error). `async` —
    /// the dedup lookup walks every event sidecar via the service.
    private func dedupAndLink(event: Event) async -> String? {
        guard let ekid = event.eventKitID else {
            // Already a sidecar-only event (no EventKit twin). Reuse its UUID
            // directly.
            return event.id.uuidString
        }
        if let existing = await service.eventUUID(forEventKitID: ekid) {
            return existing.uuidString
        }
        do {
            let minted = try await service.linkEvent(toEventKitID: ekid)
            return minted.uuidString
        } catch {
            service.recordError("link event failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveManualEntry() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = draftLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationOrNil: String? = location.isEmpty ? nil : location
        switch mode {
        case .create(let onCreated):
            let newUUID: UUID
            do {
                if draftAddToCalendar && canAddToCalendar {
                    newUUID = try service.createLinkedEvent(
                        title: title,
                        startDate: draftStart,
                        endDate: draftEnd,
                        isAllDay: draftAllDay,
                        location: locationOrNil
                    )
                } else {
                    newUUID = try service.createManualEvent(
                        title: title,
                        startDate: draftStart,
                        endDate: draftEnd,
                        isAllDay: draftAllDay,
                        location: locationOrNil
                    )
                }
            } catch {
                service.recordError("create event failed: \(error.localizedDescription)")
                return
            }
            onCreated(newUUID.uuidString)
            dismiss()
        case .link(let onLinked):
            // Manual-entry in link mode mints a sidecar-only event and hands
            // its UUID to the caller, along with the draft link note. The
            // caller wires the contact↔event link.
            let newUUID: UUID
            do {
                newUUID = try service.createManualEvent(
                    title: title,
                    startDate: draftStart,
                    endDate: draftEnd,
                    isAllDay: draftAllDay,
                    location: locationOrNil
                )
            } catch {
                service.recordError("create manual event failed: \(error.localizedDescription)")
                return
            }
            onLinked(newUUID.uuidString, draftLinkNote.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        }
    }
}
