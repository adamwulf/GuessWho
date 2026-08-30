# theme report — .build/traces/tp-after.xml

total sampled CPU: 7814 ms; main thread: 1055 ms

## Theme stack presence (overlapping; % of total)

| Theme | CPU ms | % |
|---|---|---|
| sidecar read+decode | 1743 | 22.3% |
| ISO8601 parse | 7 | 0.1% |
| allPlaces | 912 | 11.7% |
| conflict scan | 1 | 0.0% |
| contacts fetchAll | 1502 | 19.2% |
| ek attendees | 0 | 0.0% |
| eventsWindow | 907 | 11.6% |
| linkCounts | 343 | 4.4% |
| MapKit/Geo (binary) | 0 | 0.0% |

## Kernel leaf symbols (all threads, top 15)

| CPU ms | Leaf |
|---|---|
| 421 | `__open` |
| 317 | `__getattrlist` |
| 244 | `mach_msg2_trap` |
| 144 | `getattrlistbulk` |
| 93 | `kevent_id` |
| 75 | `read` |
| 67 | `stat` |
| 55 | `__mac_syscall` |
| 50 | `__iopolicysys` |
| 30 | `semaphore_signal_trap` |
| 26 | `semaphore_wait_trap` |
| 19 | `close` |
| 16 | `semaphore_timedwait_trap` |
| 10 | `madvise` |
| 10 | `fstat` |

## Kernel leaves inside each theme (top 5 per theme)

- **sidecar read+decode**: `__getattrlist` 256ms, `__open` 77ms, `read` 69ms, `stat` 59ms, `__mac_syscall` 46ms
- **allPlaces**: `__getattrlist` 96ms, `__mac_syscall` 22ms, `getattrlistbulk` 18ms, `kevent_id` 8ms, `__iopolicysys` 7ms
- **contacts fetchAll**: `mach_msg2_trap` 111ms, `__open` 32ms, `stat` 7ms, `mach_absolute_time` 3ms, `__ulock_wake` 2ms
- **eventsWindow**: `mach_msg2_trap` 37ms, `getattrlistbulk` 22ms, `__getattrlist` 7ms, `__ulock_wait2` 2ms, `__open` 2ms
- **linkCounts**: `__getattrlist` 50ms, `getattrlistbulk` 37ms, `kevent_id` 6ms, `__mac_syscall` 3ms, `__iopolicysys` 3ms

## CPU by 2 s bucket (theme presence, ms)

| window (s) | sidecar read+decode | ISO8601 parse | allPlaces | conflict scan | contacts fetchAll | ek attendees | eventsWindow | linkCounts | MapKit/Geo (binary) | TOTAL |
|---|---|---|---|---|---|---|---|---|---|---|
| 0–2 | 7 | 0 | 0 | 0 | 6 | 0 | 0 | 0 | 0 | 916 |
| 2–4 | 224 | 1 | 126 | 1 | 617 | 0 | 432 | 46 | 0 | 1824 |
| 4–6 | 223 | 0 | 129 | 0 | 609 | 0 | 0 | 43 | 0 | 1094 |
| 6–8 | 139 | 2 | 117 | 0 | 270 | 0 | 0 | 2 | 0 | 676 |
| 8–10 | 233 | 1 | 100 | 0 | 0 | 0 | 232 | 66 | 0 | 825 |
| 10–12 | 258 | 1 | 103 | 0 | 0 | 0 | 123 | 31 | 0 | 709 |
| 12–14 | 220 | 1 | 125 | 0 | 0 | 0 | 0 | 30 | 0 | 448 |
| 14–16 | 99 | 0 | 47 | 0 | 0 | 0 | 0 | 38 | 0 | 304 |
| 16–18 | 158 | 1 | 72 | 0 | 0 | 0 | 120 | 31 | 0 | 513 |
| 18–20 | 161 | 0 | 93 | 0 | 0 | 0 | 0 | 29 | 0 | 401 |
| 20–22 | 21 | 0 | 0 | 0 | 0 | 0 | 0 | 27 | 0 | 102 |
| 22–24 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 2 |
