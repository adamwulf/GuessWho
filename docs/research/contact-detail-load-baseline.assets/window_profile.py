#!/usr/bin/env python3
"""Windowed variant of the baseline's time_profile_report.py.

Aggregates an xctrace `time-profile` XML export, restricted to one or more
[from..to] second windows (e.g. the per-navigation windows the nav_open
signpost markers delimit — see nav_windows.py). Prints, per window: total and
main-thread sampled CPU, top main-thread leaf symbols, and app-binary
(GuessWho*) stack presence.

Usage:
  window_profile.py tp.xml LABEL:FROM:TO [LABEL:FROM:TO ...] [--top N]
FROM/TO are seconds since trace start (floats).
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

TOP = 20
raw = sys.argv[1:]
if "--top" in raw:
    i = raw.index("--top")
    TOP = int(raw[i + 1])
    raw = raw[:i] + raw[i + 2:]
args = raw
XML = args[0]

windows = []
for spec in args[1:]:
    label, frm, to = spec.rsplit(":", 2)
    windows.append((label, float(frm) * 1e9, float(to) * 1e9))

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
        val = el.text if el.text is not None else el.attrib.get('fmt', '?')
    if 'id' in el.attrib:
        intern[el.attrib['id']] = val
    return val

class Win:
    def __init__(self, label, frm, to):
        self.label, self.frm, self.to = label, frm, to
        self.total = 0
        self.main = 0
        self.leaf_main = Counter()
        self.presence_main = Counter()
        self.leaf_all = Counter()
        self.app_presence = Counter()

wins = [Win(*w) for w in windows]

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
    el.clear()
    if bt is None or w is None or st is None:
        continue
    for win in wins:
        if not (win.frm <= st < win.to):
            continue
        win.total += w
        leaf = bt[0]
        win.leaf_all[leaf] += w
        is_main = th is not None and th.startswith('Main Thread')
        if is_main:
            win.main += w
            win.leaf_main[leaf] += w
            for fr in set(bt):
                win.presence_main[fr] += w
        for fr in set(bt):
            if fr[1].startswith('GuessWho'):
                win.app_presence[fr] += w

def ms(v):
    return v / 1e6

def table(counter, base, top, title):
    print(f"\n### {title}\n")
    print("| CPU ms | % | Symbol | Binary |")
    print("|---|---|---|---|")
    for (sym, b), v in counter.most_common(top):
        s = sym if len(sym) <= 110 else sym[:107] + '...'
        print(f"| {ms(v):.1f} | {100 * v / base if base else 0:.1f}% | `{s}` | {b} |")

print(f"# Windowed time-profile aggregation — {XML}")
for win in wins:
    print(f"\n## {win.label} [{win.frm/1e9:.2f}s – {win.to/1e9:.2f}s]\n")
    print(f"total sampled CPU: {ms(win.total):.0f} ms, "
          f"main thread: {ms(win.main):.0f} ms")
    table(win.leaf_main, win.main, TOP,
          f"Main thread — top leaf symbols (base {ms(win.main):.0f} ms)")
    table(win.presence_main, win.main, TOP,
          "Main thread — stack presence")
    table(win.leaf_all, win.total, TOP,
          f"All threads — top leaf symbols (base {ms(win.total):.0f} ms)")
    table(win.app_presence, win.total, TOP,
          "App binaries (GuessWho*) — stack presence, all threads")
