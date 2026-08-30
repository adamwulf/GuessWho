# theme report — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-0638a25a/repo/.build/traces/tp-after-b2.xml

total sampled CPU: 3301 ms; main thread: 854 ms

## Theme stack presence (overlapping; % of total)

| Theme | CPU ms | % |
|---|---|---|
| sidecar read+decode | 233 | 7.1% |
| ISO8601 parse | 4 | 0.1% |
| allPlaces | 190 | 5.8% |
| conflict scan | 0 | 0.0% |
| contacts fetchAll | 1214 | 36.8% |
| ek attendees | 0 | 0.0% |
| eventsWindow | 316 | 9.6% |
| linkCounts | 0 | 0.0% |
| MapKit/Geo (binary) | 0 | 0.0% |

## Kernel leaf symbols (all threads, top 15)

| CPU ms | Leaf |
|---|---|
| 134 | `mach_msg2_trap` |
| 94 | `__getattrlist` |
| 71 | `__open` |
| 32 | `stat` |
| 24 | `getattrlistbulk` |
| 13 | `__mac_syscall` |
| 11 | `read` |
| 9 | `__iopolicysys` |
| 8 | `__open_nocancel` |
| 8 | `mach_absolute_time` |
| 7 | `__ulock_wait2` |
| 7 | `semaphore_timedwait_trap` |
| 7 | `lstat` |
| 6 | `__kdebug_trace64` |
| 6 | `faccessat` |

## Kernel leaves inside each theme (top 5 per theme)

- **allPlaces**: `semaphore_timedwait_trap` 6ms
- **contacts fetchAll**: `mach_msg2_trap` 69ms, `__open` 14ms, `stat` 10ms, `mach_absolute_time` 7ms, `mach_msg2_internal` 2ms
- **eventsWindow**: `mach_msg2_trap` 38ms, `getattrlistbulk` 5ms, `__getattrlist` 3ms, `__ulock_wait2` 1ms, `kevent_id` 1ms

## CPU by 2 s bucket (theme presence, ms)

| window (s) | sidecar read+decode | ISO8601 parse | allPlaces | conflict scan | contacts fetchAll | ek attendees | eventsWindow | linkCounts | MapKit/Geo (binary) | TOTAL |
|---|---|---|---|---|---|---|---|---|---|---|
| 0–2 | 6 | 0 | 3 | 0 | 5 | 0 | 1 | 0 | 0 | 920 |
| 2–4 | 226 | 4 | 187 | 0 | 623 | 0 | 315 | 0 | 0 | 1658 |
| 4–6 | 0 | 0 | 0 | 0 | 558 | 0 | 0 | 0 | 0 | 567 |
| 6–8 | 1 | 0 | 0 | 0 | 28 | 0 | 0 | 0 | 0 | 138 |
| 8–10 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 |
| 10–12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 2 |
| 12–14 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 |
| 16–18 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 14 |
