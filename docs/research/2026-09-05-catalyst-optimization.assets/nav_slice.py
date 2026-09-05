"""Slice a time-profile XML into per-navigation CPU windows.

Windows are given in seconds relative to the trace recording start-date
(log wall-clock minus start-date). Sample-time in the export is nanoseconds
from recording start. We sum sampled weight (ms) per window, split all-thread
vs main-thread, and collect top app-binary (GuessWho*) stack-presence frames.
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

XML = sys.argv[1]

# (label, start_s, end_s, kind) kind: "full" or "load" (load = nav_open->load-finished)
WINDOWS = [
    ("readiness+attendee (arm->A)", 0.0, 53.895, "full"),
    ("A full",   53.895, 62.443, "full"),
    ("B full",   62.443, 71.004, "full"),
    ("org full", 71.004, 77.429, "full"),
    ("event full", 77.429, 83.737, "full"),
    ("phantom full", 83.737, 89.113, "full"),
    ("A load",   53.895, 54.840, "load"),
    ("B load",   62.443, 62.955, "load"),
    ("org load", 71.004, 72.142, "load"),
]

intern = {}

def parse_binary(el):
    if 'ref' in el.attrib:
        return intern.get(el.attrib['ref'], '?')
    val = el.attrib.get('name', '?')
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

def parse_frame(el):
    if 'ref' in el.attrib:
        return intern.get(el.attrib['ref'], ('?', '?'))
    name = el.attrib.get('name')
    addr = el.attrib.get('addr', '?')
    binel = el.find('binary')
    binname = parse_binary(binel) if binel is not None else '(unmapped)'
    val = (name if name else addr, binname)
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

def parse_backtrace(el):
    if 'ref' in el.attrib:
        return intern.get(el.attrib['ref'], [])
    frames = [parse_frame(f) for f in el.findall('frame')]
    if 'id' in el.attrib:
        intern[el.attrib['id']] = frames
    return frames

def parse_simple(el):
    if 'ref' in el.attrib:
        return intern.get(el.attrib['ref'])
    if el.tag == 'thread':
        val = el.attrib.get('fmt', '?thread')
    elif el.tag in ('sample-time', 'weight'):
        val = int(el.text) if el.text else 0
    else:
        val = el.text if el.text is not None else el.attrib.get('fmt', '?')
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

allw = Counter()
mainw = Counter()
app_presence = {w[0]: Counter() for w in WINDOWS}

for _, el in ET.iterparse(XML, events=('end',)):
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
    if st is None or w is None:
        el.clear(); continue
    ts = st / 1e9  # ns -> s
    is_main = th is not None and th.startswith('Main Thread')
    for (label, a, b, kind) in WINDOWS:
        if a <= ts < b:
            allw[label] += w
            if is_main:
                mainw[label] += w
            if bt:
                seen = set()
                for fr in bt:
                    if fr[1].startswith('GuessWho') and fr not in seen:
                        seen.add(fr)
                        app_presence[label][fr] += w
    el.clear()

def ms(x): return x / 1e6

print("| Window | wall s | all-thread CPU ms | main-thread CPU ms |")
print("|---|---|---|---|")
for (label, a, b, kind) in WINDOWS:
    print(f"| {label} | {b-a:.2f} | {ms(allw[label]):.0f} | {ms(mainw[label]):.0f} |")

for (label, a, b, kind) in WINDOWS:
    top = app_presence[label].most_common(6)
    if not top:
        continue
    print(f"\n### {label} — top app-binary stack presence")
    for (sym, binn), wt in top:
        s = sym if len(sym) <= 90 else sym[:87] + '...'
        print(f"- {ms(wt):.0f} ms  `{s}`  ({binn})")
