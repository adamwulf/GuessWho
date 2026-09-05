# Evidence bundle — 2026-09-05 Catalyst optimization

Supporting evidence for [`../2026-09-05-catalyst-optimization.md`](../2026-09-05-catalyst-optimization.md).
All aggregate/sanitized (no contact/event names, emails, or record ids).

## Files

| File | What it is |
|---|---|
| `nav_slice.py` | Slices a `time-profile` XML into per-navigation CPU windows by log→trace clock alignment (window offsets are inline; edit if re-aligning). |
| `machouuid.py` | Mach-O `LC_UUID` extractor (used for build-vs-trace identity checks; `dwarfdump`/`otool`/`lipo` were not allow-listed). |
| `per-navigation-cpu.md` | Output of `nav_slice.py` on the completed nav trace: per-window all/main CPU + per-open app hot paths. |
| `timeprofile-nav-completed.md` | Aggregated `time-profile` of `debug-nav-2` (completed nav, `85EADC20`). |
| `timeprofile-nav-aborted.md` | Aggregated `time-profile` of `debug-nav-1` (aborted nav, `2E41162C`) — isolates the attendee warm-up. |
| `timeprofile-debug-startup.md` | Aggregated `time-profile` of `debug-verify2` (this-tree startup, `86DE3F5E`). |
| `timeprofile-installed-v169.md` | Aggregated `time-profile` of `debug-launch-tp-1` (installed Release v169, `C7B114CE`). |

Bulky `.trace` bundles live in `.build/profiling/` (worktree-local, not committed).

## Environment

Xcode 26.3 (17C519); xctrace 26.0 (17C519); macOS 26.5.2 (25F84), Apple Silicon
(`t6000`); SDK MacOSX26.2, target `arm64-apple-ios17.0-macabi`. Branch
`agent/agent-edc537f7` @ `ecdd424`.

## Build commands & outcomes (all `** BUILD SUCCEEDED **`)

```sh
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData -configuration Debug build     # a420e04, ba9b95c, ecdd424
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData -configuration Release build   # exclusion validation
```

Debug scheme compiles with coverage instrumentation (`-profile-generate` /
`-profile-coverage-mapping`, 69 invocations) — inflates absolute CPU.

## Capture commands (representative)

```sh
# per capture: prune stale DerivedData registrations, unregister installed, prefer this build
python3 ~/.claude/skills/xctrace/prune-lsregister.py com.milestonemade.guesswho \
  --keep .build/DerivedData/Build/Products/Debug-maccatalyst/GuessWho.app --apply
lsregister -u /Applications/GuessWho.app
lsregister -f .build/DerivedData/Build/Products/Debug-maccatalyst/GuessWho.app

# completed navigation capture (240 s; 180 s readiness deadline in ecdd424)
xcrun xctrace record --template "Time Profiler" --instrument "os_signpost" \
  --time-limit 240s --no-prompt \
  --output .build/profiling/debug-nav-2.trace \
  --launch -- .build/DerivedData/Build/Products/Debug-maccatalyst/GuessWho.app/Contents/MacOS/GuessWho \
  --nav-benchmark

# restore installed registration afterward (done on success AND every abort)
lsregister -f /Applications/GuessWho.app

# analysis
xcrun xctrace export --input <trace> \
  --xpath '/trace-toc/run/data/table[@schema="time-profile"]' --output tp.xml
python3 ../catalyst-startup-cpu-baseline.assets/time_profile_report.py tp.xml
python3 nav_slice.py tp.xml
```

Note: `xctrace --launch` routes through LaunchServices (even the inner exec
path), so it substituted the installed `/Applications` app until it was
unregistered. `xctrace --env GUESSWHO_NAV_BENCHMARK=1` stalled the launch twice
(unexplained); the `--nav-benchmark` argv path was used instead.

## Trace identity checks (build UUID ⊂ trace `symbols/stores/`)

| Trace | build | dylib UUID present | attribution |
|---|---|---|---|
| `debug-nav-2` | `ecdd424` | `85EADC20-93D5-3E8B-ACFC-7BE491B4D701` | this tree — also toc `path=.../Debug-maccatalyst/GuessWho.app`, `arguments="--nav-benchmark"`, pid 5804, `exit(0)` |
| `debug-nav-1` | `ba9b95c` | `2E41162C-47D6-371F-9F64-B29B58C42B34` | this tree (aborted) |
| `debug-verify2` | `a420e04` | `86DE3F5E-20B5-3731-A8F6-DDD515A50E18` | this tree (startup) |
| `debug-launch-tp-1` | installed v169 | `C7B114CE-2333-37B6-AD2A-645B28D84E7A` | installed Release (substituted) |

Debug stub `GuessWho` UUID `38A28841-9F6C-31FA-BC06-C950C9DCBAB3` (stable).
Installed universal binary also has x86_64 UUID `19E3B61C-5DF6-31A6-9CDC-F716DEC336CC`.

## Registration restoration — VERIFIED

After the captures: `lsregister -f /Applications/GuessWho.app` was run;
`lsregister -dump` shows `/Applications/GuessWho.app` registered (front-ranked,
last `-f`). Installed process pid 84763 never killed. 25 stale sibling-worktree
DerivedData registrations were pruned (they re-register on next build).

## Key log excerpts (sanitized; counts/durations only)

App log: `~/Library/Group Containers/T68Z94627S.com.milestonemade.guesswho/Logs/app-2026-09-05.log`.

```
# permissions/data
startup cache load finished cache=contacts durationMs=11117 items=1685 status=ready
EventKit window fetch finished durationMs=... events=1517
EventKit attendee index built events=15760

# aborted nav (debug-nav-1): attendee warm-up finished ~99 s, 9 s past the 90 s gate
20:49:43 nav benchmark armed; waiting for startup caches
20:51:14 nav benchmark aborted: startup cache wait timed out
20:51:25 EventKit attendee index built events=15760

# completed nav (debug-nav-2): readiness then full sequence
20:02:12 nav benchmark: startup caches ready attendees=ready contacts=1685 events=1242
20:02:12 opening contact A   -> contact load finished durationMs=743 (core ready 37 ms)
20:02:20 opening contact B   -> contact load finished durationMs=424 (core ready 28 ms)
20:02:29 opening organization-> contact load finished durationMs=1009 (core ready 27 ms)
20:02:35 opening event       -> (no trustworthy load-finished breadcrumb)
20:02:42 opening phantom organization
20:02:47 nav benchmark: complete
```
