#!/usr/bin/env python3
"""Aggregate an xctrace time-profile XML export into hotspot tables.

The export interns elements: first occurrence carries id="N" plus content,
later occurrences are <tag ref="N"/>. We keep an id -> parsed-value table.

Outputs (markdown):
  - per-thread sample totals
  - top leaf symbols (self weight) for main thread and for all threads
  - top stack-presence symbols (deduped per sample) for main thread
  - self weight rolled up by binary (all threads + main)
  - self weight by binary per 5s bucket (all threads)
  - top leaf symbols restricted to app binaries (GuessWho*)
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

XML = sys.argv[1]
TOP = int(sys.argv[2]) if len(sys.argv) > 2 else 30

intern = {}  # id -> parsed value (depends on tag)

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
    sym = name if name else addr
    val = (sym, binname)
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
    """sample-time / weight / thread-state / thread: text or fmt value."""
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

total_w = 0
thread_w = Counter()
leaf_all = Counter()        # (sym, bin) -> weight, all threads
leaf_main = Counter()       # main thread only
presence_main = Counter()   # (sym, bin) -> weight, deduped per sample, main
bin_all = Counter()
bin_main = Counter()
bucket_bin = defaultdict(Counter)   # bucket(5s) -> binary -> weight
leaf_app = Counter()        # leaves in app binaries (GuessWho*)
app_presence_all = Counter()  # app-binary frames present anywhere in stack, all threads
n_rows = 0

for event, el in ET.iterparse(XML, events=('end',)):
    if el.tag != 'row':
        continue
    st = th = w = state = None
    bt = None
    for child in el:
        if child.tag == 'sample-time':
            st = parse_simple(child)
        elif child.tag == 'thread':
            th = parse_simple(child)
        elif child.tag == 'thread-state':
            state = parse_simple(child)
        elif child.tag == 'weight':
            w = parse_simple(child)
        elif child.tag == 'backtrace':
            bt = parse_backtrace(child)
    if bt is None or w is None:
        el.clear()
        continue
    n_rows += 1
    total_w += w
    is_main = th is not None and th.startswith('Main Thread')
    thread_w[th] += w
    leaf = bt[0]
    leaf_all[leaf] += w
    binname = leaf[1]
    bin_all[binname] += w
    if st is not None:
        bucket_bin[st // 5_000_000_000][binname] += w
    if binname.startswith('GuessWho'):
        leaf_app[leaf] += w
    for fr in set(bt):
        if fr[1].startswith('GuessWho'):
            app_presence_all[fr] += w
    if is_main:
        leaf_main[leaf] += w
        bin_main[binname] += w
        for fr in set(bt):
            presence_main[fr] += w
    el.clear()

def ms(w):
    return w / 1e6

def pct(w, base):
    return 100.0 * w / base if base else 0.0

main_total = sum(bin_main.values())

print(f"# time-profile aggregation — {XML}")
print(f"\nrows: {n_rows}, total sampled CPU: {ms(total_w):.0f} ms, "
      f"main thread: {ms(main_total):.0f} ms")

print(f"\n## Threads by sampled CPU (top 12)\n")
print("| Thread | CPU ms | % of total |")
print("|---|---|---|")
for th, w in thread_w.most_common(12):
    print(f"| {th} | {ms(w):.0f} | {pct(w, total_w):.1f}% |")

def table(counter, base, top, title):
    print(f"\n## {title}\n")
    print("| CPU ms | % | Symbol | Binary |")
    print("|---|---|---|---|")
    for (sym, b), w in counter.most_common(top):
        s = sym if len(sym) <= 110 else sym[:107] + '...'
        print(f"| {ms(w):.1f} | {pct(w, base):.1f}% | `{s}` | {b} |")

table(leaf_main, main_total, TOP, f"Main thread — top leaf symbols (self weight, base = main {ms(main_total):.0f} ms)")
table(presence_main, main_total, TOP, "Main thread — stack presence (weight of samples containing frame)")
table(leaf_all, total_w, TOP, f"All threads — top leaf symbols (base = total {ms(total_w):.0f} ms)")
table(leaf_app, total_w, TOP, "App binaries (GuessWho*) — top leaf symbols, all threads")
table(app_presence_all, total_w, TOP, "App binaries (GuessWho*) — stack presence, all threads")

print(f"\n## Self weight by binary — all threads (top 25)\n")
print("| CPU ms | % | Binary |")
print("|---|---|---|")
for b, w in bin_all.most_common(25):
    print(f"| {ms(w):.0f} | {pct(w, total_w):.1f}% | {b} |")

print(f"\n## Self weight by binary — main thread (top 20)\n")
print("| CPU ms | % | Binary |")
print("|---|---|---|")
for b, w in bin_main.most_common(20):
    print(f"| {ms(w):.0f} | {pct(w, main_total):.1f}% | {b} |")

print(f"\n## CPU by 5s bucket and binary (top 6 binaries per bucket)\n")
for bucket in sorted(bucket_bin):
    row = bucket_bin[bucket]
    tot = sum(row.values())
    tops = ", ".join(f"{b} {ms(w):.0f}ms" for b, w in row.most_common(6))
    print(f"- **{bucket*5}–{bucket*5+5}s** (total {ms(tot):.0f} ms): {tops}")
