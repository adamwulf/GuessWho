# time-profile aggregation — .build/traces/tp-after.xml

rows: 7814, total sampled CPU: 7814 ms, main thread: 1055 ms

## Threads by sampled CPU (top 12)

| Thread | CPU ms | % of total |
|---|---|---|
| GuessWho 0x28d5f4a (GuessWho, pid: 96336) | 1972 | 25.2% |
| Main Thread 0x28d5cd0 (GuessWho, pid: 96336) | 1055 | 13.5% |
| GuessWho 0x28d5f22 (GuessWho, pid: 96336) | 968 | 12.4% |
| GuessWho 0x28d5f9f (GuessWho, pid: 96336) | 591 | 7.6% |
| GuessWho 0x28d5f9e (GuessWho, pid: 96336) | 589 | 7.5% |
| GuessWho 0x28d5f39 (GuessWho, pid: 96336) | 580 | 7.4% |
| GuessWho 0x28d5f48 (GuessWho, pid: 96336) | 426 | 5.5% |
| GuessWho 0x28d5f49 (GuessWho, pid: 96336) | 373 | 4.8% |
| GuessWho 0x28d5f23 (GuessWho, pid: 96336) | 336 | 4.3% |
| GuessWho 0x28d5f20 (GuessWho, pid: 96336) | 320 | 4.1% |
| GuessWho 0x28d5f97 (GuessWho, pid: 96336) | 217 | 2.8% |
| GuessWho 0x28d5f96 (GuessWho, pid: 96336) | 199 | 2.5% |

## Main thread — top leaf symbols (self weight, base = main 1055 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 59.0 | 5.6% | `objc_msgSend` | libobjc.A.dylib |
| 34.0 | 3.2% | `__getattrlist` | libsystem_kernel.dylib |
| 27.0 | 2.6% | `__CF_IS_OBJC` | CoreFoundation |
| 25.0 | 2.4% | `-[CUIStructuredThemeStore lookupAssetForKey:]` | CoreUI |
| 25.0 | 2.4% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 22.0 | 2.1% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 20.0 | 1.9% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 16.0 | 1.5% | `_platform_memmove` | libsystem_platform.dylib |
| 15.0 | 1.4% | `_xzm_free` | libsystem_malloc.dylib |
| 14.0 | 1.3% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 13.0 | 1.2% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 12.0 | 1.1% | `_CFRelease` | CoreFoundation |
| 11.0 | 1.0% | `map_images_nolock` | libobjc.A.dylib |
| 10.0 | 0.9% | `<deduplicated_symbol>` | dyld |
| 9.0 | 0.9% | `madvise` | libsystem_kernel.dylib |
| 9.0 | 0.9% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 8.0 | 0.8% | `method_t* getMethodFromListArray<method_list_t**>(method_list_t**, unsigned int, objc_selector*)` | libobjc.A.dylib |
| 8.0 | 0.8% | `lstat` | libsystem_kernel.dylib |
| 7.0 | 0.7% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 7.0 | 0.7% | `__mac_syscall` | libsystem_kernel.dylib |
| 7.0 | 0.7% | `load_categories_nolock(header_info*)::$_0::operator()(category_t* const*, bool) const` | libobjc.A.dylib |
| 7.0 | 0.7% | `__CFStringCreateImmutableFunnel3` | CoreFoundation |
| 6.0 | 0.6% | `dyld3::MachOFile::trieWalk(Diagnostics&, unsigned char const*, unsigned char const*, char const*)` | dyld |
| 6.0 | 0.6% | `_platform_strcmp_noMTE` | dyld |
| 6.0 | 0.6% | `objc_autoreleaseReturnValue` | libobjc.A.dylib |
| 6.0 | 0.6% | `cache_t::insert(objc_selector*, void (*)(), objc_object*)` | libobjc.A.dylib |
| 6.0 | 0.6% | `getattrlistbulk` | libsystem_kernel.dylib |
| 5.0 | 0.5% | `dyld3::MachOLoaded::findClosestSymbol(unsigned long long, char const**, unsigned long long*) const` | dyld |
| 5.0 | 0.5% | `lookUpImpOrForward` | libobjc.A.dylib |
| 5.0 | 0.5% | `_CFRetain` | CoreFoundation |

## Main thread — stack presence (weight of samples containing frame)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 883.0 | 83.7% | `start` | dyld |
| 839.0 | 79.5% | `specialized static UIApplicationDelegate.main()` | GuessWho |
| 839.0 | 79.5% | `UIApplicationMain` | UIKitCore |
| 839.0 | 79.5% | `0x1c4ccdcf8` | UIKitCore |
| 736.0 | 69.8% | `-[NSApplication run]` | AppKit |
| 736.0 | 69.8% | `NSApplicationMain` | AppKit |
| 736.0 | 69.8% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 736.0 | 69.8% | `UINSApplicationMain` | UIKitMacHelper |
| 704.0 | 66.7% | `_DPSNextEvent` | AppKit |
| 704.0 | 66.7% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 704.0 | 66.7% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 701.0 | 66.4% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 700.0 | 66.4% | `RunCurrentEventLoopInMode` | HIToolbox |
| 700.0 | 66.4% | `ReceiveNextEventCommon` | HIToolbox |
| 700.0 | 66.4% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 696.0 | 66.0% | `_CFRunLoopRunSpecificWithOptions` | CoreFoundation |
| 692.0 | 65.6% | `__CFRunLoopRun` | CoreFoundation |
| 507.0 | 48.1% | `_dispatch_client_callout` | libdispatch.dylib |
| 336.0 | 31.8% | `_dispatch_main_queue_callback_4CF` | libdispatch.dylib |
| 336.0 | 31.8% | `_dispatch_main_queue_drain` | libdispatch.dylib |
| 336.0 | 31.8% | `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__` | CoreFoundation |
| 336.0 | 31.8% | `_dispatch_main_queue_drain.cold.6` | libdispatch.dylib |
| 278.0 | 26.4% | `CA::Transaction::commit()` | QuartzCore |
| 269.0 | 25.5% | `CA::Context::commit_transaction(CA::Transaction*, double, double*)` | QuartzCore |
| 246.0 | 23.3% | `CA::Layer::update_if_needed_(CA::Transaction*, CA::LayerUpdateReason)` | QuartzCore |
| 246.0 | 23.3% | `CA::Layer::perform_update_(CA::Layer*, CALayer*, unsigned int, CA::LayerUpdateReason, CA::Transaction*)` | QuartzCore |
| 233.0 | 22.1% | `-[UIView(CALayerDelegate) layoutSublayersOfLayer:]` | UIKitCore |
| 207.0 | 19.6% | `0x1c4cd1d8c` | UIKitCore |
| 207.0 | 19.6% | `0x1c4cd2418` | UIKitCore |
| 201.0 | 19.1% | `__NSOQSchedule_f` | Foundation |

## All threads — top leaf symbols (base = total 7814 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 421.0 | 5.4% | `__open` | libsystem_kernel.dylib |
| 337.0 | 4.3% | `objc_msgSend` | libobjc.A.dylib |
| 317.0 | 4.1% | `__getattrlist` | libsystem_kernel.dylib |
| 244.0 | 3.1% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 187.0 | 2.4% | `start_wqthread` | libsystem_pthread.dylib |
| 144.0 | 1.8% | `getattrlistbulk` | libsystem_kernel.dylib |
| 133.0 | 1.7% | `_xzm_free` | libsystem_malloc.dylib |
| 122.0 | 1.6% | `__CF_IS_OBJC` | CoreFoundation |
| 107.0 | 1.4% | `_platform_memmove` | libsystem_platform.dylib |
| 93.0 | 1.2% | `kevent_id` | libsystem_kernel.dylib |
| 81.0 | 1.0% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 81.0 | 1.0% | `_platform_memset` | libsystem_platform.dylib |
| 75.0 | 1.0% | `read` | libsystem_kernel.dylib |
| 73.0 | 0.9% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 70.0 | 0.9% | `___CFBasicHashFindBucket_Linear` | CoreFoundation |
| 67.0 | 0.9% | `_getLastByteOfValueIncludingMarker` | Foundation |
| 67.0 | 0.9% | `stat` | libsystem_kernel.dylib |
| 62.0 | 0.8% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 55.0 | 0.7% | `__mac_syscall` | libsystem_kernel.dylib |
| 55.0 | 0.7% | `_CFRelease` | CoreFoundation |
| 55.0 | 0.7% | `objc_release` | libobjc.A.dylib |
| 50.0 | 0.6% | `__CFStringHash` | CoreFoundation |
| 50.0 | 0.6% | `__iopolicysys` | libsystem_kernel.dylib |
| 49.0 | 0.6% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 40.0 | 0.5% | `swift_release` | libswiftCore.dylib |
| 35.0 | 0.4% | `__CFStringCreateImmutableFunnel3` | CoreFoundation |
| 30.0 | 0.4% | `_getASCIIStringAtMarker` | Foundation |
| 30.0 | 0.4% | `semaphore_signal_trap` | libsystem_kernel.dylib |
| 29.0 | 0.4% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 29.0 | 0.4% | `-[NSPathStore2 characterAtIndex:]` | Foundation |

## App binaries (GuessWho*) — top leaf symbols, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 9.0 | 0.1% | `__swift_memcpy1_1` | GuessWhoSync |
| 8.0 | 0.1% | `<deduplicated_symbol>` | GuessWhoSync |
| 5.0 | 0.1% | `0x106359ca8` | GuessWhoSync |
| 5.0 | 0.1% | `static SidecarISO8601.fixedLayoutDate(from:)` | GuessWhoSync |
| 4.0 | 0.1% | `DYLD-STUB$$swift_bridgeObjectRelease` | GuessWhoSync |
| 3.0 | 0.0% | `specialized static SidecarISO8601.decimal(_:startingAt:count:)` | GuessWhoSync |
| 3.0 | 0.0% | `initializeWithCopy for Event` | GuessWhoSync |
| 3.0 | 0.0% | `specialized JSONValue.init(from:)` | GuessWhoSync |
| 3.0 | 0.0% | `specialized SidecarEnvelope.init(from:)` | GuessWhoSync |
| 3.0 | 0.0% | `0x1063e96d1` | GuessWhoSync |
| 3.0 | 0.0% | `SidecarCell.init(from:)` | GuessWhoSync |
| 2.0 | 0.0% | `partial apply for closure #1 in FileSystemSidecarStore.read(_:)` | GuessWhoSync |
| 2.0 | 0.0% | `static SidecarISO8601.date(from:)` | GuessWhoSync |
| 2.0 | 0.0% | `specialized static SidecarISO8601.gregorianDaysSince1970(year:month:day:)` | GuessWhoSync |
| 2.0 | 0.0% | `DYLD-STUB$$swift_bridgeObjectRetain` | GuessWhoSync |
| 2.0 | 0.0% | `DYLD-STUB$$objc_release_x8` | GuessWhoSync |
| 2.0 | 0.0% | `0x106359d59` | GuessWhoSync |
| 2.0 | 0.0% | `DYLD-STUB$$type metadata accessor for OS_dispatch_queue.AutoreleaseFrequency` | GuessWhoSync |
| 2.0 | 0.0% | `type metadata accessor for MapsPlace` | GuessWhoSync |
| 2.0 | 0.0% | `closure #1 in FileSystemSidecarStore.coordinatedRead(key:at:_:)` | GuessWhoSync |
| 2.0 | 0.0% | `destroy for Event` | GuessWhoSync |
| 2.0 | 0.0% | `DYLD-STUB$$type metadata accessor for URL` | GuessWhoSync |
| 2.0 | 0.0% | `FileSystemSidecarStore.fileURL(for:)` | GuessWhoSync |
| 2.0 | 0.0% | `destroy for SidecarCell` | GuessWhoSync |
| 1.0 | 0.0% | `_GLOBAL__sub_I_InstrProfilingRuntime.cpp` | GuessWhoSync |
| 1.0 | 0.0% | `static GuessWhoLog.bootstrap(processName:appGroupID:baseOverride:)` | GuessWho |
| 1.0 | 0.0% | `type metadata accessor for ContactsRepository` | GuessWhoSync |
| 1.0 | 0.0% | `type metadata accessor for PlaceholderViewController` | GuessWho |
| 1.0 | 0.0% | `ContactsRepository.group(localID:)` | GuessWhoSync |
| 1.0 | 0.0% | `thunk for @escaping @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |

## App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 5528.0 | 70.7% | `0x10644058b` | GuessWhoSync |
| 1508.0 | 19.3% | `protocol witness for SidecarStoreProtocol.read(_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 1502.0 | 19.2% | `specialized closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 1475.0 | 18.9% | `partial apply for specialized closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 1463.0 | 18.7% | `partial apply for closure #1 in CNContactStoreAdapter.fetchAll()` | GuessWhoSync |
| 1462.0 | 18.7% | `closure #1 in CNContactStoreAdapter.fetchAll()` | GuessWhoSync |
| 1393.0 | 17.8% | `FileSystemSidecarStore.read(_:)` | GuessWhoSync |
| 1241.0 | 15.9% | `<deduplicated_symbol>` | GuessWhoSync |
| 1129.0 | 14.4% | `closure #1 in FileSystemSidecarStore.runWithBusyHandling(key:operation:)` | GuessWhoSync |
| 1110.0 | 14.2% | `partial apply for closure #1 in FileSystemSidecarStore.coordinatedRead(key:at:_:)` | GuessWhoSync |
| 1070.0 | 13.7% | `closure #1 in FileSystemSidecarStore.coordinatedRead(key:at:_:)` | GuessWhoSync |
| 912.0 | 11.7% | `closure #1 in closure #1 in GuessWhoSync.allPlaces()` | GuessWhoSync |
| 912.0 | 11.7% | `PlaceCorpusCache.value(walkingCorpus:)` | GuessWhoSync |
| 910.0 | 11.6% | `closure #1 in GuessWhoSync.allPlaces()` | GuessWhoSync |
| 907.0 | 11.6% | `closure #1 in closure #1 in GuessWhoSync.eventsWindow(from:to:includeEventKit:)` | GuessWhoSync |
| 898.0 | 11.5% | `GuessWhoSync.eventsWindow(from:to:includeEventKit:)` | GuessWhoSync |
| 839.0 | 10.7% | `specialized static UIApplicationDelegate.main()` | GuessWho |
| 771.0 | 9.9% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 755.0 | 9.7% | `specialized SidecarEnvelope.init(from:)` | GuessWhoSync |
| 746.0 | 9.5% | `protocol witness for EventStoreProtocol.fetchEvents(in:) in conformance EKEventStoreAdapter` | GuessWhoSync |
| 635.0 | 8.1% | `protocol witness for Decodable.init(from:) in conformance SidecarCell` | GuessWhoSync |
| 634.0 | 8.1% | `SidecarCell.init(from:)` | GuessWhoSync |
| 572.0 | 7.3% | `FileSystemSidecarStore.allKeys()` | GuessWhoSync |
| 572.0 | 7.3% | `protocol witness for SidecarStoreProtocol.allKeys() in conformance FileSystemSidecarStore` | GuessWhoSync |
| 536.0 | 6.9% | `JSONValue.init(from:)` | GuessWhoSync |
| 535.0 | 6.8% | `specialized JSONValue.init(from:)` | GuessWhoSync |
| 519.0 | 6.6% | `FileSystemSidecarStore.fileURL(for:)` | GuessWhoSync |
| 437.0 | 5.6% | `closure #1 in closure #1 in GuessWhoSync.allContactTimestamps()` | GuessWhoSync |
| 434.0 | 5.6% | `GuessWhoSync.allContactTimestamps()` | GuessWhoSync |
| 430.0 | 5.5% | `implicit closure #1 in EKEventStoreAdapter.fetchEvents(in:)` | GuessWhoSync |

## Self weight by binary — all threads (top 25)

| CPU ms | % | Binary |
|---|---|---|
| 1667 | 21.3% | libsystem_kernel.dylib |
| 1355 | 17.3% | CoreFoundation |
| 1089 | 13.9% | libobjc.A.dylib |
| 829 | 10.6% | Foundation |
| 811 | 10.4% | libswiftCore.dylib |
| 463 | 5.9% | libsystem_malloc.dylib |
| 286 | 3.7% | libsystem_platform.dylib |
| 239 | 3.1% | libsystem_pthread.dylib |
| 127 | 1.6% | GuessWhoSync |
| 112 | 1.4% | UIKitCore |
| 97 | 1.2% | dyld |
| 93 | 1.2% | libdispatch.dylib |
| 80 | 1.0% | CoreData |
| 79 | 1.0% | EventKit |
| 72 | 0.9% | libxpc.dylib |
| 43 | 0.6% | CoreServicesInternal |
| 36 | 0.5% | CoreUI |
| 30 | 0.4% | libsystem_c.dylib |
| 28 | 0.4% | Contacts |
| 25 | 0.3% | libicucore.A.dylib |
| 22 | 0.3% | CarbonCore |
| 20 | 0.3% | libsystem_blocks.dylib |
| 20 | 0.3% | libcorecrypto.dylib |
| 18 | 0.2% | QuartzCore |
| 18 | 0.2% | CoreGraphics |

## Self weight by binary — main thread (top 20)

| CPU ms | % | Binary |
|---|---|---|
| 234 | 22.2% | libobjc.A.dylib |
| 183 | 17.3% | CoreFoundation |
| 113 | 10.7% | libsystem_kernel.dylib |
| 112 | 10.6% | UIKitCore |
| 61 | 5.8% | libswiftCore.dylib |
| 60 | 5.7% | dyld |
| 50 | 4.7% | libsystem_malloc.dylib |
| 38 | 3.6% | libsystem_platform.dylib |
| 36 | 3.4% | CoreUI |
| 34 | 3.2% | Foundation |
| 17 | 1.6% | AppKit |
| 17 | 1.6% | QuartzCore |
| 15 | 1.4% | CoreGraphics |
| 8 | 0.8% | libicucore.A.dylib |
| 6 | 0.6% | CoreText |
| 4 | 0.4% | GuessWhoSync |
| 4 | 0.4% | libsystem_pthread.dylib |
| 4 | 0.4% | UIFoundation |
| 4 | 0.4% | SwiftUICore |
| 4 | 0.4% | libFontParser.dylib |

## CPU by 5s bucket and binary (top 6 binaries per bucket)

- **0–5s** (total 3279 ms): CoreFoundation 679ms, libobjc.A.dylib 559ms, libsystem_kernel.dylib 548ms, Foundation 368ms, libswiftCore.dylib 198ms, libsystem_malloc.dylib 187ms
- **5–10s** (total 2056 ms): libsystem_kernel.dylib 428ms, CoreFoundation 361ms, libobjc.A.dylib 303ms, libswiftCore.dylib 241ms, Foundation 200ms, libsystem_malloc.dylib 127ms
- **10–15s** (total 1315 ms): libsystem_kernel.dylib 365ms, libswiftCore.dylib 208ms, CoreFoundation 161ms, Foundation 152ms, libobjc.A.dylib 118ms, libsystem_malloc.dylib 86ms
- **15–20s** (total 1060 ms): libsystem_kernel.dylib 304ms, libswiftCore.dylib 153ms, CoreFoundation 141ms, Foundation 102ms, libobjc.A.dylib 94ms, libsystem_malloc.dylib 56ms
- **20–25s** (total 104 ms): libsystem_kernel.dylib 22ms, libobjc.A.dylib 15ms, CoreFoundation 13ms, libswiftCore.dylib 11ms, UIKitCore 10ms, libsystem_malloc.dylib 7ms
