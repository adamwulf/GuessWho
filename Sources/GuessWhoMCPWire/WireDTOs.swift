import Foundation

/// Allowlist-only wire DTOs (plans/cli-mcp.md INV-3b).
///
/// Every type here is a POSITIVE FIELD ALLOWLIST: it names exactly the
/// fields that may cross the wire, and the mappers in GuessWhoMCPCore can
/// only populate what is named. Fields that must NEVER appear (asserted by
/// the golden-DTO tests):
///
///   * the Apple contact note (INV-3 — the DTO simply has no such field)
///   * `modifiedBy` / any per-install device UUID
///   * any raw GuessWho UUID, Apple local identifier, or storage key id
///   * the `guesswho://` identity URL (URL addresses are sourced from
///     `userVisibleURLAddresses` only)
///
/// `id` fields carry SEALED, per-app-run random reference tokens minted by
/// the host (see `GuessWhoMCPCore.HandleRegistry`) — never a persistent or
/// meaningful identifier. Date fields are pre-formatted ISO 8601 strings so
/// wire encoding never depends on an encoder date strategy.
///
/// Keep additions here deliberate: adding a field to a DTO is a security
/// review event, not a convenience edit.

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

/// A labeled postal address, pre-formatted for display.
public struct WirePostalAddress: Codable, Sendable, Equatable {
    public let label: String?
    public let street: String
    public let city: String
    public let state: String
    public let postalCode: String
    public let country: String

    public init(label: String?, street: String, city: String, state: String, postalCode: String, country: String) {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
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

/// Full contact card for contacts_get.
public struct WireContact: Codable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let givenName: String?
    public let familyName: String?
    public let nickname: String?
    public let organization: String?
    public let department: String?
    public let jobTitle: String?
    public let phoneNumbers: [WireLabeledValue]
    public let emailAddresses: [WireLabeledValue]
    public let postalAddresses: [WirePostalAddress]
    /// Sourced from user-visible web addresses ONLY (INV-3b).
    public let urlAddresses: [WireLabeledValue]
    public let birthday: String?
    public let dates: [WireLabeledDate]
    public let isFavorite: Bool

    public init(
        id: String, kind: String, name: String,
        givenName: String?, familyName: String?, nickname: String?,
        organization: String?, department: String?, jobTitle: String?,
        phoneNumbers: [WireLabeledValue], emailAddresses: [WireLabeledValue],
        postalAddresses: [WirePostalAddress], urlAddresses: [WireLabeledValue],
        birthday: String?, dates: [WireLabeledDate], isFavorite: Bool
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.department = department
        self.jobTitle = jobTitle
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.postalAddresses = postalAddresses
        self.urlAddresses = urlAddresses
        self.birthday = birthday
        self.dates = dates
        self.isFavorite = isFavorite
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
/// and the far contact projected to the same sealed id scheme.
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
