import SwiftUI
import GuessWhoSync

/// Shared link/create sheet for events (E3). Used in three modes:
/// - `.create` — events list "+" → mint a new event (manual or linked)
/// - `.link`   — contact view "Add Event" → choose/create an event then link
///               it to the caller's endpoint (contact, etc.)
/// - `.adopt`  — manual EventDetail "Link to a calendar event" → attach an
///               existing manual sidecar to an EventKit event
struct EventLinkSheet: View {
    enum Mode {
        /// Create a standalone event (events list "+"). Callback returns the
        /// new event's UUID so the caller can navigate to it.
        case create(onCreated: (_ eventUUID: String) -> Void)
        /// Link an existing event to something (contact, or a manual event
        /// adopting EventKit). Callback returns the chosen event's UUID + note.
        case link(onLinked: (_ eventUUID: String, _ note: String) -> Void)
        /// Adopt an existing manual sidecar by attaching it to an EventKit
        /// event the user picks. The sheet calls
        /// `service.linkExistingSidecar(uuid: existingUUID, toEventKitID:)`
        /// on row tap, then fires `onAdopted()` (typically a reload).
        case adopt(eventUUID: String, onAdopted: () -> Void)
    }

    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var search: String = ""
    /// EventKit events grouped by start-of-day. Today is preloaded; the
    /// "Show more" button extends the window forward 365 days, pull-to-
    /// refresh prepends a year at a time backward.
    @State private var loadedDays: [Date: [Event]] = [:]
    @State private var expandedBeyondToday = false
    @State private var loadedForwardThrough: Date = Calendar.current.startOfDay(for: Date())
    @State private var loadedBackwardThrough: Date = Calendar.current.startOfDay(for: Date())
    /// `true` once the user has tapped "Add Other" OR when authorization
    /// blocks calendar browsing (manual-only fallback).
    @State private var manualEntry = false
    /// `true` when a search miss triggered the inline "Search older events"
    /// merge. Used to suppress repeated taps from the same empty state.
    @State private var didMergeOlderSearch = false

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
                .task { initialLoad() }
        }
    }

    private var navigationTitle: String {
        if manualEntry {
            switch mode {
            case .create: return "New Event"
            case .link: return "New Event"
            case .adopt: return "Pick Event"
            }
        }
        switch mode {
        case .create: return "Add Event"
        case .link: return "Pick Event"
        case .adopt: return "Pick Event"
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

            let groups = grouped(filteredEvents)
            if groups.isEmpty {
                emptyOrSearchSection
            } else {
                ForEach(groups, id: \.day) { group in
                    Section(header: Text(sectionTitle(for: group.day))) {
                        ForEach(group.events, id: \.id) { event in
                            Button { pick(event) } label: { eventRow(event) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            if canBrowseCalendar && !expandedBeyondToday {
                Section {
                    Button {
                        loadShowMore()
                    } label: {
                        Label("Show more", systemImage: "chevron.down")
                    }
                }
            }

            // "Add Other" doesn't apply in adopt mode — you can't adopt an
            // existing sidecar to a manual entry; the whole point is to
            // attach an EventKit event.
            if case .adopt = mode {
                EmptyView()
            } else {
                Section {
                    Button {
                        manualEntry = true
                    } label: {
                        Label("Add Other", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search events")
        .refreshable { await loadOneMoreYearBackward() }
    }

    @ViewBuilder
    private var emptyOrSearchSection: some View {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Section {
                Text("No events.")
                    .foregroundStyle(.secondary)
            }
        } else if canBrowseCalendar && !didMergeOlderSearch {
            Section {
                Button {
                    searchOlderEvents()
                } label: {
                    Label("Search older events", systemImage: "magnifyingglass")
                }
            } footer: {
                Text("Searches the past 3 years and next year in your calendar.")
            }
        } else {
            Section {
                Text("No matches.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: Event) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.isLinked ? "calendar" : "calendar.badge.plus")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title.isEmpty ? "(Untitled event)" : event.title)
                    .font(.body)
                HStack(spacing: 6) {
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

    // MARK: - Initial load

    private func initialLoad() {
        if !canBrowseCalendar {
            // No-permission fallback (E3.3): force manual-entry only.
            manualEntry = true
            return
        }
        // Adopt mode skips manual entry entirely — Add Other is hidden.
        let today = Calendar.current.startOfDay(for: Date())
        loadedForwardThrough = today
        loadedBackwardThrough = today
        let todays = service.eventsOnDay(today)
        var bucket = loadedDays
        bucket[today] = todays
        loadedDays = bucket
    }

    private func loadShowMore() {
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 365, to: today) ?? today
        // Use the window read for the range; the orchestrator handles EventKit
        // gating internally and falls back gracefully when access is denied.
        let events = service.fetchEventsRange(from: today, to: end)
        mergeIntoLoadedDays(events)
        expandedBeyondToday = true
        loadedForwardThrough = end
    }

    private func loadOneMoreYearBackward() async {
        guard canBrowseCalendar else { return }
        let to = loadedBackwardThrough
        guard let from = Calendar.current.date(byAdding: .year, value: -1, to: to) else { return }
        let events = service.fetchEventsRange(from: from, to: to)
        await MainActor.run {
            mergeIntoLoadedDays(events)
            loadedBackwardThrough = from
        }
    }

    private func searchOlderEvents() {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canBrowseCalendar else { return }
        let today = Calendar.current.startOfDay(for: Date())
        let from = Calendar.current.date(byAdding: .year, value: -3, to: today) ?? today
        let to = Calendar.current.date(byAdding: .day, value: 365, to: today) ?? today
        let interval = DateInterval(start: from, end: to)
        let hits = service.searchCalendarEvents(text: trimmed, in: interval)
        mergeIntoLoadedDays(hits)
        didMergeOlderSearch = true
    }

    private func mergeIntoLoadedDays(_ events: [Event]) {
        var bucket = loadedDays
        let cal = Calendar.current
        for event in events {
            let day = cal.startOfDay(for: event.startDate)
            var existing = bucket[day] ?? []
            if !existing.contains(where: { $0.id == event.id }) {
                existing.append(event)
            }
            bucket[day] = existing
        }
        loadedDays = bucket
    }

    // MARK: - Filtering + grouping

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

    private func pick(_ event: Event) {
        switch mode {
        case .create(let onCreated):
            guard let uuid = dedupAndLink(event: event) else { return }
            onCreated(uuid)
            dismiss()
        case .link(let onLinked):
            guard let uuid = dedupAndLink(event: event) else { return }
            // Partial-failure note: if `onLinked` throws (caller wraps it via
            // recordError, see SyncService.addContactEventLink path), the
            // sidecar minted by `linkEvent` exists but the contact↔event
            // link does not. The orphan sidecar is harmless and the user can
            // retry the link from the contact view (per E3.2 partial-failure
            // handling).
            onLinked(uuid, pickedRowNote.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        case .adopt(let existingUUID, let onAdopted):
            // Adopt: attach an existing manual sidecar to the picked EventKit
            // event. No mint — `linkExistingSidecar` writes the eventKitID
            // cell on the existing envelope.
            guard let ekid = event.eventKitID else {
                service.recordError("adopt failed: picked event has no eventKitID")
                return
            }
            do {
                try service.linkExistingSidecar(uuid: existingUUID, toEventKitID: ekid)
            } catch {
                service.recordError("link existing sidecar failed: \(error.localizedDescription)")
                return
            }
            onAdopted()
            dismiss()
        }
    }

    /// Mandatory dedup path (E3.2 / C-SHEET-DEDUP): first look up the sidecar
    /// already pointing at this EventKit ID; only mint when there isn't one.
    /// Returns the resulting event UUID string, or nil on failure (after
    /// recording the error).
    private func dedupAndLink(event: Event) -> String? {
        guard let ekid = event.eventKitID else {
            // Already a sidecar-only event (no EventKit twin). Reuse its UUID
            // directly.
            return event.id.uuidString
        }
        if let existing = service.eventUUID(forEventKitID: ekid) {
            return existing.uuidString
        }
        do {
            let minted = try service.linkEvent(toEventKitID: ekid)
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
            // caller wires the contact↔event link (E3.2 / C-ADDOTHER-LINKMODE).
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
        case .adopt:
            // Adopt mode has no manual-entry path — Add Other is hidden in
            // the picker, so this branch is unreachable in practice. Be
            // defensive: do nothing.
            dismiss()
        }
    }
}
