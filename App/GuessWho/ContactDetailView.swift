import SwiftUI
import Contacts
import MapKit
import GuessWhoSync

struct ContactDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(ContactsRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    let localID: String

    @State private var contact: Contact?
    @State private var sidecar: SidecarEnvelope?
    @State private var notesStore: NotesStore?
    @State private var reconcileOutcome: IdentityReconcileReport.ContactOutcome?
    @State private var reconcileError: String?
    @State private var didAutoReconcile = false

    // Focus identity covers both the bottom new-note editor and any row
    // currently being edited. Hoisted here so a single nav-bar checkmark
    // can commit whichever edit is active and dismiss the keyboard.
    fileprivate enum NoteFocus: Hashable {
        case newNote
        case row(UUID)
    }
    @FocusState private var noteFocus: NoteFocus?
    @State private var newNoteText: String = ""
    @State private var editingID: UUID?
    @State private var draftBody: String = ""
    // Body captured at edit-start, used by §12.5's no-op-tap rule: commit
    // is a no-op only when the draft is unchanged from this snapshot —
    // never the current on-disk value. Matters when a reconcile lands
    // mid-edit and rewrites the on-disk body.
    @State private var editStartSnapshot: String = ""

    private var isEditingAnything: Bool {
        noteFocus != nil
    }

    var body: some View {
        Form {
            if let contact {
                infoSection(contact)

                referencedBySection(contact)

                if let notesStore {
                    NotesSection(
                        store: notesStore,
                        newNoteText: $newNoteText,
                        editingID: $editingID,
                        draftBody: $draftBody,
                        noteFocus: $noteFocus,
                        beginEdit: beginEdit(_:),
                        deleteNote: deleteNote(_:)
                    )
                }

                #if DEBUG
                debugSection(contact)
                #endif
            } else {
                ProgressView()
            }
        }
        .navigationTitle(contact?.displayName ?? "Contact")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    commitActiveEdit()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Back")
            }
            if isEditingAnything {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commitActiveEdit()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .accessibilityLabel("Done")
                }
            }
        }
        .task {
            await loadContact()
            if !didAutoReconcile {
                didAutoReconcile = true
                await performReconcile()
            }
        }
        .onDisappear {
            // Backstop for the edge-swipe-back gesture: the system pop
            // bypasses our custom back button, so commit here too. A no-op
            // if commitActiveEdit() already ran from a button tap.
            commitActiveEdit()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func infoSection(_ contact: Contact) -> some View {
        // Mirror Apple's Contacts: one card with every populated field as
        // a label-above-value row, in roughly the same order Contacts uses.
        let rows = infoRows(for: contact)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    InfoRow(data: row)
                }
            }
        }
    }

    @ViewBuilder
    private func referencedBySection(_ contact: Contact) -> some View {
        let backrefs = repository.contactsReferencing(displayName: contact.displayName)
        if !backrefs.isEmpty {
            let rows = backrefs.map { entry in
                InfoRowData.contactLink(
                    label: localizedLabel(entry.label),
                    displayName: entry.contact.displayName,
                    localID: entry.contact.localID
                )
            }
            Section("Referenced By") {
                ForEach(rows) { row in
                    InfoRow(data: row)
                }
            }
        }
    }

    private func infoRows(for contact: Contact) -> [InfoRowData] {
        var rows: [InfoRowData] = []

        // Skip the individual name parts — the navigation title already
        // shows the contact's name. Job title / organization are still
        // useful here because they're not part of the displayed name.
        let workParts: [(String, String)] = [
            ("job title", contact.jobTitle),
            ("department", contact.departmentName),
            ("organization", contact.organizationName),
            ("phonetic organization", contact.phoneticOrganizationName),
        ]
        for (label, value) in workParts where !value.isEmpty {
            rows.append(.text(label: label, value: value))
        }

        for item in contact.phoneNumbers {
            rows.append(.phone(label: localizedLabel(item.label), number: item.value))
        }
        for item in contact.emailAddresses {
            rows.append(.email(label: localizedLabel(item.label), address: item.value))
        }
        for item in contact.urlAddresses where SidecarKey.parseGuessWhoContactURL(item.value) == nil {
            rows.append(.url(label: localizedLabel(item.label), urlString: item.value))
        }

        for item in contact.postalAddresses {
            rows.append(.address(label: localizedLabel(item.label), address: item.value))
        }

        if let bday = contact.birthday {
            rows.append(.date(label: "birthday", components: bday, formatted: formatDateComponents(bday)))
        }
        if let nonGreg = contact.nonGregorianBirthday {
            rows.append(.date(label: "non-gregorian birthday", components: nonGreg, formatted: formatDateComponents(nonGreg)))
        }
        for item in contact.dates {
            rows.append(.date(label: localizedLabel(item.label), components: item.value, formatted: formatDateComponents(item.value)))
        }

        for item in contact.socialProfiles {
            rows.append(.text(label: socialProfileLabel(item), value: socialProfileValue(item.value)))
        }
        for item in contact.instantMessageAddresses {
            rows.append(.text(label: instantMessageLabel(item), value: item.value.username))
        }
        let lookup = repository.lookupByDisplayName()
        for item in contact.contactRelations {
            let key = item.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, let match = lookup[key], match.localID != contact.localID {
                rows.append(.contactLink(
                    label: localizedLabel(item.label),
                    displayName: match.displayName,
                    localID: match.localID
                ))
            } else {
                rows.append(.text(label: localizedLabel(item.label), value: item.value.name))
            }
        }

        return rows
    }

    #if DEBUG
    @ViewBuilder
    private func debugSection(_ contact: Contact) -> some View {
        let rows = debugRows(for: contact)
        Section("Debug") {
            ForEach(rows) { row in
                InfoRow(data: row)
            }
        }
    }

    private func debugRows(for contact: Contact) -> [InfoRowData] {
        var rows: [InfoRowData] = []

        rows.append(.text(label: "localID", value: contact.localID, monospaced: true))
        rows.append(.text(label: "contact type", value: contact.contactType.rawValue))
        rows.append(.text(label: "image available", value: contact.imageDataAvailable ? "yes" : "no"))

        if let uuid = service.guessWhoUUID(in: contact) {
            rows.append(.text(label: "guesswho uuid", value: uuid, monospaced: true))
        } else if let reason = sidecarUnavailableReason {
            rows.append(.text(label: "guesswho uuid", value: "none — \(reason)"))
        } else {
            rows.append(.text(label: "guesswho uuid", value: "none"))
        }

        for item in contact.urlAddresses where item.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix) {
            rows.append(.text(label: "guesswho url (\(localizedLabel(item.label)))", value: item.value, monospaced: true))
        }

        if let outcome = reconcileOutcome {
            rows.append(.text(label: "reconcile: assigned uuid", value: outcome.assignedUUID ?? "—", monospaced: outcome.assignedUUID != nil))
            rows.append(.text(
                label: "reconcile: merged loser uuids",
                value: outcome.mergedLoserUUIDs.isEmpty ? "—" : outcome.mergedLoserUUIDs.joined(separator: ", "),
                monospaced: !outcome.mergedLoserUUIDs.isEmpty
            ))
            rows.append(.text(
                label: "reconcile: removed malformed urls",
                value: outcome.removedMalformedURLs.isEmpty ? "—" : outcome.removedMalformedURLs.joined(separator: ", "),
                monospaced: !outcome.removedMalformedURLs.isEmpty
            ))
            rows.append(.text(
                label: "reconcile: rewritten link ids",
                value: outcome.rewrittenLinkIDs.isEmpty ? "—" : outcome.rewrittenLinkIDs.map(\.uuidString).joined(separator: ", "),
                monospaced: !outcome.rewrittenLinkIDs.isEmpty
            ))
            for err in outcome.errors {
                rows.append(.text(label: "reconcile error", value: err, valueColor: .red))
            }
        } else if let error = reconcileError {
            rows.append(.text(label: "reconcile error", value: error, valueColor: .red))
        } else {
            rows.append(.text(label: "reconcile", value: "running…"))
        }

        if let sidecar {
            rows.append(.text(label: "sidecar: entity id", value: sidecar.entityID, monospaced: true))
            rows.append(.text(label: "sidecar: schema version", value: String(sidecar.schemaVersion)))
            rows.append(.text(label: "sidecar: cells dropped on decode", value: String(sidecar.cellsDroppedOnDecode)))
            if sidecar.fields.isEmpty {
                rows.append(.text(label: "sidecar fields", value: "(none)"))
            } else {
                for name in sidecar.fields.keys.sorted() {
                    rows.append(.text(label: "sidecar: \(name)", value: cellDescription(sidecar.fields[name]), monospaced: true))
                }
            }
        } else {
            rows.append(.text(label: "sidecar", value: "(none)"))
        }

        return rows
    }
    #endif

    // MARK: - Loading & reconcile

    private var sidecarUnavailableReason: String? {
        if case .unavailable(let reason) = service.sidecarLocation { return reason }
        return nil
    }

    private var isSidecarStorageUnavailable: Bool {
        if case .unavailable = service.sidecarLocation { return true }
        return false
    }

    private func loadContact() async {
        let loaded = service.fetchAll().first { $0.localID == localID }
        contact = loaded
        if let loaded {
            sidecar = service.sidecar(for: loaded)
            let uuid = service.guessWhoUUID(in: loaded)
            if let uuid {
                // Rebuild the store if the contact's GuessWho UUID changed
                // since last load — a Case D reconcile picks a winner UUID
                // and deletes the loser's sidecar, so a store still bound
                // to the loser would read/write a dead file.
                if notesStore?.contactUUID != uuid {
                    notesStore = NotesStore(service: service, contactUUID: uuid)
                } else {
                    notesStore?.reload()
                }
            } else {
                notesStore = nil
            }
        }
    }

    private func performReconcile() async {
        guard !isSidecarStorageUnavailable else {
            reconcileError = sidecarUnavailableReason ?? "Sidecar storage unavailable"
            return
        }
        do {
            let result = try service.reconcile(localID: localID)
            reconcileOutcome = result
            reconcileError = nil
            await loadContact()
        } catch {
            reconcileError = "\(error)"
        }
    }

    // MARK: - Notes

    private func beginEdit(_ note: ContactNote) {
        // Tapping a different row mid-edit commits the prior one first.
        if let editingID, editingID != note.id {
            commitRowEditIfChanged()
        }
        editingID = note.id
        draftBody = note.body
        editStartSnapshot = note.body
        noteFocus = .row(note.id)
    }

    private func deleteNote(_ id: UUID) {
        if editingID == id {
            editingID = nil
            draftBody = ""
            editStartSnapshot = ""
            if case .row(let focused) = noteFocus, focused == id {
                noteFocus = nil
            }
        }
        notesStore?.deleteNote(id)
    }

    private func commitActiveEdit() {
        switch noteFocus {
        case .newNote:
            commitNewNote()
        case .row:
            commitRowEditIfChanged()
        case .none:
            break
        }
        noteFocus = nil
    }

    private func commitNewNote() {
        let body = newNoteText
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let notesStore else { return }
        notesStore.addNote(body: body)
        newNoteText = ""
    }

    private func commitRowEditIfChanged() {
        guard let id = editingID else { return }
        let proposed = draftBody
        let snapshot = editStartSnapshot
        editingID = nil
        draftBody = ""
        editStartSnapshot = ""
        if proposed == snapshot { return }
        notesStore?.editNote(id, newBody: proposed)
    }

    // MARK: - Formatting

    private func localizedLabel(_ raw: String) -> String {
        if raw.isEmpty { return "other" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    private func formatDateComponents(_ components: DateComponents) -> String {
        if let date = Calendar(identifier: .gregorian).date(from: components) {
            let style = Date.FormatStyle()
                .year(.defaultDigits)
                .month(.abbreviated)
                .day(.defaultDigits)
            return date.formatted(style)
        }
        var parts: [String] = []
        if let y = components.year { parts.append(String(y)) }
        if let m = components.month { parts.append(String(format: "%02d", m)) }
        if let d = components.day { parts.append(String(format: "%02d", d)) }
        return parts.isEmpty ? "—" : parts.joined(separator: "-")
    }

    private func socialProfileLabel(_ labeled: LabeledSocialProfile) -> String {
        // The CN-provided per-profile label is usually empty; the service
        // (twitter, linkedin, …) is the meaningful identifier here.
        let service = labeled.value.service
        if !labeled.label.isEmpty {
            return localizedLabel(labeled.label)
        }
        if !service.isEmpty {
            return service
        }
        return "social"
    }

    private func socialProfileValue(_ profile: SocialProfile) -> String {
        if !profile.username.isEmpty { return profile.username }
        if !profile.urlString.isEmpty { return profile.urlString }
        if !profile.userIdentifier.isEmpty { return profile.userIdentifier }
        return "—"
    }

    private func instantMessageLabel(_ labeled: LabeledInstantMessageAddress) -> String {
        let service = labeled.value.service
        if !labeled.label.isEmpty {
            return localizedLabel(labeled.label)
        }
        if !service.isEmpty {
            return service
        }
        return "im"
    }

    private func cellDescription(_ cell: SidecarCell?) -> String {
        guard let cell else { return "—" }
        if cell.deletedAt != nil { return "(deleted)" }
        return jsonValueDescription(cell.value)
    }

    private func jsonValueDescription(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return String(n)
        case .string(let s): return s
        case .array, .object:
            if let data = try? JSONEncoder().encode(value),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "(complex)"
        }
    }
}

private struct InfoRowData: Identifiable {
    enum Kind {
        case text(value: String, monospaced: Bool, valueColor: Color?)
        case phone(number: String)
        case email(address: String)
        case url(urlString: String)
        case address(PostalAddress)
        case date(components: DateComponents, formatted: String)
        case contactLink(displayName: String, localID: String)
    }

    let id = UUID()
    let label: String
    let kind: Kind

    static func text(label: String, value: String, monospaced: Bool = false, valueColor: Color? = nil) -> InfoRowData {
        InfoRowData(label: label, kind: .text(value: value, monospaced: monospaced, valueColor: valueColor))
    }
    static func phone(label: String, number: String) -> InfoRowData {
        InfoRowData(label: label, kind: .phone(number: number))
    }
    static func email(label: String, address: String) -> InfoRowData {
        InfoRowData(label: label, kind: .email(address: address))
    }
    static func url(label: String, urlString: String) -> InfoRowData {
        InfoRowData(label: label, kind: .url(urlString: urlString))
    }
    static func address(label: String, address: PostalAddress) -> InfoRowData {
        InfoRowData(label: label, kind: .address(address))
    }
    static func date(label: String, components: DateComponents, formatted: String) -> InfoRowData {
        InfoRowData(label: label, kind: .date(components: components, formatted: formatted))
    }
    static func contactLink(label: String, displayName: String, localID: String) -> InfoRowData {
        InfoRowData(label: label, kind: .contactLink(displayName: displayName, localID: localID))
    }
}

private struct InfoRow: View {
    let data: InfoRowData

    var body: some View {
        switch data.kind {
        case .text(let value, let monospaced, let valueColor):
            labeledValue(label: data.label, value: value, monospaced: monospaced, valueColor: valueColor)
        case .phone(let number):
            tappableRow(label: data.label, value: number, url: phoneURL(number))
        case .email(let address):
            tappableRow(label: data.label, value: address, url: URL(string: "mailto:\(address)"))
        case .url(let urlString):
            tappableRow(label: data.label, value: urlString, url: URL(string: urlString))
        case .address(let address):
            AddressRow(label: data.label, address: address)
        case .date(let components, let formatted):
            tappableRow(label: data.label, value: formatted, url: calendarURL(for: components))
        case .contactLink(let displayName, let localID):
            contactLinkRow(label: data.label, displayName: displayName, localID: localID)
        }
    }

    @ViewBuilder
    private func contactLinkRow(label: String, displayName: String, localID: String) -> some View {
        // Match the tappable-row visual: label above, tinted value, whole
        // row tappable. NavigationLink(value:) feeds the existing
        // .navigationDestination(for: String.self) chain.
        NavigationLink(value: localID) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func labeledValue(label: String, value: String, monospaced: Bool, valueColor: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .body)
                .foregroundStyle(valueColor ?? .primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func tappableRow(label: String, value: String, url: URL?) -> some View {
        if let url {
            // Apple's Contacts colors the value in tint and the whole row
            // is the hit target — Link wrapping the VStack does both.
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        } else {
            labeledValue(label: label, value: value, monospaced: false, valueColor: nil)
        }
    }

    private func phoneURL(_ raw: String) -> URL? {
        // tel: requires digits only (plus '+'); strip everything else.
        let allowed = Set("+0123456789")
        let cleaned = raw.filter { allowed.contains($0) }
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "tel:\(cleaned)")
    }

    private func calendarURL(for components: DateComponents) -> URL? {
        // Calendar's calshow: scheme takes seconds since 2001-01-01.
        // Birthdays often lack a year; in that case land Calendar on
        // this year's occurrence so the user sees the next/most recent
        // one rather than year 1.
        var resolved = components
        if resolved.year == nil {
            resolved.year = Calendar(identifier: .gregorian).component(.year, from: Date())
        }
        if resolved.hour == nil { resolved.hour = 12 }
        if resolved.minute == nil { resolved.minute = 0 }
        guard let date = Calendar(identifier: .gregorian).date(from: resolved) else {
            return URL(string: "calshow:")
        }
        return URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))")
    }
}

private struct AddressRow: View {
    let label: String
    let address: PostalAddress

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var didStartGeocode = false

    var body: some View {
        Button {
            openInMaps()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatted)
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                mapPreview
            }
        }
        .buttonStyle(.plain)
        .task {
            guard !didStartGeocode else { return }
            didStartGeocode = true
            await geocode()
        }
    }

    @ViewBuilder
    private var mapPreview: some View {
        if let coordinate {
            // Static, non-interactive preview — taps fall through to the
            // surrounding Button so the whole row opens Maps as one unit.
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Marker("", coordinate: coordinate)
                    .tint(.red)
            }
            .allowsHitTesting(false)
            .frame(width: 96, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            // Reserve the same footprint so the row doesn't reflow when
            // the geocode resolves.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 96, height: 72)
        }
    }

    private var formatted: String {
        let cn = mutablePostalAddress()
        return CNPostalAddressFormatter.string(from: cn, style: .mailingAddress)
    }

    private func mutablePostalAddress() -> CNMutablePostalAddress {
        let cn = CNMutablePostalAddress()
        cn.street = address.street
        cn.subLocality = address.subLocality
        cn.city = address.city
        cn.subAdministrativeArea = address.subAdministrativeArea
        cn.state = address.state
        cn.postalCode = address.postalCode
        cn.country = address.country
        cn.isoCountryCode = address.isoCountryCode
        return cn
    }

    private func geocode() async {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodePostalAddress(mutablePostalAddress())
            await MainActor.run {
                self.coordinate = placemarks.first?.location?.coordinate
            }
        } catch {
            // Leave the placeholder; the row still functions, tap still
            // launches Maps which will do its own resolution.
        }
    }

    private func openInMaps() {
        let placemark: MKPlacemark
        if let coordinate {
            placemark = MKPlacemark(coordinate: coordinate, postalAddress: mutablePostalAddress())
        } else {
            // Maps accepts a placemark with no coordinate and resolves
            // it from the address fields.
            placemark = MKPlacemark(coordinate: kCLLocationCoordinate2DInvalid, postalAddress: mutablePostalAddress())
        }
        let item = MKMapItem(placemark: placemark)
        item.name = formatted
        item.openInMaps(launchOptions: nil)
    }
}

private struct NotesSection: View {
    let store: NotesStore
    @Binding var newNoteText: String
    @Binding var editingID: UUID?
    @Binding var draftBody: String
    var noteFocus: FocusState<ContactDetailView.NoteFocus?>.Binding
    let beginEdit: (ContactNote) -> Void
    let deleteNote: (UUID) -> Void

    var body: some View {
        Section("Notes") {
            ForEach(store.notes, id: \.id) { note in
                row(for: note)
            }
            .onDelete { offsets in
                let ids = offsets.map { store.notes[$0].id }
                for id in ids { deleteNote(id) }
            }

            // TextField with axis: .vertical inherits the cell's default
            // font + leading inset, so the editor lines up with the read
            // rows above. TextEditor draws its own inset and looked
            // shifted right.
            TextField("Add a note", text: $newNoteText, axis: .vertical)
                .focused(noteFocus, equals: .newNote)
        }
    }

    @ViewBuilder
    private func row(for note: ContactNote) -> some View {
        if editingID == note.id {
            TextField("", text: $draftBody, axis: .vertical)
                .focused(noteFocus, equals: .row(note.id))
        } else {
            // Wrap in a Button so the whole row — including the empty
            // trailing space of the Form cell — is the hit target.
            // .plain keeps the visual styling intact; without it the row
            // would adopt button tint colors.
            Button {
                beginEdit(note)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.body)
                    HStack(spacing: 6) {
                        Text(note.createdAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if note.modifiedAt > note.createdAt {
                            Text("edited")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Delete", role: .destructive) {
                    deleteNote(note.id)
                }
            }
        }
    }
}
