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
   silently skipped on older OSes) and stamps `resolvedAt`. Failed lookups
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
in as resolution lands; tap opens Apple Maps via
`maps.apple.com/place?place-id=…` or coordinate fallback). Both shells
share these VCs; per the product principle there is no user-facing
"resolve"/"sidecar" vocabulary — unresolved rows just read "Loading place
details…".

## Known limitations

* A guide import is a one-shot snapshot; edits to the guide in Apple Maps
  after sharing are not tracked. The source link is kept on the guide
  (`sourceURL` cell) so a future re-import/refresh flow can reuse it.
* Place-ID resolution needs iOS 18 / macOS 15 (MapKit place-ID API).
  On older OSes place-ID entries stay as "Loading place details…" rows;
  address entries are unaffected.
* The protobuf schema is unofficial. The decoder rejects anything it can't
  parse cleanly (import fails with a plain alert) rather than guessing.
