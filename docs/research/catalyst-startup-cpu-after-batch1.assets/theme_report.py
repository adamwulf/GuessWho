#!/usr/bin/env python3
"""Theme-level stack-presence CPU report over an xctrace time-profile XML.

Unlike burst_report.py (exact frame-name match, so "static "/"closure #1 in "
prefixed frames show 0), this matches frame names by SUBSTRING, so the themes
line up with the baseline doc's theme table. A sample counts toward every
theme any of its frames matches (deduped per sample), so themes overlap and
do not sum to 100%.

Usage: theme_report.py <time-profile.xml>
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

XML = sys.argv[1]

# label -> list of frame-name substrings (any match counts the sample once)
THEMES = {
    'sidecar read+decode': ['FileSystemSidecarStore.read(',
                            'SidecarEnvelope.init(from:',
                            'SidecarCell.init(from:'],
    'ISO8601 parse': ['SidecarISO8601.date(from:'],
    'allPlaces': ['GuessWhoSync.allPlaces('],
    'conflict scan': ['keysWithUnresolvedConflicts(',
                      'unresolvedConflictVersions(',
                      'reconcileSidecars('],
    'contacts fetchAll': ['CNContactStoreAdapter.fetchAll(',
                          'runOnWorkQueue'],
    'ek attendees': ['eventsWithAttendee('],
    'eventsWindow': ['GuessWhoSync.eventsWindow(from:to:'],
    'linkCounts': ['GuessWhoSync.linkCounts(ofKind:'],
    'MapKit/Geo (binary)': None,  # binary match: VectorKit / GeoServices
}

KERNEL_LEAVES = ('__getattrlist', 'getattrlistbulk', '__open', 'stat',
                 'getxattr', '__mac_syscall', '__iopolicysys', 'lstat',
                 'mach_msg2_trap')

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
main_w = 0
theme_w = Counter()
theme_leaf_kernel = defaultdict(Counter)  # theme -> kernel leaf sym -> weight
buckets = defaultdict(Counter)            # 2s bucket -> theme/TOTAL -> weight
kernel_leaves = Counter()                 # leaf syms in libsystem_kernel
BUCKET_NS = 2_000_000_000

for event, el in ET.iterparse(XML, events=('end',)):
    if el.tag != 'row':
        continue
    st = th = w = None
    bt = None
    for child in el:
        if child.tag == 'sample-time':
            st = parse_simple(child)
        elif child.tag == 'thread':
            th = parse_simple(child)
        elif child.tag == 'weight':
            w = parse_simple(child)
        elif child.tag == 'backtrace':
            bt = parse_backtrace(child)
        elif child.tag == 'thread-state':
            parse_simple(child)
    if bt is None or w is None:
        el.clear()
        continue
    total_w += w
    if th is not None and th.startswith('Main Thread'):
        main_w += w
    b = st // BUCKET_NS if st is not None else -1
    buckets[b]['TOTAL'] += w
    leaf_sym, leaf_bin = bt[0]
    if leaf_bin == 'libsystem_kernel.dylib':
        kernel_leaves[leaf_sym] += w
    names = [n for n, _ in bt]
    bins = set(bn for _, bn in bt)
    for label, subs in THEMES.items():
        if subs is None:
            hit = 'VectorKit' in bins or 'GeoServices' in bins
        else:
            hit = any(s in n for n in names for s in subs)
        if hit:
            theme_w[label] += w
            buckets[b][label] += w
            if leaf_bin == 'libsystem_kernel.dylib':
                theme_leaf_kernel[label][leaf_sym] += w
    el.clear()

def ms(w):
    return w / 1e6

print(f"# theme report — {XML}")
print(f"\ntotal sampled CPU: {ms(total_w):.0f} ms; main thread: {ms(main_w):.0f} ms")

print("\n## Theme stack presence (overlapping; % of total)\n")
print("| Theme | CPU ms | % |")
print("|---|---|---|")
for label in THEMES:
    w = theme_w.get(label, 0)
    print(f"| {label} | {ms(w):.0f} | {100.0 * w / total_w if total_w else 0:.1f}% |")

print("\n## Kernel leaf symbols (all threads, top 15)\n")
print("| CPU ms | Leaf |")
print("|---|---|")
for sym, w in kernel_leaves.most_common(15):
    print(f"| {ms(w):.0f} | `{sym}` |")

print("\n## Kernel leaves inside each theme (top 5 per theme)\n")
for label in THEMES:
    row = theme_leaf_kernel.get(label)
    if not row:
        continue
    tops = ", ".join(f"`{s}` {ms(w):.0f}ms" for s, w in row.most_common(5))
    print(f"- **{label}**: {tops}")

print("\n## CPU by 2 s bucket (theme presence, ms)\n")
labels = list(THEMES) + ['TOTAL']
print('| window (s) | ' + ' | '.join(labels) + ' |')
print('|' + '---|' * (len(labels) + 1))
for b in sorted(buckets):
    row = buckets[b]
    cells = ' | '.join(f"{row.get(l, 0) / 1e6:.0f}" for l in labels)
    print(f"| {b*2}–{b*2+2} | {cells} |")
