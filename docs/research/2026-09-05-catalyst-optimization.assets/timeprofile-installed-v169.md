# time-profile aggregation — /Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-edc537f7/repo/.build/profiling/timeprofile-v169.xml

rows: 8024, total sampled CPU: 8024 ms, main thread: 2121 ms

## Threads by sampled CPU (top 12)

| Thread | CPU ms | % of total |
|---|---|---|
| GuessWho 0x45441e0 (GuessWho, pid: 54398) | 2700 | 33.6% |
| Main Thread 0x4543bf8 (GuessWho, pid: 54398) | 2121 | 26.4% |
| GuessWho 0x454429c (GuessWho, pid: 54398) | 1956 | 24.4% |
| GuessWho 0x45441bc (GuessWho, pid: 54398) | 296 | 3.7% |
| GuessWho 0x454423a (GuessWho, pid: 54398) | 285 | 3.6% |
| GuessWho 0x4544294 (GuessWho, pid: 54398) | 125 | 1.6% |
| GuessWho 0x45441d4 (GuessWho, pid: 54398) | 101 | 1.3% |
| GuessWho 0x45441d5 (GuessWho, pid: 54398) | 77 | 1.0% |
| GuessWho 0x45441e1 (GuessWho, pid: 54398) | 75 | 0.9% |
| GuessWho 0x45441b7 (GuessWho, pid: 54398) | 60 | 0.7% |
| GuessWho 0x45443e1 (GuessWho, pid: 54398) | 52 | 0.6% |
| GuessWho 0x45443e3 (GuessWho, pid: 54398) | 49 | 0.6% |

## Main thread — top leaf symbols (self weight, base = main 2121 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 86.0 | 4.1% | `objc_msgSend` | libobjc.A.dylib |
| 44.0 | 2.1% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 38.0 | 1.8% | `-[CUIStructuredThemeStore lookupAssetForKey:]` | CoreUI |
| 38.0 | 1.8% | `_platform_memmove` | libsystem_platform.dylib |
| 34.0 | 1.6% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 33.0 | 1.6% | `__getattrlist` | libsystem_kernel.dylib |
| 26.0 | 1.2% | `dyld3::MachOFile::trieWalk(Diagnostics&, unsigned char const*, unsigned char const*, char const*)` | dyld |
| 26.0 | 1.2% | `__CF_IS_OBJC` | CoreFoundation |
| 25.0 | 1.2% | `getMethodFromRelativeList(relative_list_list_t<method_list_t>*, objc_selector*)` | libobjc.A.dylib |
| 24.0 | 1.1% | `CFStringFindWithOptionsAndLocale` | CoreFoundation |
| 19.0 | 0.9% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 17.0 | 0.8% | `madvise` | libsystem_kernel.dylib |
| 16.0 | 0.8% | `_CFRelease` | CoreFoundation |
| 15.0 | 0.7% | `_platform_strcmp_noMTE` | dyld |
| 14.0 | 0.7% | `map_images_nolock` | libobjc.A.dylib |

## Main thread — stack presence (weight of samples containing frame)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 1757.0 | 82.8% | `start` | dyld |
| 1648.0 | 77.7% | `0x100343d68` | GuessWho |
| 1647.0 | 77.7% | `0x1c4ccdcf8` | UIKitCore |
| 1647.0 | 77.7% | `UIApplicationMain` | UIKitCore |
| 1435.0 | 67.7% | `UINSApplicationMain` | UIKitMacHelper |
| 1435.0 | 67.7% | `NSApplicationMain` | AppKit |
| 1435.0 | 67.7% | `-[NSApplication run]` | AppKit |
| 1435.0 | 67.7% | `_NSApplicationMainWithInfoDictionary` | AppKit |
| 1380.0 | 65.1% | `-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]` | AppKit |
| 1380.0 | 65.1% | `_DPSNextEvent` | AppKit |
| 1380.0 | 65.1% | `-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]` | AppKit |
| 1374.0 | 64.8% | `_BlockUntilNextEventMatchingListInMode` | HIToolbox |
| 1374.0 | 64.8% | `ReceiveNextEventCommon` | HIToolbox |
| 1374.0 | 64.8% | `_DPSBlockUntilNextEventMatchingListInMode` | AppKit |
| 1371.0 | 64.6% | `RunCurrentEventLoopInMode` | HIToolbox |

## All threads — top leaf symbols (base = total 8024 ms)

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 464.0 | 5.8% | `mach_msg2_trap` | libsystem_kernel.dylib |
| 403.0 | 5.0% | `objc_msgSend` | libobjc.A.dylib |
| 144.0 | 1.8% | `getMethodNoSuper_nolock(objc_class*, objc_selector*)` | libobjc.A.dylib |
| 121.0 | 1.5% | `__open` | libsystem_kernel.dylib |
| 119.0 | 1.5% | `__getattrlist` | libsystem_kernel.dylib |
| 115.0 | 1.4% | `_platform_memset` | libsystem_platform.dylib |
| 108.0 | 1.3% | `_platform_memmove` | libsystem_platform.dylib |
| 102.0 | 1.3% | `__CF_IS_OBJC` | CoreFoundation |
| 93.0 | 1.2% | `_xzm_xzone_malloc_tiny` | libsystem_malloc.dylib |
| 90.0 | 1.1% | `objc_release` | libobjc.A.dylib |
| 88.0 | 1.1% | `_xzm_free` | libsystem_malloc.dylib |
| 82.0 | 1.0% | `objc_retain` | libobjc.A.dylib |
| 78.0 | 1.0% | `_getLastByteOfValueIncludingMarker` | Foundation |
| 73.0 | 0.9% | `_platform_strcmp$VARIANT$Base` | libsystem_platform.dylib |
| 56.0 | 0.7% | `stat` | libsystem_kernel.dylib |

## App binaries (GuessWho*) — top leaf symbols, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 5.0 | 0.1% | `DYLD-STUB$$swift_bridgeObjectRetain` | GuessWhoSync |
| 3.0 | 0.0% | `DYLD-STUB$$$$$indirect-absolute-symbol$$$` | GuessWhoSync |
| 3.0 | 0.0% | `0x10197af1c` | GuessWhoSync |
| 3.0 | 0.0% | `0x1018daaa0` | GuessWhoSync |
| 2.0 | 0.0% | `0x1019812d4` | GuessWhoSync |
| 2.0 | 0.0% | `DYLD-STUB$$swift_bridgeObjectRelease` | GuessWhoSync |
| 2.0 | 0.0% | `0x101a2e5cc` | GuessWhoSync |
| 2.0 | 0.0% | `0x1018cf0f0` | GuessWhoSync |
| 2.0 | 0.0% | `0x1018cef90` | GuessWhoSync |
| 2.0 | 0.0% | `0x10193ec48` | GuessWhoSync |
| 1.0 | 0.0% | `0x100343d68` | GuessWho |
| 1.0 | 0.0% | `0x1003fd700` | GuessWho |
| 1.0 | 0.0% | `0x1001cd0c0` | GuessWho |
| 1.0 | 0.0% | `0x10040a5b0` | GuessWho |
| 1.0 | 0.0% | `0x1001bccb0` | GuessWho |

## App binaries (GuessWho*) — stack presence, all threads

| CPU ms | % | Symbol | Binary |
|---|---|---|---|
| 5177.0 | 64.5% | `0x1019d0a00` | GuessWhoSync |
| 2574.0 | 32.1% | `0x1018c4e48` | GuessWhoSync |
| 2574.0 | 32.1% | `0x1018c0324` | GuessWhoSync |
| 2400.0 | 29.9% | `0x1018c5350` | GuessWhoSync |
| 2400.0 | 29.9% | `0x1018b3748` | GuessWhoSync |
| 2400.0 | 29.9% | `0x1018b3728` | GuessWhoSync |
| 1801.0 | 22.4% | `0x10194dcac` | GuessWhoSync |
| 1801.0 | 22.4% | `0x10194dccc` | GuessWhoSync |
| 1648.0 | 20.5% | `0x100343d68` | GuessWho |
| 1448.0 | 18.0% | `0x101952250` | GuessWhoSync |
| 1448.0 | 18.0% | `0x1019525e0` | GuessWhoSync |
| 1448.0 | 18.0% | `0x101958f9c` | GuessWhoSync |
| 1448.0 | 18.0% | `0x101958fb0` | GuessWhoSync |
| 1448.0 | 18.0% | `0x1019a5b98` | GuessWhoSync |
| 1448.0 | 18.0% | `0x1019543d0` | GuessWhoSync |

## Self weight by binary — all threads (top 25)

| CPU ms | % | Binary |
|---|---|---|
| 1598 | 19.9% | libobjc.A.dylib |
| 1488 | 18.5% | CoreFoundation |
| 1036 | 12.9% | libsystem_kernel.dylib |
| 687 | 8.6% | Foundation |
| 543 | 6.8% | libswiftCore.dylib |
| 416 | 5.2% | libsystem_malloc.dylib |
| 394 | 4.9% | libsystem_platform.dylib |
| 235 | 2.9% | UIKitCore |
| 219 | 2.7% | dyld |
| 177 | 2.2% | EventKit |
| 155 | 1.9% | CoreData |
| 110 | 1.4% | SwiftUI |
| 103 | 1.3% | libxpc.dylib |
| 73 | 0.9% | Contacts |
| 67 | 0.8% | libdispatch.dylib |
| 64 | 0.8% | GuessWhoSync |
| 52 | 0.6% | libsystem_pthread.dylib |
| 50 | 0.6% | CoreUI |
| 49 | 0.6% | SwiftUICore |
| 43 | 0.5% | libsystem_c.dylib |
| 37 | 0.5% | QuartzCore |
| 36 | 0.4% | CoreGraphics |
| 35 | 0.4% | libicucore.A.dylib |
| 32 | 0.4% | libsystem_blocks.dylib |
| 23 | 0.3% | CalendarFoundation |

## Self weight by binary — main thread (top 20)

| CPU ms | % | Binary |
|---|---|---|
| 372 | 17.5% | libobjc.A.dylib |
| 270 | 12.7% | CoreFoundation |
| 224 | 10.6% | UIKitCore |
| 208 | 9.8% | libswiftCore.dylib |
| 175 | 8.3% | libsystem_kernel.dylib |
| 135 | 6.4% | dyld |
| 108 | 5.1% | SwiftUI |
| 89 | 4.2% | libsystem_platform.dylib |
| 78 | 3.7% | Foundation |
| 61 | 2.9% | libsystem_malloc.dylib |
| 50 | 2.4% | CoreUI |
| 49 | 2.3% | SwiftUICore |
| 31 | 1.5% | QuartzCore |
| 30 | 1.4% | GuessWhoSync |
| 18 | 0.8% | GuessWho |
| 18 | 0.8% | CoreGraphics |
| 17 | 0.8% | AppKit |
| 17 | 0.8% | libsystem_c.dylib |
| 17 | 0.8% | CoreAutoLayout |
| 12 | 0.6% | libicucore.A.dylib |

## CPU by 5s bucket and binary (top 6 binaries per bucket)

- **0–5s** (total 112 ms): dyld 77ms, libobjc.A.dylib 18ms, libsystem_kernel.dylib 8ms, libsystem_malloc.dylib 2ms, CoreServicesStore 2ms, (unmapped) 1ms
- **5–10s** (total 2761 ms): libsystem_kernel.dylib 481ms, libobjc.A.dylib 421ms, CoreFoundation 394ms, Foundation 313ms, libswiftCore.dylib 271ms, UIKitCore 166ms
- **10–15s** (total 1074 ms): CoreFoundation 282ms, libobjc.A.dylib 246ms, libsystem_kernel.dylib 137ms, Foundation 79ms, CoreData 72ms, libsystem_platform.dylib 69ms
- **15–20s** (total 1328 ms): CoreFoundation 366ms, libobjc.A.dylib 282ms, libsystem_kernel.dylib 181ms, Foundation 138ms, libsystem_platform.dylib 103ms, libsystem_malloc.dylib 74ms
- **20–25s** (total 1576 ms): libobjc.A.dylib 320ms, libswiftCore.dylib 207ms, CoreFoundation 203ms, libsystem_kernel.dylib 116ms, SwiftUI 110ms, Foundation 80ms
- **25–30s** (total 922 ms): libobjc.A.dylib 247ms, CoreFoundation 200ms, libsystem_kernel.dylib 83ms, EventKit 83ms, libsystem_malloc.dylib 62ms, Foundation 59ms
- **30–35s** (total 251 ms): libobjc.A.dylib 64ms, CoreFoundation 42ms, libsystem_kernel.dylib 30ms, EventKit 25ms, libsystem_malloc.dylib 21ms, Foundation 18ms
