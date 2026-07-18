import Foundation

/// Wire DTOs (plans/cli-mcp.md Revision 2: whole-record minus a FOCUSED
/// EXCLUSION set).
///
/// The wire carries the whole contact/event record the user sees, EXCEPT
/// four named fields that must NEVER appear in either direction (enforced
/// by the targeted sentinel tests in GuessWhoMCPCoreTests):
///
///   * the Apple contact note (INV-3 — no DTO has such a field, and no
///     write tool accepts one)
///   * `localID` / any Apple local identifier (group and event system ids
///     ride only as derived, one-way ids)
///   * `modifiedBy` / any per-install device UUID
///   * the `guesswho://` URL form (the GuessWho identity rides as the bare
///     UUID `id`; URL addresses source from `userVisibleURLAddresses`)
///
/// A contact's `id` IS its GuessWho UUID — durable, stable across runs —
/// or, for a contact that hasn't minted one yet, the deterministic UUID it
/// WILL mint (same value before and after the mint; see
/// `Contact.deterministicGuessWhoID`). The id is a lookup key only: no
/// write tool can change it. Other records' ids are their own record UUIDs
/// (notes, tags, links, guides, places) or derived ids (system-only
/// events, groups). Date fields are pre-formatted ISO 8601 strings so wire
/// encoding never depends on an encoder date strategy.
///
/// Keep additions here deliberate: adding a field to a DTO is a review
/// event — check it against the exclusion list above.

/// One page of a bounded list read. `nextCursor` non-nil means more items
/// exist; pass it back as the `cursor` parameter for the next page.
public struct WirePage<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A labeled scalar (phone number, email address, web address).
public struct WireLabeledValue: Codable, Sendable, Equatable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

/// A labeled date (anniversary, custom date). `date` is ISO 8601 (date-only
/// where the source has no time component).
public struct WireLabeledDate: Codable, Sendable, Equatable {
    public let label: String?
    public let date: String

    public init(label: String?, date: String) {
        self.label = label
        self.date = date
    }
}

/// A labeled postal address. Carries the FULL address field set the
/// system stores (not just the display subset) so an update that replaces
/// the address list round-trips every subfield instead of dropping the
/// ones a leaner DTO wouldn't name.
public struct WirePostalAddress: Codable, Sendable, Equatable {
    public let label: String?
    public let street: String
    public let subLocality: String?
    public let city: String
    public let subAdministrativeArea: String?
    public let state: String
    public let postalCode: String
    public let country: String
    public let isoCountryCode: String?

    public init(
        label: String?, street: String, subLocality: String? = nil,
        city: String, subAdministrativeArea: String? = nil, state: String,
        postalCode: String, country: String, isoCountryCode: String? = nil
    ) {
        self.label = label
        self.street = street
        self.subLocality = subLocality
        self.city = city
        self.subAdministrativeArea = subAdministrativeArea
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }
}

/// A social profile entry (service + username and/or profile URL).
public struct WireSocialProfile: Codable, Sendable, Equatable {
    public let label: String?
    public let service: String?
    public let username: String?
    public let url: String?

    public init(label: String?, service: String?, username: String?, url: String?) {
        self.label = label
        self.service = service
        self.username = username
        self.url = url
    }
}

/// An instant-message address (service + username).
public struct WireInstantMessage: Codable, Sendable, Equatable {
    public let label: String?
    public let service: String?
    public let username: String

    public init(label: String?, service: String?, username: String) {
        self.label = label
        self.service = service
        self.username = username
    }
}

/// Compact contact row for search results, favorites, group members, and
/// the far end of a linked contact/organization.
public struct WireContactSummary: Codable, Sendable {
    public let id: String
    /// "person" or "organization" — plain values, per the linked-contacts
    /// naming note in plans/cli-mcp.md.
    public let kind: String
    public let name: String
    public let organization: String?
    public let jobTitle: String?

    public init(id: String, kind: String, name: String, organization: String?, jobTitle: String?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.organization = organization
        self.jobTitle = jobTitle
    }
}

/// Full contact card for contacts_get and the create/update write echo —
/// the whole record the user's contact card shows, minus the exclusion
/// set (no Apple note, no local ids, no device id, no identity URL).
public struct WireContact: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let namePrefix: String?
    public let givenName: String?
    public let middleName: String?
    public let familyName: String?
    public let previousFamilyName: String?
    public let nameSuffix: String?
    public let nickname: String?
    public let phoneticGivenName: String?
    public let phoneticMiddleName: String?
    public let phoneticFamilyName: String?
    public let organization: String?
    public let phoneticOrganization: String?
    public let department: String?
    public let jobTitle: String?
    public let phoneNumbers: [WireLabeledValue]
    public let emailAddresses: [WireLabeledValue]
    public let postalAddresses: [WirePostalAddress]
    /// Sourced from user-visible web addresses ONLY (the identity URL form
    /// is excluded; the identity rides as `id`).
    public let urlAddresses: [WireLabeledValue]
    public let birthday: String?
    public let dates: [WireLabeledDate]
    public let socialProfiles: [WireSocialProfile]
    public let instantMessages: [WireInstantMessage]
    /// Name-only related people from the contact card (e.g. "mother",
    /// "manager" entries) — labels + plain names, NOT the same thing as
    /// Linked Contacts (which are real connections between records).
    public let relatedNames: [WireLabeledValue]
    public let isFavorite: Bool

    public init(
        id: String, kind: String, name: String,
        namePrefix: String?, givenName: String?, middleName: String?,
        familyName: String?, previousFamilyName: String?, nameSuffix: String?,
        nickname: String?,
        phoneticGivenName: String?, phoneticMiddleName: String?, phoneticFamilyName: String?,
        organization: String?, phoneticOrganization: String?,
        department: String?, jobTitle: String?,
        phoneNumbers: [WireLabeledValue], emailAddresses: [WireLabeledValue],
        postalAddresses: [WirePostalAddress], urlAddresses: [WireLabeledValue],
        birthday: String?, dates: [WireLabeledDate],
        socialProfiles: [WireSocialProfile], instantMessages: [WireInstantMessage],
        relatedNames: [WireLabeledValue], isFavorite: Bool
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.namePrefix = namePrefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.previousFamilyName = previousFamilyName
        self.nameSuffix = nameSuffix
        self.nickname = nickname
        self.phoneticGivenName = phoneticGivenName
        self.phoneticMiddleName = phoneticMiddleName
        self.phoneticFamilyName = phoneticFamilyName
        self.organization = organization
        self.phoneticOrganization = phoneticOrganization
        self.department = department
        self.jobTitle = jobTitle
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.postalAddresses = postalAddresses
        self.urlAddresses = urlAddresses
        self.birthday = birthday
        self.dates = dates
        self.socialProfiles = socialProfiles
        self.instantMessages = instantMessages
        self.relatedNames = relatedNames
        self.isFavorite = isFavorite
    }
}

/// INPUT-side field set for contacts_update — the SINGLE-VALUE contact
/// fields only, a PATCH: only the fields the caller supplied are applied.
/// `nil` = untouched; an empty string clears a text field (and clears
/// `birthday`).
///
/// Deliberately ABSENT — every multi-value list. A whole-list replacement
/// is how an assistant bulk-edits a card believing it edited one entry, so
/// list fields change ONE entry at a time through the dedicated
/// contacts_add_* / contacts_edit_* / contacts_remove_* tools; this struct
/// having no list members makes an update-side bulk edit structurally
/// impossible, the same way the missing note member keeps the Apple note
/// unwritable. The other update exclusions carry over: no note field, no
/// contact id, no `kind`.
public struct WireContactScalarFields: Codable, Sendable, Equatable {
    public var namePrefix: String?
    public var givenName: String?
    public var middleName: String?
    public var familyName: String?
    public var previousFamilyName: String?
    public var nameSuffix: String?
    public var nickname: String?
    public var phoneticGivenName: String?
    public var phoneticMiddleName: String?
    public var phoneticFamilyName: String?
    public var organization: String?
    public var phoneticOrganization: String?
    public var department: String?
    public var jobTitle: String?
    /// "yyyy-MM-dd", "--MM-dd" (no year), or "" to clear.
    public var birthday: String?

    public init() {}

    /// The names of the fields the caller supplied, for audit summaries.
    /// Host-side display only.
    public var providedFieldNames: [String] {
        var names: [String] = []
        func note(_ name: String, _ provided: Bool) {
            if provided { names.append(name) }
        }
        note("namePrefix", namePrefix != nil)
        note("givenName", givenName != nil)
        note("middleName", middleName != nil)
        note("familyName", familyName != nil)
        note("previousFamilyName", previousFamilyName != nil)
        note("nameSuffix", nameSuffix != nil)
        note("nickname", nickname != nil)
        note("phoneticGivenName", phoneticGivenName != nil)
        note("phoneticMiddleName", phoneticMiddleName != nil)
        note("phoneticFamilyName", phoneticFamilyName != nil)
        note("organization", organization != nil)
        note("phoneticOrganization", phoneticOrganization != nil)
        note("department", department != nil)
        note("jobTitle", jobTitle != nil)
        note("birthday", birthday != nil)
        return names
    }

    /// True when no field was supplied at all (an update with nothing to do).
    public var isEmpty: Bool {
        providedFieldNames.isEmpty
    }
}

/// INPUT-side field set for contacts_create — a PATCH over a blank card:
/// only the fields the caller supplied are applied. `nil` = untouched; an
/// empty string clears a text field; an empty array clears a list; the
/// empty string clears `birthday`.
///
/// Unlike contacts_update, create DOES accept the multi-value lists: a
/// brand-new card has no existing entries a whole-list write could
/// clobber, so one-shot initialization is safe (contacts_update is
/// scalars-only; list edits go through the single-entry tools).
///
/// Deliberately ABSENT (the write-direction exclusion set): any note
/// field (the Apple note is never writable here — GuessWho's own dated
/// notes are the supported notes surface) and the contact id (a lookup
/// key, never writable).
public struct WireContactFields: Codable, Sendable, Equatable {
    public var namePrefix: String?
    public var givenName: String?
    public var middleName: String?
    public var familyName: String?
    public var previousFamilyName: String?
    public var nameSuffix: String?
    public var nickname: String?
    public var phoneticGivenName: String?
    public var phoneticMiddleName: String?
    public var phoneticFamilyName: String?
    public var organization: String?
    public var phoneticOrganization: String?
    public var department: String?
    public var jobTitle: String?
    public var phoneNumbers: [WireLabeledValue]?
    public var emailAddresses: [WireLabeledValue]?
    public var postalAddresses: [WirePostalAddress]?
    public var urlAddresses: [WireLabeledValue]?
    /// "yyyy-MM-dd", "--MM-dd" (no year), or "" to clear.
    public var birthday: String?
    public var dates: [WireLabeledDate]?
    public var socialProfiles: [WireSocialProfile]?
    public var instantMessages: [WireInstantMessage]?
    public var relatedNames: [WireLabeledValue]?

    public init() {}

    /// The single-value subset, so create and update share one scalar
    /// apply path.
    public var scalarFields: WireContactScalarFields {
        var scalars = WireContactScalarFields()
        scalars.namePrefix = namePrefix
        scalars.givenName = givenName
        scalars.middleName = middleName
        scalars.familyName = familyName
        scalars.previousFamilyName = previousFamilyName
        scalars.nameSuffix = nameSuffix
        scalars.nickname = nickname
        scalars.phoneticGivenName = phoneticGivenName
        scalars.phoneticMiddleName = phoneticMiddleName
        scalars.phoneticFamilyName = phoneticFamilyName
        scalars.organization = organization
        scalars.phoneticOrganization = phoneticOrganization
        scalars.department = department
        scalars.jobTitle = jobTitle
        scalars.birthday = birthday
        return scalars
    }

    /// The names of the fields the caller supplied, for audit summaries
    /// ("Edited the contact — jobTitle, phoneNumbers"). Host-side display
    /// only.
    public var providedFieldNames: [String] {
        var names: [String] = []
        func note(_ name: String, _ provided: Bool) {
            if provided { names.append(name) }
        }
        note("namePrefix", namePrefix != nil)
        note("givenName", givenName != nil)
        note("middleName", middleName != nil)
        note("familyName", familyName != nil)
        note("previousFamilyName", previousFamilyName != nil)
        note("nameSuffix", nameSuffix != nil)
        note("nickname", nickname != nil)
        note("phoneticGivenName", phoneticGivenName != nil)
        note("phoneticMiddleName", phoneticMiddleName != nil)
        note("phoneticFamilyName", phoneticFamilyName != nil)
        note("organization", organization != nil)
        note("phoneticOrganization", phoneticOrganization != nil)
        note("department", department != nil)
        note("jobTitle", jobTitle != nil)
        note("phoneNumbers", phoneNumbers != nil)
        note("emailAddresses", emailAddresses != nil)
        note("postalAddresses", postalAddresses != nil)
        note("urlAddresses", urlAddresses != nil)
        note("birthday", birthday != nil)
        note("dates", dates != nil)
        note("socialProfiles", socialProfiles != nil)
        note("instantMessages", instantMessages != nil)
        note("relatedNames", relatedNames != nil)
        return names
    }

    /// True when no field was supplied at all (an update with nothing to do).
    public var isEmpty: Bool {
        namePrefix == nil && givenName == nil && middleName == nil
            && familyName == nil && previousFamilyName == nil && nameSuffix == nil
            && nickname == nil && phoneticGivenName == nil && phoneticMiddleName == nil
            && phoneticFamilyName == nil && organization == nil
            && phoneticOrganization == nil && department == nil && jobTitle == nil
            && phoneNumbers == nil && emailAddresses == nil && postalAddresses == nil
            && urlAddresses == nil && birthday == nil && dates == nil
            && socialProfiles == nil && instantMessages == nil && relatedNames == nil
    }
}

/// A dated note the user wrote about a contact (GuessWho's own notes — a
/// different thing from the Apple contact note, which never crosses).
public struct WireNote: Codable, Sendable {
    public let id: String
    public let body: String
    public let createdAt: String
    public let modifiedAt: String

    public init(id: String, body: String, createdAt: String, modifiedAt: String) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// A custom field on a contact. `value` is a string ("true"/"false" for
/// checkboxes, ISO 8601 for dates). Attachment-typed fields never cross.
public struct WireCustomField: Codable, Sendable {
    public let id: String
    public let name: String
    /// "note", "multilineNote", "date", or "checkbox".
    public let type: String
    public let value: String
    public let modifiedAt: String

    public init(id: String, name: String, type: String, value: String, modifiedAt: String) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
        self.modifiedAt = modifiedAt
    }
}

/// One Linked Contact / Linked Organization row: the connection, its note,
/// and the far contact carrying its own contact id.
public struct WireLinkedContact: Codable, Sendable {
    public let id: String
    /// "person" or "organization".
    public let kind: String
    public let contact: WireContactSummary
    public let note: String?
    public let createdAt: String

    public init(id: String, kind: String, contact: WireContactSummary, note: String?, createdAt: String) {
        self.id = id
        self.kind = kind
        self.contact = contact
        self.note = note
        self.createdAt = createdAt
    }
}

/// One generic connection row (links_list / links_create), seen from the
/// record it was listed on: `kind`/`otherId` describe the record at the
/// FAR end, readable with the matching read tool (contacts_get,
/// events_get, places_list). `id` is the connection's own id — the one
/// links_remove takes.
public struct WireLink: Codable, Sendable {
    public let id: String
    /// The other record's kind: "person", "organization", "event", or
    /// "place".
    public let kind: String
    /// The other record's id, in that kind's own id space.
    public let otherId: String
    public let note: String?
    public let createdAt: String

    public init(id: String, kind: String, otherId: String, note: String?, createdAt: String) {
        self.id = id
        self.kind = kind
        self.otherId = otherId
        self.note = note
        self.createdAt = createdAt
    }
}

/// A contact group.
public struct WireGroup: Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Compact event row for events_list.
public struct WireEventSummary: Codable, Sendable {
    public let id: String
    public let title: String
    public let startDate: String
    public let endDate: String
    public let isAllDay: Bool
    public let location: String?
    public let calendarName: String?

    public init(id: String, title: String, startDate: String, endDate: String, isAllDay: Bool, location: String?, calendarName: String?) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarName = calendarName
    }
}

/// Full event for events_get. `notes` is the event's own notes text as it
/// appears in the user's calendar — allowed on the wire (it is NOT the
/// Apple contact note; see plans/cli-mcp.md DTO field sourcing).
public struct WireEvent: Codable, Sendable {
    public let id: String
    public let title: String
    public let startDate: String
    public let endDate: String
    public let isAllDay: Bool
    public let location: String?
    public let calendarName: String?
    public let notes: String?
    public let attendees: [WireEventAttendee]

    public init(
        id: String, title: String, startDate: String, endDate: String,
        isAllDay: Bool, location: String?, calendarName: String?,
        notes: String?, attendees: [WireEventAttendee]
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarName = calendarName
        self.notes = notes
        self.attendees = attendees
    }
}

public struct WireEventAttendee: Codable, Sendable, Equatable {
    public let name: String
    public let email: String?

    public init(name: String, email: String?) {
        self.name = name
        self.email = email
    }
}

/// A tag the user put on an event.
public struct WireTag: Codable, Sendable {
    public let id: String
    public let text: String
    public let createdAt: String?

    public init(id: String, text: String, createdAt: String?) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// A saved place guide. `sourceURL` is the user-visible share link the
/// guide was imported from, when known.
public struct WireGuide: Codable, Sendable {
    public let id: String
    public let name: String
    public let sourceURL: String?
    public let createdAt: String?

    public init(id: String, name: String, sourceURL: String?, createdAt: String?) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.createdAt = createdAt
    }
}

/// INPUT-side place description for guides_create: the caller's initial
/// places, by address (+ optional coordinates). An input DTO — it rides
/// requests, never responses, so it carries no id.
public struct WireNewPlace: Codable, Sendable, Equatable {
    public let address: String
    public let latitude: Double?
    public let longitude: Double?

    public init(address: String, latitude: Double?, longitude: Double?) {
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A place in a guide.
public struct WirePlace: Codable, Sendable {
    public let id: String
    public let guideId: String
    public let name: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(id: String, guideId: String, name: String, address: String?, latitude: Double?, longitude: Double?) {
        self.id = id
        self.guideId = guideId
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }
}
