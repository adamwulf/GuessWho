# time-profile aggregation — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-0638a25a/repo/.build/traces/tp-after-b2.xml

rows: 3301, total sampled CPU: 3301 ms, main thread: 854 ms

## Threads by sampled CPU (top 12)

| Thread | CPU ms | % of total |
|---|---|---|
| GuessWho 0x29f3667 (GuessWho, pid: 48450) | 1231 | 37.3% |
| Main Thread 0x29f33a8 (GuessWho, pid: 48450) | 854 | 25.9% |
| GuessWho 0x29f364d (GuessWho, pid: 48450) | 298 | 9.0% |
| GuessWho 0x29f364b (GuessWho, pid: 48450) | 216 | 6.5% |
| GuessWho 0x29f3666 (GuessWho, pid: 48450) | 190 | 5.8% |
| GuessWho 0x29f366f (GuessWho, pid: 48450) | 162 | 4.9% |
| GuessWho 0x29f364c (GuessWho, pid: 48450) | 107 | 3.2% |
| GuessWho 0x29f3674 (GuessWho, pid: 48450) | 72 | 2.2% |
| GuessWho 0x29f366a (GuessWho, pid: 48450) | 69 | 2.1% |
| GuessWho 0x29f366e (GuessWho, pid: 48450) | 31 | 0.9% |
| GuessWho 0x29f3671 (GuessWho, pid: 48450) | 25 | 0.8% |
| GuessWho 0x29f366d (GuessWho, pid: 48450) | 20 | 0.6% |

## Main thread — top leaf symbols (self weight, base = main 854 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 54.0 | 6.3% | `objc_msgSend` | libobjc.A.dylib |
| 32.0 | 3.7% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 29.0 | 3.4% | `__getattrlist` | libsystem_kernel.dylib |
| 18.0 | 2.1% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 15.0 | 1.8% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 15.0 | 1.8% | `__CF_IS_OBJC` | CoreFoundation |
| 13.0 | 1.5% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 12.0 | 1.4% | `_platform_memmove` | libsystem_platform.dylib |
| 10.0 | 1.2% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 8.0 | 0.9% | `_CFRelease` | CoreFoundation |
| 8.0 | 0.9% | `objc_autoreleaseReturnValue` | libobjc.A.dylib |
| 8.0 | 0.9% | `__mac_syscall` | libsystem_kernel.dylib |
| 7.0 | 0.8% | `__CFStringCreateImmutableFunnel3` | CoreFoundation |
| 7.0 | 0.8% | `__CFStringHash` | CoreFoundation |
| 7.0 | 0.8% | `_xzm_free` | libsystem_malloc.dylib |
| 7.0 | 0.8% | `lstat` | libsystem_kernel.dylib |
| 6.0 | 0.7% | `__open` | libsystem_kernel.dylib |
| 6.0 | 0.7% | `objc_release` | libobjc.A.dylib |
| 6.0 | 0.7% | `_CFRuntimeCreateInstance` | CoreFoundation |
| 6.0 | 0.7% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 6.0 | 0.7% | `_platform_memset` | libsystem_platform.dylib |
| 6.0 | 0.7% | `__kdebug_trace64` | libsystem_kernel.dylib |
| 6.0 | 0.7% | `getattrlistbulk` | libsystem_kernel.dylib |
| 6.0 | 0.7% | `__CFStrConvertBytesToUnicode` | CoreFoundation |
| 6.0 | 0.7% | `faccessat` | libsystem_kernel.dylib |
| 5.0 | 0.6% | `dyld4::Loader::hasExportedSymbol(Diagnostics&, dyld4::RuntimeState&, char const*, dyld4::Loader::ExportedSy...` | dyld |
| 5.0 | 0.6% | `dyld4::Loader::applyCachePatchesTo(dyld4::RuntimeState&, dyld4::Loader const*, dyld4::DyldCacheDataConstLaz...` | dyld |
| 5.0 | 0.6% | `cache_getImp` | libobjc.A.dylib |
| 5.0 | 0.6% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 5.0 | 0.6% | `__CFStringEqual` | CoreFoundation |
| 5.0 | 0.6% | `-[__NSDictionaryM objectForKey:]` | CoreFoundation |
| 5.0 | 0.6% | `dyld4::PrebuiltLoader::contains(dyld4::RuntimeState&, void const*, void const**, unsigned long long*, unsig...` | dyld |
| 5.0 | 0.6% | `__CFStringChangeSizeMultiple` | CoreFoundation |
| 4.0 | 0.5% | `<deduplicated_symbol>` | dyld |
| 4.0 | 0.5% | `__open_nocancel` | libsystem_kernel.dylib |
| 4.0 | 0.5% | `-[__NSCFString isEqual:]` | CoreFoundation |
| 4.0 | 0.5% | `_CFStringGetCStringPtrInternal` | CoreFoundation |
| 4.0 | 0.5% | `_CFRetain` | CoreFoundation |
| 3.0 | 0.4% | `mach_o::UnsafeHeader::forEachLoadCommand(void (load_command const*, bool&) block_pointer) const` | dyld |
| 3.0 | 0.4% | `dyld3::MachOLoaded::findClosestSymbol(unsigned long long, char const**, unsigned long long*) const` | dyld |

## Main thread — stack presence (weight of samples containing frame)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 715.0 | 83.7% | `start` | dyld |
| 683.0 | 80.0% | `UIApplicationMain` | UIKitCore |
| 683.0 | 80.0% | `specialized static UIApplicationDelegate.main()` | GuessWho |
| 683.0 | 80.0% | `0x1c4ccdcf8` | UIKitCore |
| 616.0 | 72.1% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 616.0 | 72.1% | `-[NSApplication run]` | AppKit |
| 616.0 | 72.1% | `UINSApplicationMain` | UIKitMacHelper |
| 616.0 | 72.1% | `NSApplicationMain` | AppKit |
| 608.0 | 71.2% | `_DPSNextEvent` | AppKit |
| 608.0 | 71.2% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 608.0 | 71.2% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 604.0 | 70.7% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 604.0 | 70.7% | `ReceiveNextEventCommon` | HIToolbox |
| 604.0 | 70.7% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 602.0 | 70.5% | `RunCurrentEventLoopInMode` | HIToolbox |
| 599.0 | 70.1% | `_CFRunLoopRunSpecificWithOptions` | CoreFoundation |
| 597.0 | 69.9% | `__CFRunLoopRun` | CoreFoundation |
| 440.0 | 51.5% | `_dispatch_client_callout` | libdispatch.dylib |
| 295.0 | 34.5% | `_dispatch_main_queue_callback_4CF` | libdispatch.dylib |
| 295.0 | 34.5% | `_dispatch_main_queue_drain` | libdispatch.dylib |
| 295.0 | 34.5% | `_dispatch_main_queue_drain.cold.6` | libdispatch.dylib |
| 295.0 | 34.5% | `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__` | CoreFoundation |
| 237.0 | 27.8% | `CA::Transaction::commit()` | QuartzCore |
| 223.0 | 26.1% | `CA::Context::commit_transaction(CA::Transaction*, double, double*)` | QuartzCore |
| 211.0 | 24.7% | `CA::Layer::update_if_needed_(CA::Transaction*, CA::LayerUpdateReason)` | QuartzCore |
| 209.0 | 24.5% | `CA::Layer::perform_update_(CA::Layer*, CALayer*, unsigned int, CA::LayerUpdateReason, CA::Transaction*)` | QuartzCore |
| 197.0 | 23.1% | `-[UIView(CALayerDelegate) layoutSublayersOfLayer:]` | UIKitCore |
| 186.0 | 21.8% | `__NSOQSchedule_f` | Foundation |
| 186.0 | 21.8% | `-[NSOperation start]` | Foundation |
| 186.0 | 21.8% | `__NSOPERATIONQUEUE_IS_STARTING_AN_OPERATION__` | Foundation |
| 186.0 | 21.8% | `_dispatch_block_async_invoke2` | libdispatch.dylib |
| 184.0 | 21.5% | `-[NSBlockOperation main]` | Foundation |
| 184.0 | 21.5% | `__NSBLOCKOPERATION_IS_CALLING_OUT_TO_A_BLOCK__` | Foundation |
| 184.0 | 21.5% | `__NSOPERATION_IS_INVOKING_MAIN__` | Foundation |
| 176.0 | 20.6% | `0x1c4cd2418` | UIKitCore |
| 176.0 | 20.6% | `0x1c4cd1d8c` | UIKitCore |
| 157.0 | 18.4% | `_dispatch_lane_barrier_sync_invoke_and_complete` | libdispatch.dylib |
| 145.0 | 17.0% | `-[BRQueryItem initWithFPItem:]` | CloudDocs |
| 140.0 | 16.4% | `__CFRunLoopDoBlocks` | CoreFoundation |
| 139.0 | 16.3% | `__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__` | CoreFoundation |

## All threads — top leaf symbols (base = total 3301 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 156.0 | 4.7% | `objc_msgSend` | libobjc.A.dylib |
| 134.0 | 4.1% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 94.0 | 2.8% | `__getattrlist` | libsystem_kernel.dylib |
| 75.0 | 2.3% | `__CF_IS_OBJC` | CoreFoundation |
| 71.0 | 2.2% | `__open` | libsystem_kernel.dylib |
| 67.0 | 2.0% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 55.0 | 1.7% | `_getLastByteOfValueIncludingMarker` | Foundation |
| 51.0 | 1.5% | `_platform_memmove` | libsystem_platform.dylib |
| 46.0 | 1.4% | `_platform_memset` | libsystem_platform.dylib |
| 45.0 | 1.4% | `_xzm_free` | libsystem_malloc.dylib |
| 43.0 | 1.3% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 32.0 | 1.0% | `stat` | libsystem_kernel.dylib |
| 28.0 | 0.8% | `___CFBasicHashFindBucket_Linear` | CoreFoundation |
| 28.0 | 0.8% | `__CFStringHash` | CoreFoundation |
| 28.0 | 0.8% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 27.0 | 0.8% | `_CFRelease` | CoreFoundation |
| 26.0 | 0.8% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 24.0 | 0.7% | `_getReferenceAtMarker` | Foundation |
| 24.0 | 0.7% | `getattrlistbulk` | libsystem_kernel.dylib |
| 23.0 | 0.7% | `__CFStringCreateImmutableFunnel3` | CoreFoundation |
| 23.0 | 0.7% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 22.0 | 0.7% | `__CFBasicHashDrain` | CoreFoundation |
| 20.0 | 0.6% | `objc_release` | libobjc.A.dylib |
| 19.0 | 0.6% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 18.0 | 0.5% | `_getASCIIStringAtMarker` | Foundation |
| 17.0 | 0.5% | `_iterateDictionaryKeysAndValues` | Foundation |
| 14.0 | 0.4% | `objc_retain` | libobjc.A.dylib |
| 14.0 | 0.4% | `_free` | libsystem_malloc.dylib |
| 14.0 | 0.4% | `list_array_tt<unsigned long, protocol_list_t, RawPtr>::iteratorImpl<false>::operator++()` | libobjc.A.dylib |
| 13.0 | 0.4% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 13.0 | 0.4% | `objc_autoreleaseReturnValue` | libobjc.A.dylib |
| 13.0 | 0.4% | `_getIntAtMarker` | Foundation |
| 13.0 | 0.4% | `__mac_syscall` | libsystem_kernel.dylib |
| 12.0 | 0.4% | `bool objc::DenseMapBase<objc::DenseMap<DisguisedPtr<objc_object>, objc::DenseMap<void const*, objc::ObjcAss...` | libobjc.A.dylib |
| 12.0 | 0.4% | `protocol_conformsToProtocol_nolock(protocol_t*, protocol_t*)` | libobjc.A.dylib |
| 11.0 | 0.3% | `read` | libsystem_kernel.dylib |
| 11.0 | 0.3% | `-[__NSCFString isEqual:]` | CoreFoundation |
| 11.0 | 0.3% | `__CFStringEqual` | CoreFoundation |
| 11.0 | 0.3% | `___NSXPCSerializationCreateObjectInDictionaryForKey_block_invoke` | Foundation |
| 11.0 | 0.3% | `__CFBasicHashAddValue` | CoreFoundation |

## App binaries (GuessWho*) — top leaf symbols, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 4.0 | 0.1% | `0x106738f74` | GuessWhoSync |
| 2.0 | 0.1% | `SidecarCell.init(from:)` | GuessWhoSync |
| 2.0 | 0.1% | `<deduplicated_symbol>` | GuessWhoSync |
| 2.0 | 0.1% | `specialized _NativeDictionary._copyOrMoveAndResize(capacity:moveElements:)` | GuessWhoSync |
| 1.0 | 0.0% | `GuessWhoAppDelegate.init()` | GuessWho |
| 1.0 | 0.0% | `type metadata accessor for EventSortOrder` | GuessWhoSync |
| 1.0 | 0.0% | `type metadata accessor for MCPAuditLog` | GuessWhoSync |
| 1.0 | 0.0% | `FileSystemSidecarStore.listKeys(in:kind:requestDownloads:)` | GuessWhoSync |
| 1.0 | 0.0% | `0x106738fa1` | GuessWhoSync |
| 1.0 | 0.0% | `DYLD-STUB$$swift_bridgeObjectRetain` | GuessWhoSync |
| 1.0 | 0.0% | `destroy for MapsPlace` | GuessWhoSync |
| 1.0 | 0.0% | `outlined assign with take of Date?` | GuessWhoSync |
| 1.0 | 0.0% | `__swift_noop_void_return` | GuessWhoSync |
| 1.0 | 0.0% | `0x10678ac71` | GuessWhoSync |
| 1.0 | 0.0% | `DYLD-STUB$$type metadata accessor for Date` | GuessWhoSync |
| 1.0 | 0.0% | `type metadata accessor for Event` | GuessWhoSync |
| 1.0 | 0.0% | `specialized Set.insert(_:)` | GuessWhoSync |
| 1.0 | 0.0% | `DYLD-STUB$$swift_bridgeObjectRelease` | GuessWhoSync |
| 1.0 | 0.0% | `BusyOperationState.__deallocating_deinit` | GuessWhoSync |
| 1.0 | 0.0% | `static SidecarISO8601.date(from:)` | GuessWhoSync |
| 1.0 | 0.0% | `specialized GuessWhoSync.liveEventKitID(envelope:)` | GuessWhoSync |
| 1.0 | 0.0% | `0x1067086f9` | GuessWhoSync |
| 1.0 | 0.0% | `0x10685bced` | GuessWhoSync |
| 1.0 | 0.0% | `initializeWithCopy for Event` | GuessWhoSync |
| 1.0 | 0.0% | `specialized static SidecarISO8601.decimal(_:startingAt:count:)` | GuessWhoSync |
| 1.0 | 0.0% | `specialized static SidecarISO8601.gregorianDaysSince1970(year:month:day:)` | GuessWhoSync |
| 1.0 | 0.0% | `protocol witness for static Equatable.== infix(_:_:) in conformance Int` | GuessWhoSync |
| 1.0 | 0.0% | `protocol witness for CodingKey.stringValue.getter in conformance SidecarCell.CodingKeys` | GuessWhoSync |
| 1.0 | 0.0% | `static CNContactStoreAdapter.toContact(_:)` | GuessWhoSync |
| 1.0 | 0.0% | `DYLD-STUB$$objc_retainAutoreleasedReturnValue` | GuessWhoSync |
| 1.0 | 0.0% | `0x10673906d` | GuessWhoSync |

## App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 2054.0 | 62.2% | `0x10683092f` | GuessWhoSync |
| 1214.0 | 36.8% | `specialized closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 1194.0 | 36.2% | `partial apply for specialized closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 1185.0 | 35.9% | `partial apply for closure #1 in closure #1 in CNContactStoreAdapter.fetchAll()` | GuessWhoSync |
| 1185.0 | 35.9% | `closure #1 in CNContactStoreAdapter.init(store:)` | GuessWhoSync |
| 1185.0 | 35.9% | `closure #1 in closure #1 in CNContactStoreAdapter.fetchAll()` | GuessWhoSync |
| 1184.0 | 35.9% | `static CNContactStoreAdapter.enumerateAllContacts(store:keys:)` | GuessWhoSync |
| 683.0 | 20.7% | `specialized static UIApplicationDelegate.main()` | GuessWho |
| 316.0 | 9.6% | `closure #1 in closure #1 in GuessWhoSync.eventsWindow(from:to:includeEventKit:)` | GuessWhoSync |
| 314.0 | 9.5% | `GuessWhoSync.eventsWindow(from:to:includeEventKit:)` | GuessWhoSync |
| 264.0 | 8.0% | `<deduplicated_symbol>` | GuessWhoSync |
| 254.0 | 7.7% | `EKEventStoreAdapter.runUnderlyingWindowFetch(in:)` | GuessWhoSync |
| 254.0 | 7.7% | `EKEventStoreAdapter.fetchEvents(in:)` | GuessWhoSync |
| 254.0 | 7.7% | `closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 254.0 | 7.7% | `closure #1 in EKEventStoreAdapter.fetchEvents(in:)` | GuessWhoSync |
| 254.0 | 7.7% | `protocol witness for EventStoreProtocol.fetchEvents(in:) in conformance EKEventStoreAdapter` | GuessWhoSync |
| 254.0 | 7.7% | `closure #1 in EventWindowFetchCoordinator.fetch(interval:operation:)` | GuessWhoSync |
| 245.0 | 7.4% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 234.0 | 7.1% | `specialized FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 232.0 | 7.0% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 227.0 | 6.9% | `specialized FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 226.0 | 6.8% | `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)` | GuessWhoSync |
| 223.0 | 6.8% | `specialized SidecarEnvelope.init(from:)` | GuessWhoSync |
| 223.0 | 6.8% | `ProductionSidecarFileCoordinator.coordinateReading(at:_:)` | GuessWhoSync |
| 220.0 | 6.7% | `0x10672327b` | GuessWhoSync |
| 214.0 | 6.5% | `thunk for @escaping @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |
| 206.0 | 6.2% | `partial apply for closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |
| 204.0 | 6.2% | `partial apply for closure #1 in FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 204.0 | 6.2% | `closure #2 in closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |
| 201.0 | 6.1% | `SidecarCell.init(from:)` | GuessWhoSync |
| 200.0 | 6.1% | `protocol witness for Decodable.init(from:) in conformance SidecarCell` | GuessWhoSync |
| 200.0 | 6.1% | `implicit closure #1 in static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 190.0 | 5.8% | `closure #1 in closure #1 in GuessWhoSync.allPlaces()` | GuessWhoSync |
| 190.0 | 5.8% | `closure #1 in GuessWhoSync.allPlaces()` | GuessWhoSync |
| 186.0 | 5.6% | `static EKEventStoreAdapter.toEvent(_:)` | GuessWhoSync |
| 179.0 | 5.4% | `JSONValue.init(from:)` | GuessWhoSync |
| 179.0 | 5.4% | `specialized JSONValue.init(from:)` | GuessWhoSync |
| 110.0 | 3.3% | `<deduplicated_symbol>` | GuessWho |
| 100.0 | 3.0% | `protocol witness for SidecarStoreProtocol.allKeys() in conformance FileSystemSidecarStore` | GuessWhoSync |
| 100.0 | 3.0% | `FileSystemSidecarStore.allKeys()` | GuessWhoSync |

## Self weight by binary — all threads (top 25)

| CPU ms | % | Binary |
|---|---|---|
| 756 | 22.9% | CoreFoundation |
| 581 | 17.6% | libobjc.A.dylib |
| 477 | 14.5% | libsystem_kernel.dylib |
| 351 | 10.6% | Foundation |
| 247 | 7.5% | libswiftCore.dylib |
| 191 | 5.8% | libsystem_malloc.dylib |
| 155 | 4.7% | libsystem_platform.dylib |
| 83 | 2.5% | UIKitCore |
| 76 | 2.3% | CoreData |
| 69 | 2.1% | dyld |
| 36 | 1.1% | GuessWhoSync |
| 31 | 0.9% | libdispatch.dylib |
| 25 | 0.8% | libsystem_pthread.dylib |
| 21 | 0.6% | Contacts |
| 19 | 0.6% | EventKit |
| 17 | 0.5% | QuartzCore |
| 15 | 0.5% | CoreGraphics |
| 14 | 0.4% | libxpc.dylib |
| 11 | 0.3% | libicucore.A.dylib |
| 11 | 0.3% | libsystem_c.dylib |
| 11 | 0.3% | libdyld.dylib |
| 10 | 0.3% | libsystem_blocks.dylib |
| 9 | 0.3% | CoreUI |
| 8 | 0.2% | CoreServicesInternal |
| 7 | 0.2% | AppKit |

## Self weight by binary — main thread (top 20)

| CPU ms | % | Binary |
|---|---|---|
| 184 | 21.5% | libobjc.A.dylib |
| 178 | 20.8% | CoreFoundation |
| 113 | 13.2% | libsystem_kernel.dylib |
| 83 | 9.7% | UIKitCore |
| 49 | 5.7% | dyld |
| 46 | 5.4% | libswiftCore.dylib |
| 38 | 4.4% | libsystem_malloc.dylib |
| 24 | 2.8% | Foundation |
| 23 | 2.7% | libsystem_platform.dylib |
| 17 | 2.0% | QuartzCore |
| 14 | 1.6% | CoreGraphics |
| 9 | 1.1% | CoreUI |
| 7 | 0.8% | AppKit |
| 7 | 0.8% | CoreAutoLayout |
| 6 | 0.7% | libsystem_pthread.dylib |
| 4 | 0.5% | GuessWhoSync |
| 4 | 0.5% | libsystem_c.dylib |
| 4 | 0.5% | libicucore.A.dylib |
| 4 | 0.5% | libdyld.dylib |
| 4 | 0.5% | SwiftUICore |

## CPU by 5s bucket and binary (top 6 binaries per bucket)

- **0–5s** (total 2868 ms): CoreFoundation 645ms, libobjc.A.dylib 498ms, libsystem_kernel.dylib 439ms, Foundation 329ms, libswiftCore.dylib 225ms, libsystem_malloc.dylib 172ms
- **5–10s** (total 416 ms): CoreFoundation 110ms, libobjc.A.dylib 81ms, libsystem_kernel.dylib 37ms, libsystem_platform.dylib 26ms, CoreData 24ms, Foundation 22ms
- **10–15s** (total 3 ms): libswiftCore.dylib 1ms, libsystem_kernel.dylib 1ms, libsystem_platform.dylib 1ms
- **15–20s** (total 14 ms): libsystem_platform.dylib 9ms, libobjc.A.dylib 2ms, libsystem_malloc.dylib 1ms, libsystem_c.dylib 1ms, CoreFoundation 1ms
