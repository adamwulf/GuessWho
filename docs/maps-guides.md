# Apple Maps guides: share-link import and the Guides tab

GuessWho can import a shared Apple Maps guide (a user-curated list of
places) from its share link and list it under the **Guides** section (a
sidebar row on Catalyst, a bottom tab on iPhone). Each guide lists its
places; tapping a place opens it in Apple Maps.

## The share-link format (reverse-engineered, verified 2026-07)

Sharing a guide from Apple Maps produces a short link:

```
https://maps.apple/ug/<token>
```

That URL 301-redirects to the expanded web form:

```
https://maps.apple.com/guides?user=<base64>
```

**The `user` parameter IS the guide.** It is a base64-encoded binary
protobuf carrying the guide's name and one entry per saved place — the
rendered web page is just a viewer over it, so the import never scrapes
HTML. Observed schema (field numbers from real payloads):

```
message Guide {
  string name = 1;              // e.g. "Berlin"
  repeated Entry entries = 2;   // in the guide's display order
}
message Entry {
  uint64 unknown = 1;           // constant observed as 9902
  uint64 muid = 2;              // Apple Maps place id (place-of-business entries)
  string address = 3;           // address entries only
  Coordinate coordinate = 4;    // address entries only
}
message Coordinate {
  double latitude = 1;
  double longitude = 2;
}
```

Two entry shapes exist:

* **Place-ID entries** (a saved business/POI): only the 64-bit `muid`.
  `"I" + uppercase-hex(muid)` (no zero padding) is exactly the raw value of
  MapKit's `MKMapItem.Identifier` — e.g. muid `15031693076549454298` →
  `ID09B4D36386DC9DA`, matching the `place-id=` anchors on the rendered
  guide page.
* **Address entries** (a saved plain address): the address string and
  coordinate travel inline; there is no place id and nothing to resolve.

## Import pipeline

1. **Decode** — `MapsGuideURL` (GuessWhoSync) recognizes both URL forms,
   follows the short link's redirect *without* downloading the page body
   (`fetchSnapshot(from:)` stops at the 301 and reads `Location`), and
   decodes the `user` payload with a minimal protobuf reader. Pure decode
   paths are unit-tested against a real Berlin guide payload
   (`MapsGuideURLTests`).
2. **Store** — `GuessWhoSync.createGuide(from:sourceURL:)` mints a guide
   sidecar (`guides/<uuid>.json`, kind `.guide`) plus one place sidecar per
   entry (`places/<uuid>.json`, kind `.place`). Places carry a `guideID`
   cell pointing at their guide and an `orderCache` cell preserving the
   shared order. Same envelope/cell format as events; syncs through the
   same iCloud root.
3. **Resolve** — `GuidePlaceResolver` (app target) turns each place-ID
   entry into name/address/coordinate via the public
   `MKMapItemRequest(mapItemIdentifier:)` API (iOS 18+/macCatalyst 18+;
   silently skipped on older OSes) and stamps `resolvedAt`. The pass is
   **serial and rate-limited** — one lookup at a time, spaced
   `requestInterval` apart (0.2s), escalating to a 1s+ backoff-and-retry when
   MapKit returns `MKError.loadingThrottled` — so a large guide (100+ places)
   doesn't burst past MapKit's place-ID rate limit. It reloads the repository
   after each success, so rows fill in one at a time rather than all at the
   end, and publishes the place it is currently looking up
   (`resolvingPlaceID` + `.guideResolutionActivePlaceDidChange`) so the list
   shows a per-row spinner / "waiting" state. A per-guide in-flight guard
   coalesces the import-path pass and the list's on-open retry so they never
   run duplicate passes (which would double the request rate). Failed lookups
   stay unresolved and retry the next time the guide opens.

## Entry points

* **Share sheet (iOS)** — the `GuessWhoShare` extension recognizes a
  `maps.apple` guide link and bounces it into the app via the wake scheme:
  `guesswho-linkedin[-debug]://import-guide?url=<share link>`. The scene
  delegate (`handleGuideImportWake`) runs the import and lands the UI on
  the new guide. (Same bounce-only philosophy as the LinkedIn share flow —
  the extension parses and stores nothing.)
* **"+" on the Guides list (both platforms)** — paste the share link into
  a small alert; pre-filled from the pasteboard when it already holds a
  guide link.

## UI shape

`GuidesListViewController` (guides, newest import first, place counts) →
push → `GuidePlacesListViewController` (places in shared order; rows fill
in one at a time as resolution lands, each row showing a spinner while it is
being looked up, "Waiting to load…" while queued behind others, and its
name/address once done) → push → `GuidePlaceDetailView` (the place detail,
below). Both shells share the two list VCs; per the product principle there
is no user-facing "resolve"/"sidecar" vocabulary — the plain-language row
states above stand in for it.

## Place detail and association matching

Tapping a place row pushes `GuidePlaceDetailView` (App target, SwiftUI),
hosted the same way as `ContactDetailView` / `EventDetailView`. It shows the
place's name, address, and coordinate with an **Open in Maps** button (the
`maps.apple.com/place?place-id=…` / coordinate-fallback deep link that used
to fire on row tap now lives on this button), plus three best-effort
"who/what is here" sections derived from the place's address:

* **Recent Events** — calendar events whose free-text location contains the
  place's street line, via `SyncService.recentEvents(forEmails:addresses:)`
  with an empty email set and the place's street line as the location needle.
* **Contacts** / **Organizations** — records whose structured postal street
  line appears inside the place's address, partitioned by `ContactType`.

All three reuse the **street-line token matcher** (`EventLocationMatcher`,
GuessWhoSync) that already backs the contact detail's "Recent Events"
section: a needle must appear as a contiguous run of ≥2 words inside the
haystack, so a shared city/state alone never sweeps in unrelated records.
The place's street-line needle is derived from its formatted `address`
(MapKit's `placemark.title`) with `PostalAddress.parse(fromFullAddress:)`,
falling back to the first comma-delimited segment.

**Matching keys off the resolved `address`.** For place-ID entries that is
only populated after the MapKit resolution pass, so an unresolved place
matches nothing — the association sections stay empty until its row fills in.
Address entries (inline address + coordinate) match immediately.

## Latitude/longitude: options and caveats

Matching is street-line-based today. Coordinate-based matching was
considered and deferred; this records why and what it would take.

**What coordinate data we actually have, and when:**

* **Address entries** carry a coordinate (and address) inline in the payload
  — available at import, no resolution needed.
* **Place-ID entries** have **no coordinate until the MapKit resolution pass
  stamps `latitude`/`longitude`** — the *same* pass that fills `address`. So
  before resolution a place-ID entry has neither a street line nor a
  coordinate; lat/long is not a way around an unresolved place.
* Contacts/organizations store **postal addresses only — no coordinates.**
  Any geo match needs their addresses geocoded first.

**Options for using lat/long, each with its caveat:**

1. **Geo-radius contact/org match** — geocode each contact's postal address
   to a coordinate (`CLGeocoder`) and match those within *N* meters of the
   place. Caveats: `CLGeocoder` is online-only and aggressively rate-limited
   (throttles within a small burst), asynchronous, and its results must be
   cached/sidecar-stored to avoid re-geocoding the whole address book on
   every place open — i.e. a new geocode+storage subsystem. Radius choice
   trades recall against false matches (a building's pin and a contact's
   mailing address for the same site can differ by tens of meters), and exact
   coordinate equality is meaningless for floating-point lat/long.
2. **Event proximity** — EventKit events rarely carry a coordinate
   (`structuredLocation.geoLocation` is usually nil; the location is free
   text), so geo-matching events is low-recall. Street-text matching is the
   pragmatic path and is what we do.
3. **Reverse-geocode the place coordinate to a street, then street-match** —
   redundant, since resolution already returns a formatted address; only
   marginally useful for address entries that lack a street breakdown.

**Decision:** street-line matching now — no new dependencies, no geocoding
quota, deterministic, and it works from the data resolution already gives us.
If coordinate matching is pursued later, gate it on a cached
contact-geocode store (option 1) rather than geocoding live per place.

## Known limitations

* A guide import is a one-shot snapshot; edits to the guide in Apple Maps
  after sharing are not tracked. The source link is kept on the guide
  (`sourceURL` cell) so a future re-import/refresh flow can reuse it.
* Place-ID resolution needs iOS 18 / macOS 15 (MapKit place-ID API).
  On older OSes place-ID entries stay as "Loading place details…" rows;
  address entries are unaffected.
* **Large guides resolve slowly (by design).** Resolution is serial and
  rate-limited (see Import pipeline step 3), so a 150-place guide takes a few
  minutes to fully fill in — but it does so live, one row at a time, and
  survives navigating away (the pass is not tied to the list controller's
  lifecycle). MapKit throttling is handled with backoff-and-retry rather than
  swallowed; a place that still fails after its retries stays pending and is
  retried the next time the guide opens. Note that street/lat-long matching on
  the place detail keys off the *resolved* fields, so a place's association
  sections stay empty until its row resolves. Remaining sharp edge: there is
  no per-request timeout, so a single hung `MKMapItemRequest` can stall the
  rest of that pass until the next guide open re-kicks it.
* The protobuf schema is unofficial. The decoder rejects anything it can't
  parse cleanly (import fails with a plain alert) rather than guessing.
