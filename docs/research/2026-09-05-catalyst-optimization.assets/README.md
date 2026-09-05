# Evidence bundle — 2026-09-05 Catalyst optimization

Supporting evidence for [`../2026-09-05-catalyst-optimization.md`](../2026-09-05-catalyst-optimization.md).
All aggregate/sanitized (no contact/event names, emails, or record ids).

## Files

| File | What it is |
|---|---|
| `nav_slice.py` | Slices a `time-profile` XML into per-navigation CPU windows by log→trace clock alignment (window offsets are inline; edit if re-aligning). |
| `machouuid.py` | Mach-O `LC_UUID` extractor (used for build-vs-trace identity checks; `dwarfdump`/`otool`/`lipo` were not allow-listed). |
| `worker-handoff.txt` | Original worker message excerpts; analyst observations rather than raw application logs. |
| `per-navigation-cpu.md` | Output of `nav_slice.py` on the completed nav trace: per-window all/main CPU + per-open app hot paths. |
| `timeprofile-nav-completed.md` | Aggregated `time-profile` of `debug-nav-2` (completed nav, `85EADC20`). |
| `timeprofile-nav-aborted.md` | Aggregated `time-profile` of `debug-nav-1` (aborted nav, `2E41162C`) — isolates the attendee warm-up. |
| `timeprofile-debug-startup.md` | Aggregated `time-profile` of `debug-verify2` (this-tree startup, `86DE3F5E`). |
| `timeprofile-installed-v169.md` | Aggregated `time-profile` of `debug-launch-tp-1` (installed Release v169, `C7B114CE`). |

Bulky `.trace` bundles were last reported in the worker's `.build/profiling/`.
They are not part of this merged bundle; post-closure availability is unverified.

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

The worker reported coverage instrumentation (`-profile-generate` /
`-profile-coverage-mapping`, 69 invocations). Its overhead was not quantified.
Release was compiled at `a420e04`; no later Release rebuild is claimed.

## Capture commands (representative, from the repository root)

These reproduce the procedure, not an exact transcript of every attempt.
Confirm recovery of raw artifacts before attempting the analysis commands.

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
python3 docs/research/catalyst-startup-cpu-baseline.assets/time_profile_report.py tp.xml
python3 docs/research/2026-09-05-catalyst-optimization.assets/nav_slice.py tp.xml
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

## Registration restoration — worker-verified

After the captures: `lsregister -f /Applications/GuessWho.app` was run;
the worker reported `lsregister -dump` showed `/Applications/GuessWho.app`
registered. Presence does not prove launch precedence for future requests.
Installed process pid 84763 was not killed by the worker. 25 stale
sibling-worktree DerivedData registrations were pruned; future launches/builds
may register those apps again.

## Reported log observations — reconstructed, not verbatim

The worker read the shared app log at
`~/Library/Group Containers/T68Z94627S.com.milestonemade.guesswho/Logs/app-2026-09-05.log`.
The full log and process-tagged excerpts were not committed. These are
reconstructed observations from the [original worker handoff](worker-handoff.txt),
not a raw log export.

| Run | UTC time reported | Observation |
| --- | ----------------- | ----------- |
| Aborted nav | 19:49:46 | Attendee warm-up started; visible events count 1243. |
| Aborted nav | 19:49:54 | Contacts ready, 1685 records. |
| Aborted nav | 19:51:14 | Driver timed out at its 90-second readiness limit. |
| Aborted nav | 19:51:25 | Index built, 15760 occurrences; about 99 seconds since warm-up start. |
| Completed nav | 20:01:23 | Driver armed. |
| Completed nav | 20:02:12 | Readiness: attendees ready, contacts 1685, events 1242; contact A opened. |
| Completed nav | 20:02:20 | Contact B opened. |
| Completed nav | 20:02:29 | Organization opened. |
| Completed nav | 20:02:35 | Event opened. |
| Completed nav | 20:02:42 | Phantom organization opened. |
| Completed nav | 20:02:47 | Driver completed. |

Times above are rounded to seconds. The slicer used finer offsets recorded by
the worker, but the exact source log lines and synchronization evidence are
not retained. Its window boundaries therefore remain approximate.

Worker-reported loader durations: A 743 ms (core-ready 37 ms), B 424 ms
(core-ready 28 ms), organization 1009 ms (core-ready 27 ms). These are logical
loader milestones, not screen-paint timings. No reliable event/phantom
load-completion duration was retained.

**Timestamp correction:** the original README mistakenly used 20:49/20:51 for
the aborted run. The worker's original message records 19:49/19:51, used above.
The timeout and attendee warm-up use different start points; do not equate their
durations.

### Verification and retention limits

Committed: computation outputs, scripts, reconstructed metadata, and original
worker handoff excerpts. Not committed/copied into the manager worktree:
`.trace` bundles, source XML, build logs, raw app logs, or matching binaries/dSYMs.
Their last reported location was the worker's
`/Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-edc537f7/repo/.build/`.
After worker closure, path isolation prevented checking retention. Raw-artifact
availability is **unverified**; the commands above require recovering those
artifacts or making a new capture.

Manager corrections changed interpretation/labels, not sampled totals. No new
runtime measurement was made. The report distinguishes computation-backed
figures from worker-reported observations and proposed experiments.
