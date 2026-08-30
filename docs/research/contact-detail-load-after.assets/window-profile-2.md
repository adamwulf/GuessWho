# Windowed time-profile aggregation — .build/traces/tp-2.xml

## launch [0.00s – 18.55s]

total sampled CPU: 9438 ms, main thread: 1385 ms

### Main thread — top leaf symbols (base 1385 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 83.0 | 6.0% | `objc_msgSend` | libobjc.A.dylib |
| 46.0 | 3.3% | `__getattrlist` | libsystem_kernel.dylib |
| 31.0 | 2.2% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 28.0 | 2.0% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 23.0 | 1.7% | `__CF_IS_OBJC` | CoreFoundation |
| 20.0 | 1.4% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 17.0 | 1.2% | `_xzm_free` | libsystem_malloc.dylib |
| 16.0 | 1.2% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 14.0 | 1.0% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 13.0 | 0.9% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 13.0 | 0.9% | `_platform_memmove` | libsystem_platform.dylib |
| 11.0 | 0.8% | `dyld3::MachOFile::trieWalk(Diagnostics&, unsigned char const*, unsigned char const*, char const*)` | dyld |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 1126.0 | 81.3% | `start` | dyld |
| 1064.0 | 76.8% | `UIApplicationMain` | UIKitCore |
| 1064.0 | 76.8% | `0x1c4ccdcf8` | UIKitCore |
| 1064.0 | 76.8% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 1064.0 | 76.8% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 1064.0 | 76.8% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 950.0 | 68.6% | `UINSApplicationMain` | UIKitMacHelper |
| 950.0 | 68.6% | `-[NSApplication run]` | AppKit |
| 950.0 | 68.6% | `NSApplicationMain` | AppKit |
| 950.0 | 68.6% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 935.0 | 67.5% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 935.0 | 67.5% | `_DPSNextEvent` | AppKit |

### All threads — top leaf symbols (base 9438 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 526.0 | 5.6% | `objc_msgSend` | libobjc.A.dylib |
| 506.0 | 5.4% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 184.0 | 1.9% | `__getattrlist` | libsystem_kernel.dylib |
| 178.0 | 1.9% | `__open` | libsystem_kernel.dylib |
| 177.0 | 1.9% | `objc_release` | libobjc.A.dylib |
| 157.0 | 1.7% | `_xzm_free` | libsystem_malloc.dylib |
| 152.0 | 1.6% | `objc_retain` | libobjc.A.dylib |
| 147.0 | 1.6% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 142.0 | 1.5% | `-[EKObjectID isEqual:]` | EventKit |
| 115.0 | 1.2% | `__CF_IS_OBJC` | CoreFoundation |
| 106.0 | 1.1% | `_platform_memset` | libsystem_platform.dylib |
| 95.0 | 1.0% | `_platform_memmove` | libsystem_platform.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 7424.0 | 78.7% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 4311.0 | 45.7% | `Result<>.init(catching:)` | GuessWhoSync |
| 3881.0 | 41.1% | `partial apply for closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 3881.0 | 41.1% | `closure #1 in EKEventStoreAdapter.init(store:)` | GuessWhoSync |
| 3880.0 | 41.1% | `static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)` | GuessWhoSync |
| 3566.0 | 37.8% | `WindowSingleFlightCache.value(interval:build:)` | GuessWhoSync |
| 3566.0 | 37.8% | `closure #1 in closure #1 in GuessWhoSync.prepareRecentEventsIndex()` | GuessWhoSync |
| 3566.0 | 37.8% | `EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 3566.0 | 37.8% | `protocol witness for EventStoreProtocol.prepareEventsWithAttendeeIndex(in:) in conformance EKEventStoreAdapter` | GuessWhoSync |
| 3565.0 | 37.8% | `EKEventStoreAdapter.buildAttendeeIndex(in:)` | GuessWhoSync |
| 3565.0 | 37.8% | `closure #1 in EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |
| 3565.0 | 37.8% | `partial apply for closure #1 in EKEventStoreAdapter.prepareEventsWithAttendeeIndex(in:)` | GuessWhoSync |

## contact-A [18.55s – 26.86s]

total sampled CPU: 880 ms, main thread: 380 ms

### Main thread — top leaf symbols (base 380 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 15.0 | 3.9% | `objc_msgSend` | libobjc.A.dylib |
| 6.0 | 1.6% | `_xzm_free` | libsystem_malloc.dylib |
| 5.0 | 1.3% | `__CFStringHash` | CoreFoundation |
| 4.0 | 1.1% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 4.0 | 1.1% | `_platform_memmove` | libsystem_platform.dylib |
| 4.0 | 1.1% | `<deduplicated_symbol>` | SwiftUICore |
| 3.0 | 0.8% | `getCache(swift::TargetTypeContextDescriptor<swift::InProcess> const&)` | libswiftCore.dylib |
| 3.0 | 0.8% | `swift::Demangle::__runtime::makeSymbolicMangledNameStringRef(char const*)` | libswiftCore.dylib |
| 3.0 | 0.8% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 3.0 | 0.8% | `objc_release` | libobjc.A.dylib |
| 3.0 | 0.8% | `_CFRelease` | CoreFoundation |
| 3.0 | 0.8% | `objc_retain` | libobjc.A.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 306.0 | 80.5% | `0x1c4ccdcf8` | UIKitCore |
| 306.0 | 80.5% | `UINSApplicationMain` | UIKitMacHelper |
| 306.0 | 80.5% | `RunCurrentEventLoopInMode` | HIToolbox |
| 306.0 | 80.5% | `-[NSApplication run]` | AppKit |
| 306.0 | 80.5% | `ReceiveNextEventCommon` | HIToolbox |
| 306.0 | 80.5% | `UIApplicationMain` | UIKitCore |
| 306.0 | 80.5% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 306.0 | 80.5% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 306.0 | 80.5% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 306.0 | 80.5% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 306.0 | 80.5% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 306.0 | 80.5% | `NSApplicationMain` | AppKit |

### All threads — top leaf symbols (base 880 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 47.0 | 5.3% | `__getattrlist` | libsystem_kernel.dylib |
| 31.0 | 3.5% | `__open` | libsystem_kernel.dylib |
| 26.0 | 3.0% | `objc_msgSend` | libobjc.A.dylib |
| 20.0 | 2.3% | `swift_conformsToProtocolMaybeInstantiateSuperclasses(swift::TargetMetadata<swift::InProcess> const*, swift:...` | libswiftCore.dylib |
| 16.0 | 1.8% | `_xzm_free` | libsystem_malloc.dylib |
| 16.0 | 1.8% | `__CF_IS_OBJC` | CoreFoundation |
| 11.0 | 1.2% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 8.0 | 0.9% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 8.0 | 0.9% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 8.0 | 0.9% | `start_wqthread` | libsystem_pthread.dylib |
| 8.0 | 0.9% | `swift::TargetContextDescriptor<swift::InProcess>::getGenericContext() const` | libswiftCore.dylib |
| 8.0 | 0.9% | `getattrlistbulk` | libsystem_kernel.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 425.0 | 48.3% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 306.0 | 34.8% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 306.0 | 34.8% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 306.0 | 34.8% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 168.0 | 19.1% | `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)` | GuessWhoSync |
| 167.0 | 19.0% | `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance ProductionSidecarFileC...` | GuessWhoSync |
| 167.0 | 19.0% | `ProductionSidecarFileCoordinator.coordinateReading(at:_:)` | GuessWhoSync |
| 162.0 | 18.4% | `partial apply for closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |
| 162.0 | 18.4% | `closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |
| 161.0 | 18.3% | `thunk for @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |
| 161.0 | 18.3% | `thunk for @escaping @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |
| 160.0 | 18.2% | `partial apply for closure #1 in FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |

## contact-B [26.86s – 35.37s]

total sampled CPU: 751 ms, main thread: 345 ms

### Main thread — top leaf symbols (base 345 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 34.0 | 9.9% | `objc_msgSend` | libobjc.A.dylib |
| 5.0 | 1.4% | `_platform_memmove` | libsystem_platform.dylib |
| 5.0 | 1.4% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 5.0 | 1.4% | `_xzm_free` | libsystem_malloc.dylib |
| 4.0 | 1.2% | `swift_retain` | libswiftCore.dylib |
| 4.0 | 1.2% | `__CFStringHash` | CoreFoundation |
| 4.0 | 1.2% | `objc_release_x20` | libobjc.A.dylib |
| 4.0 | 1.2% | `__kdebug_trace64` | libsystem_kernel.dylib |
| 3.0 | 0.9% | `Hasher.combine(bytes:)` | libswiftCore.dylib |
| 3.0 | 0.9% | `getCache(swift::TargetTypeContextDescriptor<swift::InProcess> const&)` | libswiftCore.dylib |
| 3.0 | 0.9% | `<deduplicated_symbol>` | SwiftUICore |
| 3.0 | 0.9% | `CFNumberGetValue` | CoreFoundation |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 268.0 | 77.7% | `0x1c4ccdcf8` | UIKitCore |
| 268.0 | 77.7% | `UINSApplicationMain` | UIKitMacHelper |
| 268.0 | 77.7% | `-[NSApplication run]` | AppKit |
| 268.0 | 77.7% | `ReceiveNextEventCommon` | HIToolbox |
| 268.0 | 77.7% | `UIApplicationMain` | UIKitCore |
| 268.0 | 77.7% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 268.0 | 77.7% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 268.0 | 77.7% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 268.0 | 77.7% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 268.0 | 77.7% | `NSApplicationMain` | AppKit |
| 268.0 | 77.7% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 268.0 | 77.7% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |

### All threads — top leaf symbols (base 751 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 43.0 | 5.7% | `objc_msgSend` | libobjc.A.dylib |
| 33.0 | 4.4% | `__open` | libsystem_kernel.dylib |
| 27.0 | 3.6% | `__getattrlist` | libsystem_kernel.dylib |
| 19.0 | 2.5% | `_platform_memmove` | libsystem_platform.dylib |
| 12.0 | 1.6% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 12.0 | 1.6% | `_xzm_free` | libsystem_malloc.dylib |
| 11.0 | 1.5% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 9.0 | 1.2% | `__mac_syscall` | libsystem_kernel.dylib |
| 7.0 | 0.9% | `swift_retain` | libswiftCore.dylib |
| 7.0 | 0.9% | `swift_release` | libswiftCore.dylib |
| 7.0 | 0.9% | `__CF_IS_OBJC` | CoreFoundation |
| 7.0 | 0.9% | `stat` | libsystem_kernel.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 366.0 | 48.7% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 268.0 | 35.7% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 268.0 | 35.7% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 268.0 | 35.7% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 159.0 | 21.2% | `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)` | GuessWhoSync |
| 158.0 | 21.0% | `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance ProductionSidecarFileC...` | GuessWhoSync |
| 158.0 | 21.0% | `ProductionSidecarFileCoordinator.coordinateReading(at:_:)` | GuessWhoSync |
| 158.0 | 21.0% | `thunk for @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |
| 158.0 | 21.0% | `thunk for @escaping @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |
| 157.0 | 20.9% | `closure #2 in closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |
| 157.0 | 20.9% | `partial apply for closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |
| 157.0 | 20.9% | `closure #2 in FileSystemSidecarStore.coordinatedCorpusRead(_:)` | GuessWhoSync |

## organization [35.37s – 41.39s]

total sampled CPU: 1595 ms, main thread: 587 ms

### Main thread — top leaf symbols (base 587 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 36.0 | 6.1% | `objc_msgSend` | libobjc.A.dylib |
| 14.0 | 2.4% | `_platform_memmove` | libsystem_platform.dylib |
| 8.0 | 1.4% | `_xzm_free` | libsystem_malloc.dylib |
| 6.0 | 1.0% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 5.0 | 0.9% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 5.0 | 0.9% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 5.0 | 0.9% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |
| 5.0 | 0.9% | `<deduplicated_symbol>` | VectorKit |
| 4.0 | 0.7% | `objc_release` | libobjc.A.dylib |
| 4.0 | 0.7% | `_free` | libsystem_malloc.dylib |
| 4.0 | 0.7% | `__CFStringHash` | CoreFoundation |
| 4.0 | 0.7% | `os_unfair_lock_unlock` | libsystem_platform.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 501.0 | 85.3% | `0x1c4ccdcf8` | UIKitCore |
| 501.0 | 85.3% | `UINSApplicationMain` | UIKitMacHelper |
| 501.0 | 85.3% | `RunCurrentEventLoopInMode` | HIToolbox |
| 501.0 | 85.3% | `-[NSApplication run]` | AppKit |
| 501.0 | 85.3% | `ReceiveNextEventCommon` | HIToolbox |
| 501.0 | 85.3% | `UIApplicationMain` | UIKitCore |
| 501.0 | 85.3% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 501.0 | 85.3% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 501.0 | 85.3% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 501.0 | 85.3% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 501.0 | 85.3% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 501.0 | 85.3% | `NSApplicationMain` | AppKit |

### All threads — top leaf symbols (base 1595 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 56.0 | 3.5% | `objc_msgSend` | libobjc.A.dylib |
| 54.0 | 3.4% | `__getattrlist` | libsystem_kernel.dylib |
| 47.0 | 2.9% | `__open` | libsystem_kernel.dylib |
| 36.0 | 2.3% | `_xzm_free` | libsystem_malloc.dylib |
| 25.0 | 1.6% | `start_wqthread` | libsystem_pthread.dylib |
| 23.0 | 1.4% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 22.0 | 1.4% | `_platform_memmove` | libsystem_platform.dylib |
| 22.0 | 1.4% | `___chkstk_darwin` | libsystem_pthread.dylib |
| 17.0 | 1.1% | `getattrlistbulk` | libsystem_kernel.dylib |
| 17.0 | 1.1% | `<deduplicated_symbol>` | VectorKit |
| 17.0 | 1.1% | `0x19ba65988` | libz.1.dylib |
| 14.0 | 0.9% | `read` | libsystem_kernel.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 664.0 | 41.6% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 501.0 | 31.4% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 501.0 | 31.4% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 501.0 | 31.4% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 260.0 | 16.3% | `FileSystemSidecarStore.walkCorpus(reading:listing:_:)` | GuessWhoSync |
| 260.0 | 16.3% | `protocol witness for SidecarCorpusReading.walkCorpus(reading:listing:_:) in conformance FileSystemSidecarStore` | GuessWhoSync |
| 260.0 | 16.3% | `GuessWhoSync.walkSidecarCorpus(reading:listing:_:)` | GuessWhoSync |
| 253.0 | 15.9% | `FileSystemSidecarStore.visitCapturedCorpus(keys:outcomes:_:)` | GuessWhoSync |
| 247.0 | 15.5% | `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)` | GuessWhoSync |
| 246.0 | 15.4% | `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance ProductionSidecarFileC...` | GuessWhoSync |
| 246.0 | 15.4% | `ProductionSidecarFileCoordinator.coordinateReading(at:_:)` | GuessWhoSync |
| 243.0 | 15.2% | `thunk for @callee_guaranteed (@in_guaranteed URL) -> ()` | GuessWhoSync |

## event [41.39s – 47.47s]

total sampled CPU: 951 ms, main thread: 515 ms

### Main thread — top leaf symbols (base 515 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 67.0 | 13.0% | `_DDScannerHandleState` | DataDetectorsCore |
| 32.0 | 6.2% | `computeLexemsAtPosition` | DataDetectorsCore |
| 19.0 | 3.7% | `objc_msgSend` | libobjc.A.dylib |
| 18.0 | 3.5% | `processToken` | DataDetectorsCore |
| 11.0 | 2.1% | `DDLexerDeterministicScan` | DataDetectorsCore |
| 7.0 | 1.4% | `langid_consume_string` | liblangid.dylib |
| 7.0 | 1.4% | `__open` | libsystem_kernel.dylib |
| 7.0 | 1.4% | `initializeWithCopy for Event` | GuessWhoSync |
| 6.0 | 1.2% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 6.0 | 1.2% | `stat` | libsystem_kernel.dylib |
| 5.0 | 1.0% | `_platform_memmove` | libsystem_platform.dylib |
| 5.0 | 1.0% | `objc_retainAutoreleasedReturnValue` | libobjc.A.dylib |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 228.0 | 44.3% | `0x1c4ccdcf8` | UIKitCore |
| 228.0 | 44.3% | `UINSApplicationMain` | UIKitMacHelper |
| 228.0 | 44.3% | `RunCurrentEventLoopInMode` | HIToolbox |
| 228.0 | 44.3% | `-[NSApplication run]` | AppKit |
| 228.0 | 44.3% | `ReceiveNextEventCommon` | HIToolbox |
| 228.0 | 44.3% | `UIApplicationMain` | UIKitCore |
| 228.0 | 44.3% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 228.0 | 44.3% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 228.0 | 44.3% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 228.0 | 44.3% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 228.0 | 44.3% | `NSApplicationMain` | AppKit |
| 228.0 | 44.3% | `_NSApplicationMainWithInfoDictionary` | AppKit |

### All threads — top leaf symbols (base 951 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 67.0 | 7.0% | `_DDScannerHandleState` | DataDetectorsCore |
| 41.0 | 4.3% | `objc_msgSend` | libobjc.A.dylib |
| 32.0 | 3.4% | `computeLexemsAtPosition` | DataDetectorsCore |
| 19.0 | 2.0% | `__open` | libsystem_kernel.dylib |
| 18.0 | 1.9% | `processToken` | DataDetectorsCore |
| 17.0 | 1.8% | `_xzm_free` | libsystem_malloc.dylib |
| 16.0 | 1.7% | `objc_release` | libobjc.A.dylib |
| 15.0 | 1.6% | `getattrlistbulk` | libsystem_kernel.dylib |
| 14.0 | 1.5% | `initializeWithCopy for Event` | GuessWhoSync |
| 13.0 | 1.4% | `_platform_memmove` | libsystem_platform.dylib |
| 11.0 | 1.2% | `swift_bridgeObjectRelease` | libswiftCore.dylib |
| 11.0 | 1.2% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 357.0 | 37.5% | `thunk for @escaping @callee_guaranteed @Sendable () -> ()` | GuessWhoSync |
| 299.0 | 31.4% | `GuessWhoSync.eventsWindow(from:to:includeEventKit:)` | GuessWhoSync |
| 299.0 | 31.4% | `closure #1 in closure #1 in GuessWhoSync.eventsWindow(from:to:includeEventKit:)` | GuessWhoSync |
| 228.0 | 24.0% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 228.0 | 24.0% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 227.0 | 23.9% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 218.0 | 22.9% | `static DetailLoadSignpost.measure<A>(_:_:_:)` | GuessWho.debug.dylib |
| 217.0 | 22.8% | `closure #5 in implicit closure #5 in EventDetailView.reload()` | GuessWho.debug.dylib |
| 217.0 | 22.8% | `partial apply for closure #5 in implicit closure #5 in EventDetailView.reload()` | GuessWho.debug.dylib |
| 217.0 | 22.8% | `partial apply for thunk for @escaping @callee_guaranteed @async () -> (@owned [GuideAddressMatcher.Match])` | GuessWho.debug.dylib |
| 217.0 | 22.8% | `static GuideAddressMatcher.guides(appearingIn:guides:places:)` | GuessWhoSync |
| 217.0 | 22.8% | `static GuideAddressMatcher.matches(guides:places:isMatch:)` | GuessWhoSync |

## phantom-org [47.47s – 52.62s]

total sampled CPU: 118 ms, main thread: 108 ms

### Main thread — top leaf symbols (base 108 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 4.0 | 3.7% | `objc_msgSend` | libobjc.A.dylib |
| 3.0 | 2.8% | `initializeWithCopy for Contact` | GuessWhoSync |
| 3.0 | 2.8% | `_CFRelease` | CoreFoundation |
| 3.0 | 2.8% | `<deduplicated_symbol>` | libswiftCore.dylib |
| 2.0 | 1.9% | `objc_autoreleaseReturnValue` | libobjc.A.dylib |
| 2.0 | 1.9% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 2.0 | 1.9% | `_xzm_free` | libsystem_malloc.dylib |
| 2.0 | 1.9% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 2.0 | 1.9% | `static Hasher._hash(seed:_:)` | libswiftCore.dylib |
| 2.0 | 1.9% | `swift_release` | libswiftCore.dylib |
| 1.0 | 0.9% | `_swift_stdlib_getGeneralCategory` | libswiftCore.dylib |
| 1.0 | 0.9% | `+[UITraitCollection _currentTraitCollectionWithFallback:markFallback:]` | UIKitCore |

### Main thread — stack presence

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 97.0 | 89.8% | `0x1c4ccdcf8` | UIKitCore |
| 97.0 | 89.8% | `UINSApplicationMain` | UIKitMacHelper |
| 97.0 | 89.8% | `-[NSApplication run]` | AppKit |
| 97.0 | 89.8% | `ReceiveNextEventCommon` | HIToolbox |
| 97.0 | 89.8% | `UIApplicationMain` | UIKitCore |
| 97.0 | 89.8% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 97.0 | 89.8% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 97.0 | 89.8% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 97.0 | 89.8% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 97.0 | 89.8% | `NSApplicationMain` | AppKit |
| 97.0 | 89.8% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 97.0 | 89.8% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |

### All threads — top leaf symbols (base 118 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 4.0 | 3.4% | `objc_msgSend` | libobjc.A.dylib |
| 4.0 | 3.4% | `swift_conformsToProtocolMaybeInstantiateSuperclasses(swift::TargetMetadata<swift::InProcess> const*, swift:...` | libswiftCore.dylib |
| 3.0 | 2.5% | `initializeWithCopy for Contact` | GuessWhoSync |
| 3.0 | 2.5% | `_CFRelease` | CoreFoundation |
| 3.0 | 2.5% | `<deduplicated_symbol>` | libswiftCore.dylib |
| 2.0 | 1.7% | `objc_autoreleaseReturnValue` | libobjc.A.dylib |
| 2.0 | 1.7% | `_xzm_xzone_malloc` | libsystem_malloc.dylib |
| 2.0 | 1.7% | `_xzm_free` | libsystem_malloc.dylib |
| 2.0 | 1.7% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` | libswiftCore.dylib |
| 2.0 | 1.7% | `static Hasher._hash(seed:_:)` | libswiftCore.dylib |
| 2.0 | 1.7% | `swift_release` | libswiftCore.dylib |
| 1.0 | 0.8% | `_swift_stdlib_getGeneralCategory` | libswiftCore.dylib |

### App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 97.0 | 82.2% | `static UIApplicationDelegate.main()` | GuessWho.debug.dylib |
| 97.0 | 82.2% | `__debug_main_executable_dylib_entry_point` | GuessWho.debug.dylib |
| 97.0 | 82.2% | `static GuessWhoAppDelegate.$main()` | GuessWho.debug.dylib |
| 17.0 | 14.4% | `PhantomOrganizationDetailView.body.getter` | GuessWho.debug.dylib |
| 17.0 | 14.4% | `protocol witness for View.body.getter in conformance PhantomOrganizationDetailView` | GuessWho.debug.dylib |
| 11.0 | 9.3% | `thunk for @escaping @isolated(any) @callee_guaranteed @async () -> (@out A)` | GuessWho.debug.dylib |
| 11.0 | 9.3% | `closure #1 in GuessWhoSceneDelegate.startNavBenchmarkIfRequested(appDelegate:)` | GuessWho.debug.dylib |
| 11.0 | 9.3% | `partial apply for thunk for @escaping @isolated(any) @callee_guaranteed @async () -> (@out A)` | GuessWho.debug.dylib |
| 11.0 | 9.3% | `partial apply for closure #1 in GuessWhoSceneDelegate.startNavBenchmarkIfRequested(appDelegate:)` | GuessWho.debug.dylib |
| 11.0 | 9.3% | `GuessWhoSceneDelegate.runNavBenchmark(appDelegate:)` | GuessWho.debug.dylib |
| 10.0 | 8.5% | `GuessWhoSceneDelegate.showPhantomOrganizationDetail(phantom:appDelegate:)` | GuessWho.debug.dylib |
| 9.0 | 7.6% | `ContactsRepository.phantomOrganization(key:)` | GuessWhoSync |
