#!/usr/bin/env python3
"""Per-navigation signpost breakdown for the detail-load benchmark.

Input: an os-signpost XML export (xctrace export --xpath
'/trace-toc/run/data/table[@schema="os-signpost"]') of a trace recorded while
the app ran with `--nav-benchmark`.

The DEBUG driver drops a point Event named `nav_open` (message: contact-A /
contact-B / organization / event / phantom-org) before each navigation, and
the detail views wrap each load step in Begin/End regions
(contact_detail_load, contact_recent_events, event_detail_load, ...). This
script groups the regions into windows split at the `nav_open` markers and
prints, per window: each region's count + total duration, plus the window's
overall span.

Usage: nav_windows.py signposts.xml [--subsystem com.milestonemade.guesswho]
"""
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

XML = sys.argv[1]
SUBSYSTEM = "com.milestonemade.guesswho"
if "--subsystem" in sys.argv:
    SUBSYSTEM = sys.argv[sys.argv.index("--subsystem") + 1]

seen = {}

def resolve(elem):
    eid = elem.get("id")
    if eid is not None:
        v = elem.text or ""
        seen[eid] = v
        return v
    ref = elem.get("ref")
    if ref is not None:
        return seen.get(ref)
    return elem.text

rows = []  # (ts_ns, event_type, name, message)
for _, elem in ET.iterparse(XML, events=("end",)):
    if elem.tag != "row":
        continue
    ts = etype = name = subsystem = None
    message = None
    for child in elem:
        tag = child.tag
        if tag == "event-time":
            v = resolve(child)
            if v is not None:
                ts = int(v)
        elif tag == "event-type":
            etype = resolve(child)
        elif tag == "signpost-name":
            name = resolve(child)
        elif tag == "subsystem":
            subsystem = resolve(child)
        elif tag == "os-log-metadata":
            md = child.get("fmt")
            if md is None:
                ref = child.get("ref")
                if ref is not None:
                    md = seen.get("__md_" + ref)
            elif child.get("id"):
                seen["__md_" + child.get("id")] = md
            message = md
    if ts is not None and etype is not None and name is not None \
            and subsystem == SUBSYSTEM:
        rows.append((ts, etype, name, message or ""))
    elem.clear()

rows.sort(key=lambda r: r[0])

# Split into windows at nav_open markers.
windows = []  # (label, start_ns, end_ns_exclusive)
markers = [(ts, msg) for ts, etype, name, msg in rows
           if name == "nav_open" and etype == "Event"]
complete = [ts for ts, etype, name, _ in rows if name == "nav_benchmark_complete"]
for i, (ts, msg) in enumerate(markers):
    end = markers[i + 1][0] if i + 1 < len(markers) \
        else (complete[0] if complete else rows[-1][0] + 1)
    windows.append((msg or f"window{i}", ts, end))

def ms(ns):
    return ns / 1e6

print(f"# Per-navigation signpost windows — {XML}")
if not windows:
    print("\nNo nav_open markers found; dumping all intervals instead.")
    windows = [("(entire trace)", rows[0][0] if rows else 0,
                (rows[-1][0] + 1) if rows else 1)]

for label, start, end in windows:
    inside = [r for r in rows if start <= r[0] < end]
    # Pair Begin/End per name with a stack (regions are main-thread, nested).
    stacks = defaultdict(list)
    durs = defaultdict(list)   # name -> [duration_ns]
    ends = defaultdict(list)   # name -> [end_ns]
    for ts, etype, name, msg in inside:
        if etype == "Begin":
            stacks[name].append(ts)
        elif etype == "End" and stacks[name]:
            b = stacks[name].pop()
            durs[name].append(ts - b)
            ends[name].append(ts)
    span_end = max((max(e) for e in ends.values()), default=start)
    print(f"\n## {label} — nav_open at {start/1e9:.3f}s, "
          f"last region end +{ms(span_end - start):.0f} ms\n")
    print("| Region | Count | Total ms | Max ms |")
    print("|---|---|---|---|")
    for name in sorted(durs, key=lambda n: -sum(durs[n])):
        d = durs[name]
        print(f"| {name} | {len(d)} | {ms(sum(d)):.1f} | {ms(max(d)):.1f} |")
    dangling = {n: len(s) for n, s in stacks.items() if s}
    if dangling:
        print(f"\nUnpaired Begins (crossed window edge): {dangling}")
