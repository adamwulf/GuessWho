# time-profile aggregation — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-edc537f7/repo/.build/profiling/timeprofile-nav2.xml

rows: 17563, total sampled CPU: 17563 ms, main thread: 5042 ms

## Threads by sampled CPU (top 12)

| Thread | CPU ms | % of total |
|---|---|---|
| Main Thread 0x45d337e (GuessWho, pid: 5804) | 5042 | 28.7% |
| GuessWho 0x45d3b0f (GuessWho, pid: 5804) | 4322 | 24.6% |
| GuessWho 0x45d395a (GuessWho, pid: 5804) | 2898 | 16.5% |
| GuessWho 0x45d3b08 (GuessWho, pid: 5804) | 633 | 3.6% |
| GuessWho 0x45d39bb (GuessWho, pid: 5804) | 448 | 2.6% |
| GuessWho 0x45d395c (GuessWho, pid: 5804) | 431 | 2.5% |
| GuessWho 0x45d52ae (GuessWho, pid: 5804) | 403 | 2.3% |
| GuessWho 0x45d3929 (GuessWho, pid: 5804) | 352 | 2.0% |
| GuessWho 0x45d5968 (GuessWho, pid: 5804) | 301 | 1.7% |
| GuessWho 0x45d55ad (GuessWho, pid: 5804) | 243 | 1.4% |
| GuessWho 0x45d52e7 (GuessWho, pid: 5804) | 225 | 1.3% |
| GuessWho 0x45d55ac (GuessWho, pid: 5804) | 211 | 1.2% |

## Main thread — top leaf symbols (self weight, base = main 5042 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 243.0 | 4.8% | `objc_msgSend` | libobjc.A.dylib |
| 88.0 | 1.7% | `_DDScannerHandleState` | DataDetectorsCore |
| 62.0 | 1.2% | `_platform_memmove` | libsystem_platform.dylib |
| 53.0 | 1.1% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 50.0 | 1.0% | `__getattrlist` | libsystem_kernel.dylib |
| 48.0 | 1.0% | `swift_release` | libswiftCore.dylib |
| 46.0 | 0.9% | `objc_retain` | libobjc.A.dylib |
| 45.0 | 0.9% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 45.0 | 0.9% | `_xzm_free` | libsystem_malloc.dylib |
| 42.0 | 0.8% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 41.0 | 0.8% | `-[CUIStructuredThemeStore lookupAssetForKey:]` | CoreUI |
| 40.0 | 0.8% | `__CF_IS_OBJC` | CoreFoundation |
| 40.0 | 0.8% | `swift_retain` | libswiftCore.dylib |
| 39.0 | 0.8% | `madvise` | libsystem_kernel.dylib |
| 38.0 | 0.8% | `<deduplicated_symbol>` | dyld |

## Main thread — stack presence (weight of samples containing frame)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 3910.0 | 77.5% | `start` | dyld |
| 3735.0 | 74.1% | `UIApplicationMain` | UIKitCore |
| 3735.0 | 74.1% | `0x1c4ccdcf8` | UIKitCore |
| 3734.0 | 74.1% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 3733.0 | 74.0% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 3733.0 | 74.0% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 3454.0 | 68.5% | `-[NSApplication run]` | AppKit |
| 3454.0 | 68.5% | `UINSApplicationMain` | UIKitMacHelper |
| 3454.0 | 68.5% | `NSApplicationMain` | AppKit |
| 3454.0 | 68.5% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 3363.0 | 66.7% | `_DPSNextEvent` | AppKit |
| 3363.0 | 66.7% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 3363.0 | 66.7% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 3351.0 | 66.5% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 3351.0 | 66.5% | `ReceiveNextEventCommon` | HIToolbox |

## All threads — top leaf symbols (base = total 17563 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 865.0 | 4.9% | `objc_msgSend` | libobjc.A.dylib |
| 676.0 | 3.8% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 251.0 | 1.4% | `objc_release` | libobjc.A.dylib |
| 248.0 | 1.4% | `_xzm_free` | libsystem_malloc.dylib |
| 247.0 | 1.4% | `__getattrlist` | libsystem_kernel.dylib |
| 246.0 | 1.4% | `objc_retain` | libobjc.A.dylib |
| 228.0 | 1.3% | `__open` | libsystem_kernel.dylib |
| 225.0 | 1.3% | `_platform_memmove` | libsystem_platform.dylib |
| 216.0 | 1.2% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 212.0 | 1.2% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 184.0 | 1.0% | `__CF_IS_OBJC` | CoreFoundation |
| 177.0 | 1.0% | `_platform_memset` | libsystem_platform.dylib |
| 128.0 | 0.7% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 125.0 | 0.7% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 122.0 | 0.7% | `getattrlistbulk` | libsystem_kernel.dylib |

## App binaries (GuessWho*) — top leaf symbols, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 18.0 | 0.1% | `initializeWithCopy for Event` | GuessWhoSync |
| 17.0 | 0.1% | `DYLD-STUB$$swift_bridgeObjectRelease` | GuessWhoSync |
| 14.0 | 0.1% | `__swift_instantiateConcreteTypeFromMangledNameV2` | GuessWhoSync |
| 14.0 | 0.1% | `destroy for Event` | GuessWhoSync |
| 13.0 | 0.1% | `initializeWithCopy for Contact` | GuessWhoSync |
| 11.0 | 0.1% | `DYLD-STUB$$swift_bridgeObjectRetain` | GuessWhoSync |
| 8.0 | 0.0% | `destroy for Contact` | GuessWhoSync |
| 7.0 | 0.0% | `static SidecarISO8601.decimal(_:startingAt:count:)` | GuessWhoSync |
| 5.0 | 0.0% | `outlined init with copy of A?` | GuessWhoSync |
| 4.0 | 0.0% | `static EKEventStoreAdapter.toEvent(_:)` | GuessWhoSync |
| 4.0 | 0.0% | `DYLD-STUB$$type metadata accessor for Date` | GuessWhoSync |
| 4.0 | 0.0% | `Collection.map<A, B>(_:)` | GuessWhoSync |
| 3.0 | 0.0% | `0x10777242c` | GuessWhoSync |
| 3.0 | 0.0% | `destroy for DynamicKey` | GuessWhoSync |
| 3.0 | 0.0% | `Event.init(id:eventKitID:title:startDate:endDate:isAllDay:location:eventKitNotes:attendees:calendarName:cal...` | GuessWhoSync |

## App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 10738.0 | 61.1% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 5581.0 | 31.8% | `Result<>.init(catching:)` | GuessWhoSync |
| 5043.0 | 28.7% | `closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 5043.0 | 28.7% | `partial apply for closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 5042.0 | 28.7% | `static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 3920.0 | 22.3% | `EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 3920.0 | 22.3% | `closure #1 in closure #1 in GuessWhoSync.prepareRecentEventsIndex()` | GuessWhoSync |
| 3920.0 | 22.3% | `protocol witness for EventStoreProtocol.prepareEventsWithAttendeeIndex(in:) in conformance EKEventStoreAdapter` | GuessWhoSync |
| 3920.0 | 22.3% | `WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 3919.0 | 22.3% | `closure #1 in EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 3919.0 | 22.3% | `EKEventStoreAdapter.buildAttendeeIndex(in:)` | GuessWhoSync |
| 3919.0 | 22.3% | `partial apply for closure #1 in EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 3919.0 | 22.3% | `closure #1 in WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 3919.0 | 22.3% | `partial apply for closure #1 in WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 3734.0 | 21.3% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |

## Self weight by binary — all threads (top 25)

| CPU ms | % | Binary |
|---|---|---|
| 3216 | 18.3% | libobjc.A.dylib |
| 2793 | 15.9% | CoreFoundation |
| 1899 | 10.8% | libsystem_kernel.dylib |
| 1814 | 10.3% | libswiftCore.dylib |
| 1401 | 8.0% | Foundation |
| 1026 | 5.8% | libsystem_malloc.dylib |
| 721 | 4.1% | libsystem_platform.dylib |
| 536 | 3.1% | UIKitCore |
| 516 | 2.9% | EventKit |
| 346 | 2.0% | dyld |
| 288 | 1.6% | VectorKit |
| 278 | 1.6% | GuessWhoSync |
| 268 | 1.5% | libsystem_pthread.dylib |
| 185 | 1.1% | CoreData |
| 164 | 0.9% | DataDetectorsCore |
| 150 | 0.9% | libxpc.dylib |
| 150 | 0.9% | SwiftUICore |
| 133 | 0.8% | libdispatch.dylib |
| 115 | 0.7% | CoreGraphics |
| 103 | 0.6% | QuartzCore |
| 103 | 0.6% | libicucore.A.dylib |
| 103 | 0.6% | SwiftUI |
| 84 | 0.5% | Contacts |
| 83 | 0.5% | libsystem_blocks.dylib |
| 79 | 0.4% | GeoServices |

## Self weight by binary — main thread (top 20)

| CPU ms | % | Binary |
|---|---|---|
| 820 | 16.3% | libobjc.A.dylib |
| 623 | 12.4% | libswiftCore.dylib |
| 529 | 10.5% | UIKitCore |
| 483 | 9.6% | CoreFoundation |
| 299 | 5.9% | libsystem_kernel.dylib |
| 229 | 4.5% | dyld |
| 216 | 4.3% | libsystem_malloc.dylib |
| 192 | 3.8% | Foundation |
| 165 | 3.3% | libsystem_platform.dylib |
| 164 | 3.3% | DataDetectorsCore |
| 150 | 3.0% | SwiftUICore |
| 124 | 2.5% | VectorKit |
| 104 | 2.1% | GuessWhoSync |
| 103 | 2.0% | SwiftUI |
| 97 | 1.9% | QuartzCore |
| 68 | 1.3% | CoreUI |
| 68 | 1.3% | CoreGraphics |
| 50 | 1.0% | AttributeGraph |
| 47 | 0.9% | libsystem_pthread.dylib |
| 34 | 0.7% | AppKit |

## CPU by 5s bucket and binary (top 6 binaries per bucket)

- **0–5s** (total 610 ms): dyld 174ms, libobjc.A.dylib 114ms, libsystem_kernel.dylib 62ms, CoreFoundation 50ms, CoreUI 38ms, UIKitCore 37ms
- **5–10s** (total 3933 ms): CoreFoundation 637ms, libsystem_kernel.dylib 632ms, libobjc.A.dylib 612ms, libswiftCore.dylib 465ms, Foundation 462ms, libsystem_malloc.dylib 208ms
- **10–15s** (total 1106 ms): CoreFoundation 324ms, libobjc.A.dylib 218ms, libsystem_kernel.dylib 134ms, Foundation 129ms, libsystem_platform.dylib 82ms, libsystem_malloc.dylib 56ms
- **15–20s** (total 956 ms): CoreFoundation 263ms, libobjc.A.dylib 226ms, libsystem_kernel.dylib 102ms, Foundation 79ms, libsystem_malloc.dylib 64ms, libsystem_platform.dylib 63ms
- **20–25s** (total 254 ms): libobjc.A.dylib 47ms, CoreFoundation 42ms, libswiftCore.dylib 28ms, libsystem_kernel.dylib 26ms, UIKitCore 24ms, Foundation 17ms
- **25–30s** (total 11 ms): libobjc.A.dylib 3ms, libsystem_kernel.dylib 2ms, CoreFoundation 1ms, QuartzCore 1ms, libsystem_pthread.dylib 1ms, libswift_Concurrency.dylib 1ms
- **30–35s** (total 8 ms): libsystem_platform.dylib 1ms, libsystem_kernel.dylib 1ms, AppKit 1ms, libsystem_trace.dylib 1ms, libswiftCore.dylib 1ms, libobjc.A.dylib 1ms
- **35–40s** (total 980 ms): libobjc.A.dylib 271ms, CoreFoundation 176ms, EventKit 98ms, Foundation 94ms, libsystem_malloc.dylib 69ms, libsystem_kernel.dylib 62ms
- **40–45s** (total 1082 ms): libobjc.A.dylib 279ms, CoreFoundation 173ms, EventKit 108ms, libsystem_kernel.dylib 100ms, libswiftCore.dylib 89ms, libsystem_malloc.dylib 76ms
- **45–50s** (total 1477 ms): libobjc.A.dylib 402ms, CoreFoundation 311ms, EventKit 176ms, Foundation 135ms, libsystem_kernel.dylib 99ms, libswiftCore.dylib 80ms
- **50–55s** (total 1143 ms): libobjc.A.dylib 230ms, libswiftCore.dylib 207ms, CoreFoundation 159ms, SwiftUI 64ms, libsystem_malloc.dylib 62ms, libsystem_kernel.dylib 59ms
- **55–60s** (total 33 ms): libobjc.A.dylib 8ms, UIKitCore 8ms, libsystem_platform.dylib 4ms, libswiftCore.dylib 3ms, libsystem_kernel.dylib 2ms, QuartzCore 2ms
- **60–65s** (total 478 ms): libswiftCore.dylib 78ms, libobjc.A.dylib 71ms, CoreFoundation 61ms, UIKitCore 49ms, libsystem_malloc.dylib 31ms, SwiftUICore 31ms
- **65–70s** (total 1 ms): Foundation 1ms
- **70–75s** (total 1706 ms): VectorKit 269ms, libobjc.A.dylib 184ms, libswiftCore.dylib 177ms, CoreFoundation 147ms, libsystem_kernel.dylib 140ms, libsystem_malloc.dylib 115ms
- **75–80s** (total 595 ms): DataDetectorsCore 151ms, libswiftCore.dylib 91ms, libsystem_kernel.dylib 69ms, CoreFoundation 38ms, Foundation 34ms, libobjc.A.dylib 31ms
- **80–85s** (total 594 ms): libswiftCore.dylib 100ms, libobjc.A.dylib 79ms, UIKitCore 67ms, libsystem_kernel.dylib 56ms, CoreFoundation 49ms, Foundation 43ms
- **85–90s** (total 163 ms): libsystem_kernel.dylib 33ms, libswiftCore.dylib 28ms, CoreFoundation 18ms, libobjc.A.dylib 18ms, libsystem_malloc.dylib 18ms, UIKitCore 14ms
- **90–95s** (total 183 ms): libsystem_kernel.dylib 42ms, libswiftCore.dylib 33ms, libobjc.A.dylib 23ms, libsystem_malloc.dylib 15ms, CoreFoundation 13ms, UIKitCore 12ms
- **95–100s** (total 434 ms): libswiftCore.dylib 75ms, libobjc.A.dylib 75ms, libsystem_kernel.dylib 56ms, CoreFoundation 56ms, libsystem_malloc.dylib 33ms, Foundation 30ms
- **100–105s** (total 24 ms): libsystem_platform.dylib 6ms, libsystem_malloc.dylib 4ms, VectorKit 4ms, Foundation 2ms, libsystem_pthread.dylib 2ms, libsystem_kernel.dylib 1ms
- **110–115s** (total 14 ms): libsystem_platform.dylib 6ms, libsystem_malloc.dylib 3ms, VectorKit 3ms, libobjc.A.dylib 2ms
- **115–120s** (total 149 ms): libobjc.A.dylib 28ms, CoreFoundation 27ms, libsystem_malloc.dylib 23ms, libsystem_kernel.dylib 20ms, libsystem_platform.dylib 17ms, Foundation 13ms
- **120–125s** (total 745 ms): libobjc.A.dylib 164ms, CoreFoundation 122ms, libswiftCore.dylib 98ms, Foundation 59ms, libsystem_malloc.dylib 48ms, libsystem_kernel.dylib 47ms
- **125–130s** (total 235 ms): libobjc.A.dylib 47ms, CoreFoundation 43ms, libswiftCore.dylib 34ms, Foundation 22ms, GuessWhoSync 17ms, libsystem_malloc.dylib 14ms
- **135–140s** (total 1 ms): libobjc.A.dylib 1ms
- **140–145s** (total 2 ms): libsystem_malloc.dylib 1ms, libsystem_platform.dylib 1ms
- **145–150s** (total 1 ms): libobjc.A.dylib 1ms
- **150–155s** (total 632 ms): libswiftCore.dylib 128ms, libsystem_kernel.dylib 121ms, CoreFoundation 81ms, libobjc.A.dylib 75ms, Foundation 50ms, libsystem_malloc.dylib 36ms
- **155–160s** (total 2 ms): libobjc.A.dylib 2ms
- **165–170s** (total 1 ms): libsystem_pthread.dylib 1ms
- **180–185s** (total 8 ms): libsystem_malloc.dylib 3ms, libobjc.A.dylib 2ms, UIKitCore 1ms, libsystem_platform.dylib 1ms, libsystem_kernel.dylib 1ms
- **200–205s** (total 2 ms): libsystem_malloc.dylib 1ms, libobjc.A.dylib 1ms
