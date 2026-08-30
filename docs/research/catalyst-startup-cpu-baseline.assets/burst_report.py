#!/usr/bin/env python3
"""Per-2s-bucket CPU (ms) for selected marker functions, from a time-profile XML."""
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict, Counter

XML = sys.argv[1]

MARKERS = {
    'sidecar read': 'FileSystemSidecarStore.read(_:)',
    'ISO8601 parse': 'SidecarISO8601.date(from:)',
    'allPlaces': 'GuessWhoSync.allPlaces()',
    'reconcile': 'GuessWhoSync.reconcileSidecars()',
    'contacts fetchAll': 'CNContactStoreAdapter.fetchAll()',
    'ek attendees': 'EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)',
    'eventsWindow': 'GuessWhoSync.eventsWindow(from:to:includeEventKit:)',
    'linkCounts': 'GuessWhoSync.linkCounts(ofKind:)',
    'MapKit/VectorKit': None,  # binary match below
}

intern = {}

def parse_binary(el):
    if 'ref' in el.attrib:
        return intern[el.attrib['ref']]
    val = el.attrib.get('name', '?')
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

def parse_frame(el):
    if 'ref' in el.attrib:
        return intern[el.attrib['ref']]
    name = el.attrib.get('name') or el.attrib.get('addr', '?')
    binel = el.find('binary')
    binname = parse_binary(binel) if binel is not None else '?'
    val = (name, binname)
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

def parse_backtrace(el):
    if 'ref' in el.attrib:
        return intern[el.attrib['ref']]
    frames = [parse_frame(f) for f in el.findall('frame')]
    if 'id' in el.attrib:
        intern[el.attrib['id']] = frames
    return frames

def parse_simple(el):
    if 'ref' in el.attrib:
        return intern[el.attrib['ref']]
    if el.tag in ('sample-time', 'weight'):
        val = int(el.text)
    else:
        val = el.text or el.attrib.get('fmt', '?')
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

buckets = defaultdict(Counter)
BUCKET_NS = 2_000_000_000

for event, el in ET.iterparse(XML, events=('end',)):
    if el.tag != 'row':
        continue
    st = w = None
    bt = None
    for child in el:
        if child.tag == 'sample-time':
            st = parse_simple(child)
        elif child.tag == 'weight':
            w = parse_simple(child)
        elif child.tag == 'backtrace':
            bt = parse_backtrace(child)
        elif child.tag == 'thread':
            parse_simple(child)
        elif child.tag == 'thread-state':
            parse_simple(child)
    if bt is None or w is None or st is None:
        el.clear()
        continue
    b = st // BUCKET_NS
    names = set(n for n, _ in bt)
    bins = set(bn for _, bn in bt)
    for label, marker in MARKERS.items():
        if marker is None:
            if 'VectorKit' in bins or 'GeoServices' in bins:
                buckets[b][label] += w
        elif marker in names:
            buckets[b][label] += w
    buckets[b]['TOTAL'] += w
    el.clear()

labels = list(MARKERS) + ['TOTAL']
print('| window (s) | ' + ' | '.join(labels) + ' |')
print('|' + '---|' * (len(labels) + 1))
for b in sorted(buckets):
    row = buckets[b]
    cells = ' | '.join(f"{row.get(l, 0) / 1e6:.0f}" for l in labels)
    print(f"| {b*2}–{b*2+2} | {cells} |")
