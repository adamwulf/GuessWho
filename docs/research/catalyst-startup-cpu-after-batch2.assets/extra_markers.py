#!/usr/bin/env python3
"""Stack-presence weights for batch-2-specific markers over a time-profile XML.

Same interning/parse/dedupe approach as theme_report.py; only the marker set
differs. A sample counts toward every marker any of its frames substring-matches
(deduped per sample), so rows overlap.

Usage: extra_markers.py <time-profile.xml>
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

XML = sys.argv[1]

MARKERS = [
    'contactReloadProjection(',
    'allContactTimestamps(',
    'linkedEndpoints(',
    'linkCounts(',
    'allKeys()',
    'listKeys(',
    'walkCorpus(',
    'coordinatedCorpusRead(',
    'visitCapturedCorpus(',
    'runWithBusyHandling(',
    'ProductionSidecarFileCoordinator.coordinateReading(',
    'EventWindowFetchCoordinator',
    'fetchEventsDirectly(',
    'EKEventStoreAdapter.fetchEvents(',
    'enumerateAllContacts(',
    'CNContactStoreAdapter.fetchAll(',
    'ContactsRepository.reload(',
    'GuessWhoSync.allContacts(',
    'reconcileSidecars(',
    'JSONDecoder',
    'NSFileCoordinator',
]

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
    if el.tag == 'thread':
        val = el.attrib.get('fmt', '?thread')
    elif el.tag in ('sample-time', 'weight'):
        val = int(el.text)
    else:
        val = el.text or el.attrib.get('fmt', '?')
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

total_w = 0
marker_w = Counter()

for event, el in ET.iterparse(XML, events=('end',)):
    if el.tag != 'row':
        continue
    w = None
    bt = None
    for child in el:
        if child.tag == 'weight':
            w = parse_simple(child)
        elif child.tag == 'backtrace':
            bt = parse_backtrace(child)
        elif child.tag in ('sample-time', 'thread', 'thread-state'):
            parse_simple(child)
    if bt is None or w is None:
        el.clear()
        continue
    total_w += w
    names = [n for n, _ in bt]
    for m in MARKERS:
        if any(m in n for n in names):
            marker_w[m] += w
    el.clear()

print(f"# extra markers — {XML}")
print(f"\ntotal sampled CPU: {total_w / 1e6:.0f} ms\n")
print("| Marker | CPU ms | % |")
print("|---|---|---|")
for m in MARKERS:
    w = marker_w.get(m, 0)
    print(f"| `{m}` | {w / 1e6:.0f} | {100.0 * w / total_w if total_w else 0:.1f}% |")
