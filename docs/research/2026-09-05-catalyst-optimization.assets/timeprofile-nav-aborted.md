# time-profile aggregation — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-edc537f7/repo/.build/profiling/timeprofile-nav1.xml

rows: 11193, total sampled CPU: 11193 ms, main thread: 1589 ms

## Threads by sampled CPU (top 12)

| Thread | CPU ms | % of total |
|---|---|---|
| GuessWho 0x45bbe55 (GuessWho, pid: 64571) | 5186 | 46.3% |
| GuessWho 0x45bbe4a (GuessWho, pid: 64571) | 2328 | 20.8% |
| Main Thread 0x45bb9a4 (GuessWho, pid: 64571) | 1589 | 14.2% |
| GuessWho 0x45bbe4b (GuessWho, pid: 64571) | 436 | 3.9% |
| GuessWho 0x45c0bc8 (GuessWho, pid: 64571) | 263 | 2.3% |
| GuessWho 0x45bbe13 (GuessWho, pid: 64571) | 258 | 2.3% |
| GuessWho 0x45bef6d (GuessWho, pid: 64571) | 196 | 1.8% |
| GuessWho 0x45bbe53 (GuessWho, pid: 64571) | 142 | 1.3% |
| GuessWho 0x45bbe34 (GuessWho, pid: 64571) | 121 | 1.1% |
| GuessWho 0x45bbe12 (GuessWho, pid: 64571) | 118 | 1.1% |
| GuessWho 0x45bbe3b (GuessWho, pid: 64571) | 94 | 0.8% |
| GuessWho 0x45bbe49 (GuessWho, pid: 64571) | 91 | 0.8% |

## Main thread — top leaf symbols (self weight, base = main 1589 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 85.0 | 5.3% | `objc_msgSend` | libobjc.A.dylib |
| 49.0 | 3.1% | `__getattrlist` | libsystem_kernel.dylib |
| 25.0 | 1.6% | `__CF_IS_OBJC` | CoreFoundation |
| 25.0 | 1.6% | `madvise` | libsystem_kernel.dylib |
| 24.0 | 1.5% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 21.0 | 1.3% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 21.0 | 1.3% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 20.0 | 1.3% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 20.0 | 1.3% | `_platform_memmove` | libsystem_platform.dylib |
| 20.0 | 1.3% | `-[CUIStructuredThemeStore lookupAssetForKey:]` | CoreUI |
| 19.0 | 1.2% | `dyld3::MachOFile::trieWalk(Diagnostics&, unsigned char const*, unsigned char const*, char const*)` | dyld |
| 19.0 | 1.2% | `_xzm_free` | libsystem_malloc.dylib |

## Main thread — stack presence (weight of samples containing frame)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 1325.0 | 83.4% | `start` | dyld |
| 1253.0 | 78.9% | `0x1c4ccdcf8` | UIKitCore |
| 1253.0 | 78.9% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 1253.0 | 78.9% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 1253.0 | 78.9% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 1253.0 | 78.9% | `UIApplicationMain` | UIKitCore |
| 1095.0 | 68.9% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 1095.0 | 68.9% | `NSApplicationMain` | AppKit |
| 1095.0 | 68.9% | `UINSApplicationMain` | UIKitMacHelper |
| 1094.0 | 68.8% | `-[NSApplication run]` | AppKit |
| 1075.0 | 67.7% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 1075.0 | 67.7% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |

## All threads — top leaf symbols (base = total 11193 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 657.0 | 5.9% | `objc_msgSend` | libobjc.A.dylib |
| 605.0 | 5.4% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 204.0 | 1.8% | `objc_release` | libobjc.A.dylib |
| 190.0 | 1.7% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 172.0 | 1.5% | `objc_retain` | libobjc.A.dylib |
| 164.0 | 1.5% | `__getattrlist` | libsystem_kernel.dylib |
| 163.0 | 1.5% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 163.0 | 1.5% | `_xzm_free` | libsystem_malloc.dylib |
| 147.0 | 1.3% | `_platform_memset` | libsystem_platform.dylib |
| 127.0 | 1.1% | `-[EKObjectID isEqual:]` | EventKit |
| 124.0 | 1.1% | `_platform_memmove` | libsystem_platform.dylib |
| 121.0 | 1.1% | `__CF_IS_OBJC` | CoreFoundation |

## App binaries (GuessWho*) — top leaf symbols, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 10.0 | 0.1% | `static EKEventStoreAdapter.toEvent(_:)` | GuessWhoSync |
| 9.0 | 0.1% | `__swift_instantiateConcreteTypeFromMangledNameV2` | GuessWhoSync |
| 9.0 | 0.1% | `initializeWithCopy for Event` | GuessWhoSync |
| 5.0 | 0.0% | `DYLD-STUB$$swift_bridgeObjectRelease` | GuessWhoSync |
| 4.0 | 0.0% | `Collection.map<A, B>(_:)` | GuessWhoSync |
| 4.0 | 0.0% | `Event.init(id:eventKitID:title:startDate:endDate:isAllDay:location:eventKitNotes:attendees:calendarName:cal...` | GuessWhoSync |
| 4.0 | 0.0% | `destroy for Event` | GuessWhoSync |
| 3.0 | 0.0% | `outlined destroy of String` | GuessWhoSync |
| 3.0 | 0.0% | `static SidecarISO8601.decimal(_:startingAt:count:)` | GuessWhoSync |
| 3.0 | 0.0% | `JSONValue.init(from:)` | GuessWhoSync |
| 3.0 | 0.0% | `static EKEventStoreAdapter.hexString(from:)` | GuessWhoSync |
| 2.0 | 0.0% | `destroy for DynamicKey` | GuessWhoSync |

## App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 9003.0 | 80.4% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 5863.0 | 52.4% | `Result<>.init(catching:)` | GuessWhoSync |
| 5555.0 | 49.6% | `partial apply for closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 5555.0 | 49.6% | `static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 5555.0 | 49.6% | `closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 4934.0 | 44.1% | `closure #1 in closure #1 in GuessWhoSync.prepareRecentEventsIndex()` | GuessWhoSync |
| 4933.0 | 44.1% | `WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 4933.0 | 44.1% | `EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 4933.0 | 44.1% | `protocol witness for EventStoreProtocol.prepareEventsWithAttendeeIndex(in:) in conformance EKEventStoreAdapter` | GuessWhoSync |
| 4932.0 | 44.1% | `closure #1 in EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 4932.0 | 44.1% | `partial apply for closure #1 in WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 4932.0 | 44.1% | `partial apply for closure #1 in EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |

## Self weight by binary — all threads (top 25)

| CPU ms | % | Binary |
|---|---|---|
| 2418 | 21.6% | libobjc.A.dylib |
| 2067 | 18.5% | CoreFoundation |
| 1234 | 11.0% | libsystem_kernel.dylib |
| 1023 | 9.1% | Foundation |
| 833 | 7.4% | libswiftCore.dylib |
| 701 | 6.3% | libsystem_malloc.dylib |
| 565 | 5.0% | EventKit |
| 482 | 4.3% | libsystem_platform.dylib |
| 235 | 2.1% | UIKitCore |
| 186 | 1.7% | dyld |
| 149 | 1.3% | libxpc.dylib |
| 136 | 1.2% | GuessWhoSync |
| 128 | 1.1% | libsystem_pthread.dylib |
| 123 | 1.1% | CoreData |
| 96 | 0.9% | libicucore.A.dylib |
| 91 | 0.8% | libdispatch.dylib |
| 78 | 0.7% | CoreGraphics |
| 69 | 0.6% | Contacts |
| 58 | 0.5% | libsystem_blocks.dylib |
| 48 | 0.4% | CalendarDaemon |
| 36 | 0.3% | CalendarFoundation |
| 35 | 0.3% | QuartzCore |
| 32 | 0.3% | CoreUI |
| 31 | 0.3% | libsystem_c.dylib |
| 31 | 0.3% | CalendarDatabase |

## Self weight by binary — main thread (top 20)

| CPU ms | % | Binary |
|---|---|---|
| 279 | 17.6% | libobjc.A.dylib |
| 232 | 14.6% | UIKitCore |
| 216 | 13.6% | CoreFoundation |
| 153 | 9.6% | libsystem_kernel.dylib |
| 105 | 6.6% | libswiftCore.dylib |
| 96 | 6.0% | dyld |
| 87 | 5.5% | libsystem_malloc.dylib |
| 70 | 4.4% | Foundation |
| 56 | 3.5% | libsystem_platform.dylib |
| 32 | 2.0% | CoreUI |
| 32 | 2.0% | QuartzCore |
| 18 | 1.1% | GuessWhoSync |
| 18 | 1.1% | AppKit |
| 17 | 1.1% | CoreGraphics |
| 15 | 0.9% | GuessWho.debug.dylib |
| 12 | 0.8% | CoreAutoLayout |
| 9 | 0.6% | SwiftUICore |
| 9 | 0.6% | libsystem_pthread.dylib |
| 8 | 0.5% | libicucore.A.dylib |
| 7 | 0.4% | UIKitMacHelper |

## CPU by 5s bucket and binary (top 6 binaries per bucket)

- **0–5s** (total 1596 ms): libsystem_kernel.dylib 262ms, libobjc.A.dylib 226ms, CoreFoundation 211ms, Foundation 199ms, UIKitCore 114ms, dyld 112ms
- **5–10s** (total 2517 ms): CoreFoundation 515ms, libsystem_kernel.dylib 424ms, libobjc.A.dylib 399ms, libswiftCore.dylib 282ms, Foundation 235ms, libsystem_malloc.dylib 180ms
- **10–15s** (total 1618 ms): CoreFoundation 379ms, libobjc.A.dylib 361ms, libsystem_kernel.dylib 179ms, Foundation 147ms, libsystem_platform.dylib 106ms, libsystem_malloc.dylib 105ms
- **15–20s** (total 636 ms): libobjc.A.dylib 179ms, CoreFoundation 114ms, Foundation 54ms, libsystem_malloc.dylib 47ms, EventKit 46ms, libsystem_kernel.dylib 35ms
- **20–25s** (total 337 ms): libobjc.A.dylib 86ms, CoreFoundation 62ms, libsystem_kernel.dylib 33ms, EventKit 31ms, Foundation 22ms, libswiftCore.dylib 21ms
- **25–30s** (total 99 ms): libobjc.A.dylib 29ms, CoreFoundation 16ms, Foundation 11ms, EventKit 10ms, libsystem_kernel.dylib 5ms, libsystem_malloc.dylib 4ms
- **30–35s** (total 96 ms): libobjc.A.dylib 28ms, CoreFoundation 17ms, libswiftCore.dylib 11ms, Foundation 10ms, EventKit 8ms, libsystem_kernel.dylib 6ms
- **35–40s** (total 232 ms): libobjc.A.dylib 65ms, CoreFoundation 42ms, EventKit 20ms, libsystem_malloc.dylib 20ms, libswiftCore.dylib 18ms, Foundation 18ms
- **40–45s** (total 365 ms): libobjc.A.dylib 93ms, CoreFoundation 60ms, EventKit 38ms, libsystem_kernel.dylib 26ms, libswiftCore.dylib 26ms, Foundation 22ms
- **45–50s** (total 790 ms): libobjc.A.dylib 258ms, CoreFoundation 152ms, EventKit 133ms, Foundation 71ms, libswiftCore.dylib 48ms, libsystem_malloc.dylib 33ms
- **50–55s** (total 293 ms): libobjc.A.dylib 74ms, CoreFoundation 48ms, libsystem_kernel.dylib 36ms, EventKit 34ms, Foundation 21ms, libswiftCore.dylib 19ms
- **55–60s** (total 174 ms): CoreFoundation 39ms, libobjc.A.dylib 26ms, EventKit 18ms, Foundation 16ms, libsystem_kernel.dylib 15ms, libswiftCore.dylib 14ms
- **60–65s** (total 188 ms): CoreFoundation 38ms, libobjc.A.dylib 36ms, libsystem_kernel.dylib 25ms, Foundation 19ms, libswiftCore.dylib 18ms, EventKit 16ms
- **65–70s** (total 126 ms): libobjc.A.dylib 31ms, CoreFoundation 27ms, libswiftCore.dylib 13ms, Foundation 11ms, libsystem_kernel.dylib 10ms, libsystem_malloc.dylib 9ms
- **70–75s** (total 99 ms): libobjc.A.dylib 21ms, CoreFoundation 19ms, libswiftCore.dylib 11ms, Foundation 10ms, EventKit 9ms, libsystem_malloc.dylib 8ms
- **75–80s** (total 46 ms): libobjc.A.dylib 16ms, CoreFoundation 10ms, libswiftCore.dylib 5ms, libsystem_malloc.dylib 4ms, EventKit 3ms, Foundation 3ms
- **80–85s** (total 119 ms): CoreFoundation 30ms, libobjc.A.dylib 23ms, libsystem_kernel.dylib 11ms, EventKit 10ms, libsystem_malloc.dylib 8ms, libswiftCore.dylib 8ms
- **85–90s** (total 385 ms): libobjc.A.dylib 102ms, CoreFoundation 61ms, EventKit 39ms, libsystem_kernel.dylib 36ms, Foundation 35ms, libswiftCore.dylib 32ms
- **90–95s** (total 125 ms): libobjc.A.dylib 39ms, CoreFoundation 21ms, EventKit 12ms, Foundation 9ms, libsystem_kernel.dylib 9ms, libsystem_malloc.dylib 8ms
- **95–100s** (total 117 ms): libobjc.A.dylib 31ms, CoreFoundation 29ms, Foundation 13ms, libsystem_kernel.dylib 11ms, libsystem_malloc.dylib 7ms, EventKit 7ms
- **100–105s** (total 345 ms): libobjc.A.dylib 105ms, CoreFoundation 55ms, Foundation 29ms, EventKit 28ms, libswiftCore.dylib 25ms, libsystem_malloc.dylib 20ms
- **105–110s** (total 489 ms): libobjc.A.dylib 108ms, libswiftCore.dylib 68ms, UIKitCore 64ms, CoreFoundation 55ms, libsystem_malloc.dylib 35ms, libsystem_kernel.dylib 31ms
- **110–115s** (total 1 ms): libsystem_malloc.dylib 1ms
- **115–120s** (total 7 ms): libsystem_malloc.dylib 3ms, libsystem_platform.dylib 1ms, dyld 1ms, libobjc.A.dylib 1ms, Foundation 1ms
- **125–130s** (total 324 ms): libobjc.A.dylib 75ms, CoreFoundation 59ms, libswiftCore.dylib 36ms, libsystem_kernel.dylib 30ms, libsystem_malloc.dylib 25ms, Foundation 21ms
- **130–135s** (total 69 ms): libswiftCore.dylib 15ms, Foundation 12ms, libsystem_malloc.dylib 10ms, GuessWhoSync 8ms, CoreFoundation 8ms, libobjc.A.dylib 6ms
