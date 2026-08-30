Building image map from launch-after-b2-2.trace...
  57 unique binaries
Samples in window (matching thread filter): 3788
Symbolicating...

# Hotspots — launch-after-b2-2.trace

**Samples in window:** 3788  
**Top threads:** GuessWho 0x29f48da (877), Main Thread 0x29f486b (488), GuessWho 0x29f48dc (420), GuessWho 0x29f48c5 (351), GuessWho 0x29f48c8 (303)  

| Samples | % | Symbol | Binary |
|---------|---|--------|--------|
| 2434 | 64.3% | `0x18bb204b0` | libdispatch.dylib |
| 2346 | 61.9% | start_wqthread (in libsystem_pthread.dylib) + 8 | libsystem_pthread.dylib |
| 2253 | 59.5% | `0x18bb06a28` | libdispatch.dylib |
| 2162 | 57.1% | 0x00130930 | GuessWhoSync |
| 1479 | 39.0% | _pthread_wqthread (in libsystem_pthread.dylib) + 292 | libsystem_pthread.dylib |
| 1479 | 39.0% | `0x18bb19e34` | libdispatch.dylib |
| 1479 | 39.0% | `0x18bb19734` | libdispatch.dylib |
| 1422 | 37.5% | `0x18bb0f030` | libdispatch.dylib |
| 1398 | 36.9% | `0x18bb0fb2c` | libdispatch.dylib |
| 918 | 24.2% | `0x18bb16360` | libdispatch.dylib |
| 909 | 24.0% | `0x18bc7dc34` | libc++.1.dylib |
| 877 | 23.2% | `0x18bc869c0` | libc++.1.dylib |
| 877 | 23.2% | `0x18bc7dfc0` | libc++.1.dylib |
| 867 | 22.9% | _pthread_wqthread (in libsystem_pthread.dylib) + 232 | libsystem_pthread.dylib |
| 867 | 22.9% | `0x18bb19120` | libdispatch.dylib |
| 864 | 22.8% | start_wqthread (in libsystem_pthread.dylib) + 0 | libsystem_pthread.dylib |
| 854 | 22.5% | `0x18bb18adc` | libdispatch.dylib |
| 854 | 22.5% | `0x18b9ec298` | libsystem_trace.dylib |
| 853 | 22.5% | `0x18bb3dd6c` | libdispatch.dylib |
| 847 | 22.4% | `0x1a4ba92a8` | ContactsFoundation |
| 840 | 22.2% | `0x1a4eb788c` | Contacts |
| 840 | 22.2% | `0x1a4eb77a4` | Contacts |
| 840 | 22.2% | `0x1a4e8ec48` | Contacts |
| 838 | 22.1% | `0x1a4c805ac` | ContactsPersistence |
| 838 | 22.1% | `0x1937e67b8` | CoreData |
| 838 | 22.1% | `0x1a4c80548` | ContactsPersistence |
| 838 | 22.1% | `0x1937e68e4` | CoreData |
| 836 | 22.1% | `0x1a4fc9690` | Contacts |
| 836 | 22.1% | `0x1a505b5a4` | Contacts |
| 836 | 22.1% | `0x1a4bd86ac` | ContactsFoundation |
| 836 | 22.1% | `0x1a4bd80c0` | ContactsFoundation |
| 836 | 22.1% | `0x1a4e6a7c0` | Contacts |
| 836 | 22.1% | `0x1a4e6a6c8` | Contacts |
| 836 | 22.1% | `0x1a4e6a654` | Contacts |
| 836 | 22.1% | `0x1a4f5ff78` | Contacts |
| 834 | 22.0% | `0x1a4f45c1c` | Contacts |
| 834 | 22.0% | `0x1a4e6a420` | Contacts |
| 834 | 22.0% | `0x1a4e9b028` | Contacts |
| 834 | 22.0% | `0x1a4eb7fe4` | Contacts |
| 834 | 22.0% | `0x1a4fc9f18` | Contacts |

## Symbolication failures

These binaries had samples but couldn't be symbolicated:

- `/usr/lib/system/libdispatch.dylib` — binary not at trace-recorded path
- `/usr/lib/libc++.1.dylib` — binary not at trace-recorded path
- `/usr/lib/system/libsystem_trace.dylib` — binary not at trace-recorded path
- `/System/Library/PrivateFrameworks/ContactsFoundation.framework/Versions/A/ContactsFoundation` — binary not at trace-recorded path
- `/System/Library/Frameworks/Contacts.framework/Versions/A/Contacts` — binary not at trace-recorded path
- `/System/Library/PrivateFrameworks/ContactsPersistence.framework/Versions/A/ContactsPersistence` — binary not at trace-recorded path
- `/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData` — binary not at trace-recorded path
- `/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation` — binary not at trace-recorded path
- `/usr/lib/system/libxpc.dylib` — binary not at trace-recorded path
- `/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation` — binary not at trace-recorded path
- `/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider` — binary not at trace-recorded path
- `/System/iOSSupport/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore` — binary not at trace-recorded path
- `/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit` — binary not at trace-recorded path
- `/System/Library/PrivateFrameworks/UIKitMacHelper.framework/Versions/A/UIKitMacHelper` — binary not at trace-recorded path
- `/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox` — binary not at trace-recorded path

_Hint: if these are your own binaries, the trace was captured against a build whose UUID no longer matches what's on disk. Rebuild against the same source (or point atos at the matching .dSYM) to recover symbols._
