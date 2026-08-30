# Windowed time-profile aggregation — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-c17968b1/repo/.build/traces/tp-1.xml

## launch [0.00s – 17.94s]

total sampled CPU: 5350 ms, main thread: 1195 ms

### Main thread — top leaf symbols (base 1195 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 76.0 | 6.4% | `objc_msgSend` | libobjc.A.dylib |
| 31.0 | 2.6% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 27.0 | 2.3% | `__CF_IS_OBJC` | CoreFoundation |
| 22.0 | 1.8% | `__getattrlist` | libsystem_kernel.dylib |
| 16.0 | 1.3% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 16.0 | 1.3% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 15.0 | 1.3% | `__CFStringCreateImmutableFunnel3` | CoreFoundation |
| 14.0 | 1.2% | `_CFRelease` | CoreFoundation |
| 13.0 | 1.1% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 13.0 | 1.1% | `_CFStringGetCStringPtrInternal` | CoreFoundation |
| 12.0 | 1.0% | `dyld3::MachOFile::trieWalk(Diagnostics&, unsigned char const*, unsigned char const*, char const*)` | dyld |
| 12.0 | 1.0% | `-[CUIStructuredThemeStore lookupAssetForKey:]` | CoreUI |
| 12.0 | 1.0% | `_CFRetain` | CoreFoundation |
| 11.0 | 0.9% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 10.0 | 0.8% | `__mac_syscall` | libsystem_kernel.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 879.0 | 73.6% | `start` | dyld |
| 817.0 | 68.4% | `UIApplicationMain` | UIKitCore |
| 817.0 | 68.4% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 817.0 | 68.4% | `0x1c4ccdcf8` | UIKitCore |
| 817.0 | 68.4% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 817.0 | 68.4% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 744.0 | 62.3% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 744.0 | 62.3% | `NSApplicationMain` | AppKit |
| 744.0 | 62.3% | `-[NSApplication run]` | AppKit |
| 744.0 | 62.3% | `UINSApplicationMain` | UIKitMacHelper |
| 729.0 | 61.0% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 729.0 | 61.0% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 729.0 | 61.0% | `_DPSNextEvent` | AppKit |
| 724.0 | 60.6% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 724.0 | 60.6% | `ReceiveNextEventCommon` | HIToolbox |

### All threads — top leaf symbols (base 5350 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 218.0 | 4.1% | `objc_msgSend` | libobjc.A.dylib |
| 194.0 | 3.6% | `__getattrlist` | libsystem_kernel.dylib |
| 143.0 | 2.7% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 133.0 | 2.5% | `__open` | libsystem_kernel.dylib |
| 96.0 | 1.8% | `_xzm_free` | libsystem_malloc.dylib |
| 88.0 | 1.6% | `__CF_IS_OBJC` | CoreFoundation |
| 74.0 | 1.4% | `getattrlistbulk` | libsystem_kernel.dylib |
| 61.0 | 1.1% | `_platform_memmove` | libsystem_platform.dylib |
| 59.0 | 1.1% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 54.0 | 1.0% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 52.0 | 1.0% | `_getLastByteOfValueIncludingMarker` | Foundation |
| 49.0 | 0.9% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 45.0 | 0.8% | `stat` | libsystem_kernel.dylib |
| 44.0 | 0.8% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 43.0 | 0.8% | `___CFBasicHashFindBucket_Linear` | CoreFoundation |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 3704.0 | 69.2% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 1188.0 | 22.2% | `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 1153.0 | 21.6% | `static CNContactStoreAdapter.enumerateAllContacts(store:keys:)` | GuessWhoSync |
| 1153.0 | 21.6% | `closure #1 in CNContactStoreAdapter.init(store:)` | GuessWhoSync |
| 1153.0 | 21.6% | `partial apply for closure #1 in CNContactStoreAdapter.init(store:)` | GuessWhoSync |
| 1153.0 | 21.6% | `partial apply for closure #1 in closure #1 in CNContactStoreAdapter.fetchAll()` | GuessWhoSync |
| 1153.0 | 21.6% | `closure #1 in closure #1 in CNContactStoreAdapter.fetchAll()` | GuessWhoSync |
| 1148.0 | 21.5% | `Result<>.init(catching:)` | GuessWhoSync |
| 1037.0 | 19.4% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 1037.0 | 19.4% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 1037.0 | 19.4% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 1008.0 | 18.8% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 943.0 | 17.6% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 902.0 | 16.9% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 902.0 | 16.9% | `protocol witness for Decodable.init(from:) in conformance SidecarEnvelope` | GuessWhoSync |

## contact-A [17.94s – 26.04s]

total sampled CPU: 3177 ms, main thread: 364 ms

### Main thread — top leaf symbols (base 364 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 23.0 | 6.3% | `objc_msgSend` | libobjc.A.dylib |
| 8.0 | 2.2% | `_platform_memmove` | libsystem_platform.dylib |
| 6.0 | 1.6% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 6.0 | 1.6% | `swift_retain` | libswiftCore.dylib |
| 4.0 | 1.1% | `swift::_checkGenericRequirements(__swift::__runtime::llvm::ArrayRef<swift::GenericParamDescriptor>, __swift...` | libswiftCore.dylib |
| 4.0 | 1.1% | `__CFStringHash` | CoreFoundation |
| 4.0 | 1.1% | `_xzm_free` | libsystem_malloc.dylib |
| 3.0 | 0.8% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 3.0 | 0.8% | `swift::_getWitnessTable(swift::TargetProtocolConformanceDescriptor<swift::InProcess> const*, swift::TargetM...` | libswiftCore.dylib |
| 3.0 | 0.8% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 3.0 | 0.8% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 3.0 | 0.8% | `swift_release` | libswiftCore.dylib |
| 3.0 | 0.8% | `<deduplicated_symbol>` | libswiftCore.dylib |
| 3.0 | 0.8% | `Hasher.combine(bytes:)` | libswiftCore.dylib |
| 3.0 | 0.8% | `swift_bridgeObjectRetain` | libswiftCore.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 263.0 | 72.3% | `start` | dyld |
| 263.0 | 72.3% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 263.0 | 72.3% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 263.0 | 72.3% | `_CFRunLoopRunSpecificWithOptions` | CoreFoundation |
| 263.0 | 72.3% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 263.0 | 72.3% | `0x1c4ccdcf8` | UIKitCore |
| 263.0 | 72.3% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 263.0 | 72.3% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 263.0 | 72.3% | `ReceiveNextEventCommon` | HIToolbox |
| 263.0 | 72.3% | `NSApplicationMain` | AppKit |
| 263.0 | 72.3% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 263.0 | 72.3% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 263.0 | 72.3% | `RunCurrentEventLoopInMode` | HIToolbox |
| 263.0 | 72.3% | `-[NSApplication run]` | AppKit |
| 263.0 | 72.3% | `UIApplicationMain` | UIKitCore |

### All threads — top leaf symbols (base 3177 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 166.0 | 5.2% | `objc_msgSend` | libobjc.A.dylib |
| 109.0 | 3.4% | `objc_release` | libobjc.A.dylib |
| 89.0 | 2.8% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 89.0 | 2.8% | `-[EKObjectID isEqual:]` | EventKit |
| 84.0 | 2.6% | `__getattrlist` | libsystem_kernel.dylib |
| 80.0 | 2.5% | `objc_retain` | libobjc.A.dylib |
| 76.0 | 2.4% | `__open` | libsystem_kernel.dylib |
| 57.0 | 1.8% | `_xzm_free` | libsystem_malloc.dylib |
| 50.0 | 1.6% | `object_getClass` | libobjc.A.dylib |
| 34.0 | 1.1% | `getattrlistbulk` | libsystem_kernel.dylib |
| 34.0 | 1.1% | `__CFStringHash` | CoreFoundation |
| 31.0 | 1.0% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 30.0 | 0.9% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 30.0 | 0.9% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 29.0 | 0.9% | `_platform_memmove` | libsystem_platform.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 2710.0 | 85.3% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 1439.0 | 45.3% | `protocol witness for EventStoreProtocol.eventsWithAttendee(matchingEmails:orLocations:in:limit:) in conform...` | GuessWhoSync |
| 1439.0 | 45.3% | `closure #1 in closure #1 in GuessWhoSync.recentEvents(matchingEmails:matchingLocations:asOf:limit:)` | GuessWhoSync |
| 1439.0 | 45.3% | `EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)` | GuessWhoSync |
| 459.0 | 14.4% | `Result<>.init(catching:)` | GuessWhoSync |
| 411.0 | 12.9% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 411.0 | 12.9% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 411.0 | 12.9% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 407.0 | 12.8% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 402.0 | 12.7% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 388.0 | 12.2% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 388.0 | 12.2% | `protocol witness for Decodable.init(from:) in conformance SidecarEnvelope` | GuessWhoSync |
| 380.0 | 12.0% | `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)` | GuessWhoSync |
| 375.0 | 11.8% | `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance ProductionSidecarFileC...` | GuessWhoSync |
| 375.0 | 11.8% | `ProductionSidecarFileCoordinator.coordinateReading(at:_:)` | GuessWhoSync |

## contact-B [26.04s – 34.07s]

total sampled CPU: 2934 ms, main thread: 474 ms

### Main thread — top leaf symbols (base 474 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 44.0 | 9.3% | `objc_msgSend` | libobjc.A.dylib |
| 8.0 | 1.7% | `<deduplicated_symbol>` | SwiftUICore |
| 8.0 | 1.7% | `_xzm_free` | libsystem_malloc.dylib |
| 8.0 | 1.7% | `_platform_memmove` | libsystem_platform.dylib |
| 7.0 | 1.5% | `swift_retain` | libswiftCore.dylib |
| 7.0 | 1.5% | `_CFRetain` | CoreFoundation |
| 6.0 | 1.3% | `swift_release` | libswiftCore.dylib |
| 5.0 | 1.1% | `getCache(swift::TargetTypeContextDescriptor<swift::InProcess> const&)` | libswiftCore.dylib |
| 5.0 | 1.1% | `objc_retain` | libobjc.A.dylib |
| 5.0 | 1.1% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 5.0 | 1.1% | `_CFRelease` | CoreFoundation |
| 4.0 | 0.8% | `DYLD-STUB$$objc_retainAutoreleasedReturnValue` | UIKitCore |
| 4.0 | 0.8% | `__CFStringHash` | CoreFoundation |
| 4.0 | 0.8% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 4.0 | 0.8% | `_platform_memset` | libsystem_platform.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 303.0 | 63.9% | `start` | dyld |
| 303.0 | 63.9% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 303.0 | 63.9% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 303.0 | 63.9% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 303.0 | 63.9% | `0x1c4ccdcf8` | UIKitCore |
| 303.0 | 63.9% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 303.0 | 63.9% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 303.0 | 63.9% | `ReceiveNextEventCommon` | HIToolbox |
| 303.0 | 63.9% | `NSApplicationMain` | AppKit |
| 303.0 | 63.9% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 303.0 | 63.9% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 303.0 | 63.9% | `RunCurrentEventLoopInMode` | HIToolbox |
| 303.0 | 63.9% | `-[NSApplication run]` | AppKit |
| 303.0 | 63.9% | `UIApplicationMain` | UIKitCore |
| 303.0 | 63.9% | `UINSApplicationMain` | UIKitMacHelper |

### All threads — top leaf symbols (base 2934 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 152.0 | 5.2% | `objc_msgSend` | libobjc.A.dylib |
| 124.0 | 4.2% | `__open` | libsystem_kernel.dylib |
| 102.0 | 3.5% | `__getattrlist` | libsystem_kernel.dylib |
| 59.0 | 2.0% | `_xzm_free` | libsystem_malloc.dylib |
| 43.0 | 1.5% | `getattrlistbulk` | libsystem_kernel.dylib |
| 40.0 | 1.4% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 35.0 | 1.2% | `stat` | libsystem_kernel.dylib |
| 34.0 | 1.2% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 33.0 | 1.1% | `swift_release` | libswiftCore.dylib |
| 31.0 | 1.1% | `_platform_memmove` | libsystem_platform.dylib |
| 31.0 | 1.1% | `objc_release` | libobjc.A.dylib |
| 29.0 | 1.0% | `getCache(swift::TargetTypeContextDescriptor<swift::InProcess> const&)` | libswiftCore.dylib |
| 25.0 | 0.9% | `_free` | libsystem_malloc.dylib |
| 24.0 | 0.8% | `swift_retain` | libswiftCore.dylib |
| 23.0 | 0.8% | `_CFRelease` | CoreFoundation |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 2324.0 | 79.2% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 773.0 | 26.3% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 773.0 | 26.3% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 773.0 | 26.3% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 757.0 | 25.8% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 726.0 | 24.7% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 691.0 | 23.6% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 691.0 | 23.6% | `protocol witness for Decodable.init(from:) in conformance SidecarEnvelope` | GuessWhoSync |
| 672.0 | 22.9% | `Result<>.init(catching:)` | GuessWhoSync |
| 670.0 | 22.8% | `closure #1 in FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 670.0 | 22.8% | `partial apply for closure #1 in FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 666.0 | 22.7% | `GuessWhoSync.walkSidecarCorpus(kinds:_:)` | GuessWhoSync |
| 627.0 | 21.4% | `protocol witness for EventStoreProtocol.eventsWithAttendee(matchingEmails:orLocations:in:limit:) in conform...` | GuessWhoSync |
| 627.0 | 21.4% | `closure #1 in closure #1 in GuessWhoSync.recentEvents(matchingEmails:matchingLocations:asOf:limit:)` | GuessWhoSync |
| 627.0 | 21.4% | `EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)` | GuessWhoSync |

## organization [34.07s – 40.09s]

total sampled CPU: 2481 ms, main thread: 674 ms

### Main thread — top leaf symbols (base 674 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 29.0 | 4.3% | `objc_msgSend` | libobjc.A.dylib |
| 12.0 | 1.8% | `_xzm_free` | libsystem_malloc.dylib |
| 11.0 | 1.6% | `swift_release` | libswiftCore.dylib |
| 10.0 | 1.5% | `_platform_memmove` | libsystem_platform.dylib |
| 10.0 | 1.5% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 8.0 | 1.2% | `_platform_memset` | libsystem_platform.dylib |
| 7.0 | 1.0% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 7.0 | 1.0% | `swift_bridgeObjectRelease` | libswiftCore.dylib |
| 7.0 | 1.0% | `swift_bridgeObjectRetain` | libswiftCore.dylib |
| 6.0 | 0.9% | `objc_retain` | libobjc.A.dylib |
| 6.0 | 0.9% | `kevent_id` | libsystem_kernel.dylib |
| 6.0 | 0.9% | `_CFRelease` | CoreFoundation |
| 5.0 | 0.7% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 4.0 | 0.6% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 4.0 | 0.6% | `<deduplicated_symbol>` | SwiftUICore |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 558.0 | 82.8% | `start` | dyld |
| 558.0 | 82.8% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 558.0 | 82.8% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 558.0 | 82.8% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 558.0 | 82.8% | `0x1c4ccdcf8` | UIKitCore |
| 558.0 | 82.8% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 558.0 | 82.8% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 558.0 | 82.8% | `ReceiveNextEventCommon` | HIToolbox |
| 558.0 | 82.8% | `NSApplicationMain` | AppKit |
| 558.0 | 82.8% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 558.0 | 82.8% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 558.0 | 82.8% | `-[NSApplication run]` | AppKit |
| 558.0 | 82.8% | `UIApplicationMain` | UIKitCore |
| 558.0 | 82.8% | `UINSApplicationMain` | UIKitMacHelper |
| 558.0 | 82.8% | `_DPSNextEvent` | AppKit |

### All threads — top leaf symbols (base 2481 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 140.0 | 5.6% | `objc_msgSend` | libobjc.A.dylib |
| 69.0 | 2.8% | `__open` | libsystem_kernel.dylib |
| 50.0 | 2.0% | `_xzm_free` | libsystem_malloc.dylib |
| 49.0 | 2.0% | `__open_nocancel` | libsystem_kernel.dylib |
| 38.0 | 1.5% | `__getattrlist` | libsystem_kernel.dylib |
| 36.0 | 1.5% | `objc_release` | libobjc.A.dylib |
| 35.0 | 1.4% | `__getdirentries64` | libsystem_kernel.dylib |
| 34.0 | 1.4% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 29.0 | 1.2% | `_platform_memmove` | libsystem_platform.dylib |
| 27.0 | 1.1% | `__CF_IS_OBJC` | CoreFoundation |
| 26.0 | 1.0% | `__CFStringHash` | CoreFoundation |
| 24.0 | 1.0% | `stat` | libsystem_kernel.dylib |
| 23.0 | 0.9% | `objc_retain` | libobjc.A.dylib |
| 23.0 | 0.9% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 22.0 | 0.9% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 1398.0 | 56.3% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 644.0 | 26.0% | `protocol witness for EventStoreProtocol.eventsWithAttendee(matchingEmails:orLocations:in:limit:) in conform...` | GuessWhoSync |
| 644.0 | 26.0% | `closure #1 in closure #1 in GuessWhoSync.recentEvents(matchingEmails:matchingLocations:asOf:limit:)` | GuessWhoSync |
| 644.0 | 26.0% | `EKEventStoreAdapter.eventsWithAttendee(matchingEmails:orLocations:in:limit:)` | GuessWhoSync |
| 558.0 | 22.5% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 558.0 | 22.5% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 558.0 | 22.5% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 336.0 | 13.5% | `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)` | GuessWhoSync |
| 194.0 | 7.8% | `partial apply for closure #1 in CNContactStoreAdapter.save(_:)` | GuessWhoSync |
| 194.0 | 7.8% | `closure #1 in CNContactStoreAdapter.save(_:)` | GuessWhoSync |
| 177.0 | 7.1% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 177.0 | 7.1% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 177.0 | 7.1% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 169.0 | 6.8% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 168.0 | 6.8% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |

## event [40.09s – 46.14s]

total sampled CPU: 1937 ms, main thread: 552 ms

### Main thread — top leaf symbols (base 552 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 67.0 | 12.1% | `_DDScannerHandleState` | DataDetectorsCore |
| 17.0 | 3.1% | `objc_msgSend` | libobjc.A.dylib |
| 17.0 | 3.1% | `computeLexemsAtPosition` | DataDetectorsCore |
| 15.0 | 2.7% | `processToken` | DataDetectorsCore |
| 12.0 | 2.2% | `__munmap` | libsystem_kernel.dylib |
| 9.0 | 1.6% | `DDLexerDeterministicScan` | DataDetectorsCore |
| 7.0 | 1.3% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 7.0 | 1.3% | `__btrie_find_common_prefix` | libgermantok.dylib |
| 6.0 | 1.1% | `_CFRelease` | CoreFoundation |
| 6.0 | 1.1% | `objc_autoreleaseReturnValue` | libobjc.A.dylib |
| 6.0 | 1.1% | `__open` | libsystem_kernel.dylib |
| 5.0 | 0.9% | `swift_retain` | libswiftCore.dylib |
| 5.0 | 0.9% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 5.0 | 0.9% | `_platform_memset` | libsystem_platform.dylib |
| 5.0 | 0.9% | `stat` | libsystem_kernel.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 297.0 | 53.8% | `completeTaskWithClosure(swift::AsyncContext*, swift::SwiftError*)` | libswift_Concurrency.dylib |
| 252.0 | 45.7% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 252.0 | 45.7% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 252.0 | 45.7% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 252.0 | 45.7% | `0x1c4ccdcf8` | UIKitCore |
| 252.0 | 45.7% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 252.0 | 45.7% | `ReceiveNextEventCommon` | HIToolbox |
| 252.0 | 45.7% | `NSApplicationMain` | AppKit |
| 252.0 | 45.7% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 252.0 | 45.7% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 252.0 | 45.7% | `-[NSApplication run]` | AppKit |
| 252.0 | 45.7% | `UINSApplicationMain` | UIKitMacHelper |
| 252.0 | 45.7% | `UIApplicationMain` | UIKitCore |
| 252.0 | 45.7% | `_DPSNextEvent` | AppKit |
| 252.0 | 45.7% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |

### All threads — top leaf symbols (base 1937 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 104.0 | 5.4% | `__getattrlist` | libsystem_kernel.dylib |
| 87.0 | 4.5% | `__open` | libsystem_kernel.dylib |
| 67.0 | 3.5% | `_DDScannerHandleState` | DataDetectorsCore |
| 45.0 | 2.3% | `_xzm_free` | libsystem_malloc.dylib |
| 41.0 | 2.1% | `getattrlistbulk` | libsystem_kernel.dylib |
| 32.0 | 1.7% | `objc_msgSend` | libobjc.A.dylib |
| 28.0 | 1.4% | `swift_release` | libswiftCore.dylib |
| 25.0 | 1.3% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 22.0 | 1.1% | `stat` | libsystem_kernel.dylib |
| 21.0 | 1.1% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 21.0 | 1.1% | `__mac_syscall` | libsystem_kernel.dylib |
| 21.0 | 1.1% | `_platform_memmove` | libsystem_platform.dylib |
| 19.0 | 1.0% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 17.0 | 0.9% | `swift_retain` | libswiftCore.dylib |
| 17.0 | 0.9% | `swift::TargetContextDescriptor<swift::InProcess>::getGenericContext() const` | libswiftCore.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 1277.0 | 65.9% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 533.0 | 27.5% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 533.0 | 27.5% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 533.0 | 27.5% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 522.0 | 26.9% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 516.0 | 26.6% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 489.0 | 25.2% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 489.0 | 25.2% | `protocol witness for Decodable.init(from:) in conformance SidecarEnvelope` | GuessWhoSync |
| 460.0 | 23.7% | `Result<>.init(catching:)` | GuessWhoSync |
| 459.0 | 23.7% | `closure #1 in FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 459.0 | 23.7% | `partial apply for closure #1 in FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 453.0 | 23.4% | `protocol witness for Decodable.init(from:) in conformance SidecarCell` | GuessWhoSync |
| 452.0 | 23.3% | `SidecarCell.init(from:)` | GuessWhoSync |
| 444.0 | 22.9% | `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)` | GuessWhoSync |
| 438.0 | 22.6% | `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance ProductionSidecarFileC...` | GuessWhoSync |

## phantom-org [46.14s – 51.20s]

total sampled CPU: 1121 ms, main thread: 217 ms

### Main thread — top leaf symbols (base 217 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 19.0 | 8.8% | `objc_msgSend` | libobjc.A.dylib |
| 5.0 | 2.3% | `swift_release` | libswiftCore.dylib |
| 4.0 | 1.8% | `_free` | libsystem_malloc.dylib |
| 4.0 | 1.8% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 3.0 | 1.4% | `_platform_memmove` | libsystem_platform.dylib |
| 3.0 | 1.4% | `swift_bridgeObjectRelease` | libswiftCore.dylib |
| 3.0 | 1.4% | `swift_bridgeObjectRetain` | libswiftCore.dylib |
| 3.0 | 1.4% | `<deduplicated_symbol>` | libobjc.A.dylib |
| 3.0 | 1.4% | `<deduplicated_symbol>` | libsystem_malloc.dylib |
| 3.0 | 1.4% | `_CFRetain` | CoreFoundation |
| 3.0 | 1.4% | `objc_release` | libobjc.A.dylib |
| 2.0 | 0.9% | `AG::LayoutDescriptor::compare_bytes(void const*, void const*, unsigned long, unsigned long*)` | AttributeGraph |
| 2.0 | 0.9% | `weak_entry_for_referent` | libobjc.A.dylib |
| 2.0 | 0.9% | `_platform_memset` | libsystem_platform.dylib |
| 2.0 | 0.9% | `objc_retain` | libobjc.A.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 128.0 | 59.0% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 128.0 | 59.0% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 128.0 | 59.0% | `_CFRunLoopRunSpecificWithOptions` | CoreFoundation |
| 128.0 | 59.0% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 128.0 | 59.0% | `ReceiveNextEventCommon` | HIToolbox |
| 128.0 | 59.0% | `RunCurrentEventLoopInMode` | HIToolbox |
| 128.0 | 59.0% | `-[NSApplication run]` | AppKit |
| 128.0 | 59.0% | `_DPSNextEvent` | AppKit |
| 128.0 | 59.0% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 127.0 | 58.5% | `start` | dyld |
| 127.0 | 58.5% | `0x1c4ccdcf8` | UIKitCore |
| 127.0 | 58.5% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 127.0 | 58.5% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 127.0 | 58.5% | `NSApplicationMain` | AppKit |
| 127.0 | 58.5% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |

### All threads — top leaf symbols (base 1121 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 48.0 | 4.3% | `__getattrlist` | libsystem_kernel.dylib |
| 45.0 | 4.0% | `objc_msgSend` | libobjc.A.dylib |
| 38.0 | 3.4% | `__open` | libsystem_kernel.dylib |
| 26.0 | 2.3% | `_xzm_free` | libsystem_malloc.dylib |
| 25.0 | 2.2% | `_platform_memmove` | libsystem_platform.dylib |
| 20.0 | 1.8% | `getattrlistbulk` | libsystem_kernel.dylib |
| 17.0 | 1.5% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 15.0 | 1.3% | `stat` | libsystem_kernel.dylib |
| 14.0 | 1.2% | `swift_release` | libswiftCore.dylib |
| 14.0 | 1.2% | `__mac_syscall` | libsystem_kernel.dylib |
| 13.0 | 1.2% | `__CF_IS_OBJC` | CoreFoundation |
| 12.0 | 1.1% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 11.0 | 1.0% | `_CFRelease` | CoreFoundation |
| 10.0 | 0.9% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 9.0 | 0.8% | `_free` | libsystem_malloc.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 841.0 | 75.0% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 389.0 | 34.7% | `Result<>.init(catching:)` | GuessWhoSync |
| 337.0 | 30.1% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 337.0 | 30.1% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 337.0 | 30.1% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 329.0 | 29.3% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 300.0 | 26.8% | `FileSystemSidecarStore.decode(_:for:decoder:)` | GuessWhoSync |
| 289.0 | 25.8% | `closure #1 in FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 289.0 | 25.8% | `partial apply for closure #1 in FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 284.0 | 25.3% | `protocol witness for Decodable.init(from:) in conformance SidecarEnvelope` | GuessWhoSync |
| 284.0 | 25.3% | `SidecarEnvelope.init(from:)` | GuessWhoSync |
| 280.0 | 25.0% | `GuessWhoSync.walkSidecarCorpus(kinds:_:)` | GuessWhoSync |
| 260.0 | 23.2% | `protocol witness for Decodable.init(from:) in conformance SidecarCell` | GuessWhoSync |
| 260.0 | 23.2% | `SidecarCell.init(from:)` | GuessWhoSync |
| 254.0 | 22.7% | `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance ProductionSidecarFileC...` | GuessWhoSync |
