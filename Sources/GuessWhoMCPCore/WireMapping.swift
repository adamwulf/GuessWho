import Foundation
import GuessWhoSync
import GuessWhoMCPWire

/// Model → DTO mapping (plans/cli-mcp.md Revision 2: whole record minus
/// the focused exclusion set).
///
/// These are the ONLY functions that turn engine models into wire values.
/// Rules they enforce by construction:
///
/// * The Apple contact note is never read — no mapper touches
///   `Contact.note`. (The event mapper's `notes` is `Event.eventKitNotes`,
///   the calendar event's own notes text, which the plan explicitly
///   allows; do not "fix" that in either direction.)
/// * URL addresses source from `userVisibleURLAddresses` — the raw list
///   carries the internal identity URL, which never crosses in URL form.
/// * No Apple local identifier or `modifiedBy` device id ever crosses:
///   `id` fields carry the record's own durable id (see `WireRecordID`).
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

    static func summary(_ contact: Contact, id: String) -> WireContactSummary {
        WireContactSummary(
            id: id,
            kind: kind(contact),
            name: contact.displayName,
            organization: blankToNil(contact.organizationName),
            jobTitle: blankToNil(contact.jobTitle))
    }

    static func contact(_ contact: Contact, id: String, isFavorite: Bool) -> WireContact {
        WireContact(
            id: id,
            kind: kind(contact),
            name: contact.displayName,
            namePrefix: blankToNil(contact.namePrefix),
            givenName: blankToNil(contact.givenName),
            middleName: blankToNil(contact.middleName),
            familyName: blankToNil(contact.familyName),
            previousFamilyName: blankToNil(contact.previousFamilyName),
            nameSuffix: blankToNil(contact.nameSuffix),
            nickname: blankToNil(contact.nickname),
            phoneticGivenName: blankToNil(contact.phoneticGivenName),
            phoneticMiddleName: blankToNil(contact.phoneticMiddleName),
            phoneticFamilyName: blankToNil(contact.phoneticFamilyName),
            organization: blankToNil(contact.organizationName),
            phoneticOrganization: blankToNil(contact.phoneticOrganizationName),
            department: blankToNil(contact.departmentName),
            jobTitle: blankToNil(contact.jobTitle),
            phoneNumbers: contact.phoneNumbers.map(labeledValue),
            emailAddresses: contact.emailAddresses.map(labeledValue),
            postalAddresses: contact.postalAddresses.map(postalAddress),
            urlAddresses: contact.userVisibleURLAddresses.map(labeledValue),
            birthday: contact.birthday.flatMap(calendarDate),
            dates: contact.dates.compactMap(labeledDate),
            socialProfiles: contact.socialProfiles.map(socialProfile),
            instantMessages: contact.instantMessageAddresses.map(instantMessage),
            relatedNames: contact.contactRelations.map { relation in
                WireLabeledValue(label: blankToNil(relation.label), value: relation.value.name)
            },
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
            subLocality: blankToNil(address.value.subLocality),
            city: address.value.city,
            subAdministrativeArea: blankToNil(address.value.subAdministrativeArea),
            state: address.value.state,
            postalCode: address.value.postalCode,
            country: address.value.country,
            isoCountryCode: blankToNil(address.value.isoCountryCode))
    }

    private static func socialProfile(_ profile: LabeledSocialProfile) -> WireSocialProfile {
        WireSocialProfile(
            label: blankToNil(profile.label),
            service: blankToNil(profile.value.service),
            username: blankToNil(profile.value.username),
            url: blankToNil(profile.value.urlString))
    }

    private static func instantMessage(_ address: LabeledInstantMessageAddress) -> WireInstantMessage {
        WireInstantMessage(
            label: blankToNil(address.label),
            service: blankToNil(address.value.service),
            username: address.value.username)
    }

    // MARK: - GuessWho contact data

    static func note(_ note: ContactNote, id: String) -> WireNote? {
        guard !note.isDeleted else { return nil }
        return WireNote(
            id: id,
            body: note.body,
            createdAt: timestamp(note.createdAt),
            modifiedAt: timestamp(note.modifiedAt))
    }

    /// `nil` for attachment-typed fields (kept off the wire even if a
    /// caller bypasses the already-filtering source read) and tombstones.
    static func customField(_ field: SidecarField, id: String) -> WireCustomField? {
        guard field.deletedAt == nil, field.type != .blob else { return nil }
        let value: String
        switch field.value {
        case .string(let string): value = string
        case .bool(let bool): value = bool ? "true" : "false"
        case .number(let number): value = String(number)
        case .null, .array, .object: return nil
        }
        return WireCustomField(
            id: id,
            name: field.field,
            type: field.type.rawValue,
            value: value,
            modifiedAt: timestamp(field.modifiedAt))
    }

    static func linkedContact(
        link: Link, linkID: String, other: Contact, otherID: String
    ) -> WireLinkedContact? {
        guard link.deletedAt == nil else { return nil }
        return WireLinkedContact(
            id: linkID,
            kind: kind(other),
            contact: summary(other, id: otherID),
            note: blankToNil(link.note),
            createdAt: timestamp(link.createdAt))
    }

    static func group(_ group: ContactGroup, id: String) -> WireGroup {
        WireGroup(id: id, name: group.name)
    }

    // MARK: - Events

    static func eventSummary(_ event: Event, id: String) -> WireEventSummary {
        WireEventSummary(
            id: id,
            title: event.title,
            startDate: timestamp(event.startDate),
            endDate: timestamp(event.endDate),
            isAllDay: event.isAllDay,
            location: event.location.flatMap(blankToNil),
            calendarName: event.calendarName.flatMap(blankToNil))
    }

    static func event(_ event: Event, id: String) -> WireEvent {
        WireEvent(
            id: id,
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

    static func tag(_ tag: EventTag, id: String) -> WireTag? {
        guard tag.deletedAt == nil else { return nil }
        return WireTag(id: id, text: tag.text, createdAt: timestamp(tag.createdAt))
    }

    // MARK: - Guides

    static func guide(_ guide: MapsGuide, id: String) -> WireGuide {
        WireGuide(
            id: id,
            name: guide.name,
            sourceURL: guide.sourceURL.flatMap(blankToNil),
            createdAt: timestamp(guide.createdAt))
    }

    static func place(_ place: MapsPlace, id: String, guideID: String) -> WirePlace {
        WirePlace(
            id: id,
            guideId: guideID,
            name: place.name,
            address: place.address.flatMap(blankToNil),
            latitude: place.latitude,
            longitude: place.longitude)
    }
}
