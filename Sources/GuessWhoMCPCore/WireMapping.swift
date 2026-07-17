import Foundation
import GuessWhoSync
import GuessWhoMCPWire

/// Model → allowlisted-DTO mapping (plans/cli-mcp.md INV-3/INV-3b).
///
/// These are the ONLY functions that turn engine models into wire values.
/// Rules they enforce by construction:
///
/// * The Apple contact note is never read — no mapper touches
///   `Contact.note`. (The event mapper's `notes` is `Event.eventKitNotes`,
///   the calendar event's own notes text, which the plan explicitly
///   allows; do not "fix" that in either direction.)
/// * URL addresses source from `userVisibleURLAddresses` — the raw list
///   carries the internal identity URL.
/// * No raw UUID / local id / `modifiedBy` device id ever crosses: every
///   `id` field is a sealed handle minted by the caller.
/// * Tombstoned records are dropped defensively even where the source read
///   already filters.
///
/// All functions are pure and run OFF the main actor — the dispatcher does
/// its repository reads on MainActor, then maps here.
enum WireMapping {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        iso8601.string(from: date)
    }

    static func timestamp(_ date: Date?) -> String? {
        date.map { iso8601.string(from: $0) }
    }

    /// Calendar-date rendering for `DateComponents` (birthdays,
    /// anniversaries): "yyyy-MM-dd", or "--MM-dd" when the year is unknown.
    static func calendarDate(_ components: DateComponents) -> String? {
        guard let month = components.month, let day = components.day else { return nil }
        if let year = components.year {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }

    private static func blankToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func kind(_ contact: Contact) -> String {
        contact.contactType == .organization ? "organization" : "person"
    }

    // MARK: - Contacts

    static func summary(_ contact: Contact, handle: String) -> WireContactSummary {
        WireContactSummary(
            id: handle,
            kind: kind(contact),
            name: contact.displayName,
            organization: blankToNil(contact.organizationName),
            jobTitle: blankToNil(contact.jobTitle))
    }

    static func contact(_ contact: Contact, handle: String, isFavorite: Bool) -> WireContact {
        WireContact(
            id: handle,
            kind: kind(contact),
            name: contact.displayName,
            givenName: blankToNil(contact.givenName),
            familyName: blankToNil(contact.familyName),
            nickname: blankToNil(contact.nickname),
            organization: blankToNil(contact.organizationName),
            department: blankToNil(contact.departmentName),
            jobTitle: blankToNil(contact.jobTitle),
            phoneNumbers: contact.phoneNumbers.map(labeledValue),
            emailAddresses: contact.emailAddresses.map(labeledValue),
            postalAddresses: contact.postalAddresses.map(postalAddress),
            urlAddresses: contact.userVisibleURLAddresses.map(labeledValue),
            birthday: contact.birthday.flatMap(calendarDate),
            dates: contact.dates.compactMap(labeledDate),
            isFavorite: isFavorite)
    }

    private static func labeledValue(_ value: LabeledValue) -> WireLabeledValue {
        WireLabeledValue(label: blankToNil(value.label), value: value.value)
    }

    private static func labeledDate(_ date: LabeledDate) -> WireLabeledDate? {
        guard let rendered = calendarDate(date.value) else { return nil }
        return WireLabeledDate(label: blankToNil(date.label), date: rendered)
    }

    private static func postalAddress(_ address: LabeledPostalAddress) -> WirePostalAddress {
        WirePostalAddress(
            label: blankToNil(address.label),
            street: address.value.street,
            city: address.value.city,
            state: address.value.state,
            postalCode: address.value.postalCode,
            country: address.value.country)
    }

    // MARK: - GuessWho contact data

    static func note(_ note: ContactNote, handle: String) -> WireNote? {
        guard !note.isDeleted else { return nil }
        return WireNote(
            id: handle,
            body: note.body,
            createdAt: timestamp(note.createdAt),
            modifiedAt: timestamp(note.modifiedAt))
    }

    /// `nil` for attachment-typed fields (kept off the wire even if a
    /// caller bypasses the already-filtering source read) and tombstones.
    static func customField(_ field: SidecarField, handle: String) -> WireCustomField? {
        guard field.deletedAt == nil, field.type != .blob else { return nil }
        let value: String
        switch field.value {
        case .string(let string): value = string
        case .bool(let bool): value = bool ? "true" : "false"
        case .number(let number): value = String(number)
        case .null, .array, .object: return nil
        }
        return WireCustomField(
            id: handle,
            name: field.field,
            type: field.type.rawValue,
            value: value,
            modifiedAt: timestamp(field.modifiedAt))
    }

    static func linkedContact(
        link: Link, linkHandle: String, other: Contact, otherHandle: String
    ) -> WireLinkedContact? {
        guard link.deletedAt == nil else { return nil }
        return WireLinkedContact(
            id: linkHandle,
            kind: kind(other),
            contact: summary(other, handle: otherHandle),
            note: blankToNil(link.note),
            createdAt: timestamp(link.createdAt))
    }

    static func group(_ group: ContactGroup, handle: String) -> WireGroup {
        WireGroup(id: handle, name: group.name)
    }

    // MARK: - Events

    static func eventSummary(_ event: Event, handle: String) -> WireEventSummary {
        WireEventSummary(
            id: handle,
            title: event.title,
            startDate: timestamp(event.startDate),
            endDate: timestamp(event.endDate),
            isAllDay: event.isAllDay,
            location: event.location.flatMap(blankToNil),
            calendarName: event.calendarName.flatMap(blankToNil))
    }

    static func event(_ event: Event, handle: String) -> WireEvent {
        WireEvent(
            id: handle,
            title: event.title,
            startDate: timestamp(event.startDate),
            endDate: timestamp(event.endDate),
            isAllDay: event.isAllDay,
            location: event.location.flatMap(blankToNil),
            calendarName: event.calendarName.flatMap(blankToNil),
            notes: event.eventKitNotes.flatMap(blankToNil),
            attendees: event.attendees.map {
                WireEventAttendee(name: $0.name, email: $0.email.flatMap(blankToNil))
            })
    }

    static func tag(_ tag: EventTag, handle: String) -> WireTag? {
        guard tag.deletedAt == nil else { return nil }
        return WireTag(id: handle, text: tag.text, createdAt: timestamp(tag.createdAt))
    }

    // MARK: - Guides

    static func guide(_ guide: MapsGuide, handle: String) -> WireGuide {
        WireGuide(
            id: handle,
            name: guide.name,
            sourceURL: guide.sourceURL.flatMap(blankToNil),
            createdAt: timestamp(guide.createdAt))
    }

    static func place(_ place: MapsPlace, handle: String, guideHandle: String) -> WirePlace {
        WirePlace(
            id: handle,
            guideId: guideHandle,
            name: place.name,
            address: place.address.flatMap(blankToNil),
            latitude: place.latitude,
            longitude: place.longitude)
    }
}
