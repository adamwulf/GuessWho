# time-profile aggregation — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-edc537f7/repo/.build/profiling/timeprofile-debug-verify2.xml

rows: 10409, total sampled CPU: 10409 ms, main thread: 2541 ms

## Threads by sampled CPU (top 12)

| Thread | CPU ms | % of total |
|---|---|---|
| GuessWho 0x4596a17 (GuessWho, pid: 97887) | 3333 | 32.0% |
| GuessWho 0x4596a06 (GuessWho, pid: 97887) | 2593 | 24.9% |
| Main Thread 0x45962a9 (GuessWho, pid: 97887) | 2541 | 24.4% |
| GuessWho 0x4596b69 (GuessWho, pid: 97887) | 623 | 6.0% |
| GuessWho 0x4597f36 (GuessWho, pid: 97887) | 252 | 2.4% |
| GuessWho 0x4596c4a (GuessWho, pid: 97887) | 231 | 2.2% |
| GuessWho 0x4596a16 (GuessWho, pid: 97887) | 230 | 2.2% |
| GuessWho 0x4596a05 (GuessWho, pid: 97887) | 174 | 1.7% |
| GuessWho 0x4596b67 (GuessWho, pid: 97887) | 107 | 1.0% |
| GuessWho 0x4596a1e (GuessWho, pid: 97887) | 80 | 0.8% |
| GuessWho 0x4597133 (GuessWho, pid: 97887) | 71 | 0.7% |
| GuessWho 0x45969bc (GuessWho, pid: 97887) | 52 | 0.5% |

## Main thread — top leaf symbols (self weight, base = main 2541 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 125.0 | 4.9% | `objc_msgSend` | libobjc.A.dylib |
| 47.0 | 1.8% | `_platform_memmove` | libsystem_platform.dylib |
| 42.0 | 1.7% | `__getattrlist` | libsystem_kernel.dylib |
| 36.0 | 1.4% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 31.0 | 1.2% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 30.0 | 1.2% | `madvise` | libsystem_kernel.dylib |
| 29.0 | 1.1% | `swift_retain` | libswiftCore.dylib |
| 28.0 | 1.1% | `-[CUIStructuredThemeStore lookupAssetForKey:]` | CoreUI |
| 28.0 | 1.1% | `swift_bridgeObjectRetain` | libswiftCore.dylib |
| 26.0 | 1.0% | `_xzm_free` | libsystem_malloc.dylib |
| 25.0 | 1.0% | `map_images_nolock` | libobjc.A.dylib |
| 25.0 | 1.0% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 24.0 | 0.9% | `__CF_IS_OBJC` | CoreFoundation |
| 23.0 | 0.9% | `dyld3::MachOFile::trieWalk(Diagnostics&, unsigned char const*, unsigned char const*, char const*)` | dyld |
| 23.0 | 0.9% | `swift_release` | libswiftCore.dylib |
| 22.0 | 0.9% | `prepareMethodLists(objc_class*, method_list_t**, int, bool, bool, char const*)` | libobjc.A.dylib |
| 22.0 | 0.9% | `lookUpImpOrForward` | libobjc.A.dylib |
| 22.0 | 0.9% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |

## Main thread — stack presence (weight of samples containing frame)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 1902.0 | 74.9% | `start` | dyld |
| 1736.0 | 68.3% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 1736.0 | 68.3% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 1736.0 | 68.3% | `0x1c4ccdcf8` | UIKitCore |
| 1735.0 | 68.3% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 1735.0 | 68.3% | `UIApplicationMain` | UIKitCore |
| 1475.0 | 58.0% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 1475.0 | 58.0% | `UINSApplicationMain` | UIKitMacHelper |
| 1475.0 | 58.0% | `-[NSApplication run]` | AppKit |
| 1475.0 | 58.0% | `NSApplicationMain` | AppKit |
| 1412.0 | 55.6% | `_DPSNextEvent` | AppKit |
| 1411.0 | 55.5% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 1411.0 | 55.5% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 1407.0 | 55.4% | `RunCurrentEventLoopInMode` | HIToolbox |
| 1406.0 | 55.3% | `ReceiveNextEventCommon` | HIToolbox |
| 1406.0 | 55.3% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 1405.0 | 55.3% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 1397.0 | 55.0% | `_CFRunLoopRunSpecificWithOptions` | CoreFoundation |

## All threads — top leaf symbols (base = total 10409 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 584.0 | 5.6% | `objc_msgSend` | libobjc.A.dylib |
| 553.0 | 5.3% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 169.0 | 1.6% | `objc_release` | libobjc.A.dylib |
| 167.0 | 1.6% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 137.0 | 1.3% | `_xzm_free` | libsystem_malloc.dylib |
| 130.0 | 1.2% | `_platform_memmove` | libsystem_platform.dylib |
| 126.0 | 1.2% | `objc_retain` | libobjc.A.dylib |
| 123.0 | 1.2% | `__CF_IS_OBJC` | CoreFoundation |
| 117.0 | 1.1% | `__getattrlist` | libsystem_kernel.dylib |
| 115.0 | 1.1% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 109.0 | 1.0% | `_platform_memset` | libsystem_platform.dylib |
| 103.0 | 1.0% | `__open` | libsystem_kernel.dylib |
| 96.0 | 0.9% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 91.0 | 0.9% | `-[EKObjectID isEqual:]` | EventKit |
| 88.0 | 0.8% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 85.0 | 0.8% | `_getLastByteOfValueIncludingMarker` | Foundation |
| 75.0 | 0.7% | `___CFBasicHashFindBucket_Linear` | CoreFoundation |
| 74.0 | 0.7% | `__CFStringHash` | CoreFoundation |

## App binaries (GuessWho*) — top leaf symbols, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 15.0 | 0.1% | `DYLD-STUB$$swift_bridgeObjectRelease` | GuessWhoSync |
| 7.0 | 0.1% | `DYLD-STUB$$swift_bridgeObjectRetain` | GuessWhoSync |
| 7.0 | 0.1% | `initializeWithCopy for Contact` | GuessWhoSync |
| 7.0 | 0.1% | `outlined init with copy of Contact` | GuessWhoSync |
| 5.0 | 0.0% | `static SidecarISO8601.decimal(_:startingAt:count:)` | GuessWhoSync |
| 5.0 | 0.0% | `static EKEventStoreAdapter.toEvent(_:)` | GuessWhoSync |
| 5.0 | 0.0% | `outlined destroy of Contact` | GuessWhoSync |
| 4.0 | 0.0% | `__swift_instantiateConcreteTypeFromMangledNameV2` | GuessWhoSync |
| 4.0 | 0.0% | `type metadata accessor for Contact` | GuessWhoSync |
| 3.0 | 0.0% | `outlined destroy of SidecarCell` | GuessWhoSync |
| 3.0 | 0.0% | `outlined destroy of Event` | GuessWhoSync |
| 3.0 | 0.0% | `outlined init with copy of Event` | GuessWhoSync |
| 3.0 | 0.0% | `Contact.lastNameSortKey.getter` | GuessWhoSync |
| 3.0 | 0.0% | `storeEnumTagSinglePayload for Event` | GuessWhoSync |
| 2.0 | 0.0% | `static SidecarISO8601.gregorianDaysSince1970(year:month:day:)` | GuessWhoSync |
| 2.0 | 0.0% | `static SidecarISO8601.fixedLayoutDate(from:)` | GuessWhoSync |
| 2.0 | 0.0% | `initializeWithCopy for SidecarKey` | GuessWhoSync |
| 2.0 | 0.0% | `static Event.stableID(forEventKitID:)` | GuessWhoSync |

## App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 7229.0 | 69.4% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 3856.0 | 37.0% | `Result<>.init(catching:)` | GuessWhoSync |
| 3553.0 | 34.1% | `closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 3553.0 | 34.1% | `static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 3553.0 | 34.1% | `partial apply for closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 3099.0 | 29.8% | `EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)` | GuessWhoSync |
| 3099.0 | 29.8% | `protocol witness for EventStoreProtocol.eventsWithAttendee(matchingEmails:orLocations:in:limit:) in conform...` | GuessWhoSync |
| 3099.0 | 29.8% | `closure #1 in closure #2 in GuessWhoSync.recentEvents(matchingEmails:matchingLocations:asOf:limit:)` | GuessWhoSync |
| 3098.0 | 29.8% | `partial apply for closure #1 in WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 3098.0 | 29.8% | `closure #5 in EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)` | GuessWhoSync |
| 3098.0 | 29.8% | `closure #1 in WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 3098.0 | 29.8% | `partial apply for closure #5 in EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)` | GuessWhoSync |
| 3098.0 | 29.8% | `EKEventStoreAdapter.buildAttendeeIndex(in:)` | GuessWhoSync |
| 3098.0 | 29.8% | `WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 2836.0 | 27.2% | `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 2561.0 | 24.6% | `implicit closure #1 in static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 2561.0 | 24.6% | `partial apply for implicit closure #1 in static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 2560.0 | 24.6% | `static EKEventStoreAdapter.toEvent(_:)` | GuessWhoSync |

## Self weight by binary — all threads (top 25)

| CPU ms | % | Binary |
|---|---|---|
| 2113 | 20.3% | libobjc.A.dylib |
| 1834 | 17.6% | CoreFoundation |
| 1090 | 10.5% | libsystem_kernel.dylib |
| 988 | 9.5% | libswiftCore.dylib |
| 879 | 8.4% | Foundation |
| 584 | 5.6% | libsystem_malloc.dylib |
| 490 | 4.7% | libsystem_platform.dylib |
| 363 | 3.5% | EventKit |
| 277 | 2.7% | UIKitCore |
| 258 | 2.5% | dyld |
| 158 | 1.5% | CoreData |
| 150 | 1.4% | GuessWhoSync |
| 113 | 1.1% | libsystem_pthread.dylib |
| 108 | 1.0% | libxpc.dylib |
| 99 | 1.0% | Contacts |
| 92 | 0.9% | libdispatch.dylib |
| 77 | 0.7% | libicucore.A.dylib |
| 71 | 0.7% | SwiftUI |
| 44 | 0.4% | CoreGraphics |
| 43 | 0.4% | QuartzCore |
| 43 | 0.4% | CalendarDaemon |
| 40 | 0.4% | libsystem_blocks.dylib |
| 39 | 0.4% | libsystem_c.dylib |
| 37 | 0.4% | CoreUI |
| 36 | 0.3% | SwiftUICore |

## Self weight by binary — main thread (top 20)

| CPU ms | % | Binary |
|---|---|---|
| 438 | 17.2% | libobjc.A.dylib |
| 355 | 14.0% | libswiftCore.dylib |
| 294 | 11.6% | CoreFoundation |
| 275 | 10.8% | UIKitCore |
| 169 | 6.7% | dyld |
| 159 | 6.3% | libsystem_kernel.dylib |
| 116 | 4.6% | libsystem_platform.dylib |
| 91 | 3.6% | libsystem_malloc.dylib |
| 90 | 3.5% | Foundation |
| 75 | 3.0% | GuessWhoSync |
| 71 | 2.8% | SwiftUI |
| 37 | 1.5% | CoreUI |
| 36 | 1.4% | SwiftUICore |
| 36 | 1.4% | QuartzCore |
| 28 | 1.1% | AppKit |
| 23 | 0.9% | CoreGraphics |
| 18 | 0.7% | GuessWho.debug.dylib |
| 17 | 0.7% | libicucore.A.dylib |
| 15 | 0.6% | libsystem_pthread.dylib |
| 11 | 0.4% | CoreText |

## CPU by 5s bucket and binary (top 6 binaries per bucket)

- **0–5s** (total 172 ms): dyld 115ms, libobjc.A.dylib 32ms, CoreFoundation 6ms, libsystem_kernel.dylib 5ms, libsystem_platform.dylib 4ms, UIKitCore 2ms
- **5–10s** (total 2534 ms): libobjc.A.dylib 376ms, libsystem_kernel.dylib 355ms, libswiftCore.dylib 322ms, CoreFoundation 310ms, Foundation 264ms, UIKitCore 181ms
- **10–15s** (total 1558 ms): CoreFoundation 385ms, libobjc.A.dylib 318ms, libsystem_kernel.dylib 159ms, Foundation 150ms, libsystem_malloc.dylib 115ms, libsystem_platform.dylib 101ms
- **15–20s** (total 1089 ms): CoreFoundation 314ms, libobjc.A.dylib 221ms, libsystem_kernel.dylib 116ms, Foundation 114ms, libsystem_malloc.dylib 86ms, libsystem_platform.dylib 68ms
- **20–25s** (total 2562 ms): libobjc.A.dylib 516ms, CoreFoundation 396ms, libswiftCore.dylib 348ms, libsystem_kernel.dylib 252ms, Foundation 167ms, libsystem_malloc.dylib 147ms
- **25–30s** (total 2463 ms): libobjc.A.dylib 644ms, CoreFoundation 417ms, EventKit 262ms, libswiftCore.dylib 238ms, libsystem_kernel.dylib 200ms, Foundation 182ms
- **30–35s** (total 31 ms): CoreFoundation 6ms, libobjc.A.dylib 6ms, libsystem_kernel.dylib 3ms, libswiftCore.dylib 3ms, UIKitCore 3ms, Foundation 2ms
