Building image map from launch-after-2.trace...
  56 unique binaries
Samples in window (matching thread filter): 19790
Symbolicating...

# Hotspots — launch-after-2.trace

**Samples in window:** 19790  
**Top threads:** GuessWho 0x28d6e57 (2385), GuessWho 0x28d6db0 (2355), GuessWho 0x28d6dbd (1981), GuessWho 0x28d6dbc (1863), GuessWho 0x28d6d97 (1762)  

| Samples | % | Symbol | Binary |
|---------|---|--------|--------|
| 15336 | 77.5% | `0x18bb204b0` | libdispatch.dylib |
| 15326 | 77.4% | start_wqthread (in libsystem_pthread.dylib) + 8 | libsystem_pthread.dylib |
| 15185 | 76.7% | `0x18bb06a28` | libdispatch.dylib |
| 15059 | 76.1% | 0x0011c58c | GuessWhoSync |
| 7953 | 40.2% | _pthread_wqthread (in libsystem_pthread.dylib) + 292 | libsystem_pthread.dylib |
| 7950 | 40.2% | `0x18bb19734` | libdispatch.dylib |
| 7949 | 40.2% | `0x18bb19e34` | libdispatch.dylib |
| 7845 | 39.6% | `0x18bb0f030` | libdispatch.dylib |
| 7759 | 39.2% | `0x18bb0fb2c` | libdispatch.dylib |
| 7371 | 37.2% | _pthread_wqthread (in libsystem_pthread.dylib) + 232 | libsystem_pthread.dylib |
| 7371 | 37.2% | `0x18bb19120` | libdispatch.dylib |
| 7362 | 37.2% | `0x18bb18adc` | libdispatch.dylib |
| 7361 | 37.2% | `0x18bb3dd6c` | libdispatch.dylib |
| 6997 | 35.4% | protocol witness for SidecarStoreProtocol.read(_:) in conformance FileSystemSidecarStore (/<compiler-generated>:0) | GuessWhoSync |
| 6695 | 33.8% | <deduplicated_symbol> (in GuessWhoSync) + 80 | GuessWhoSync |
| 6690 | 33.8% | closure #1 in FileSystemSidecarStore.runWithBusyHandling(key:operation:) (FileSystemSidecarStore.swift:689) | GuessWhoSync |
| 6689 | 33.8% | FileSystemSidecarStore.read(_:) (FileSystemSidecarStore.swift:111) | GuessWhoSync |
| 6687 | 33.8% | partial apply for closure #1 in FileSystemSidecarStore.coordinatedRead(key:at:_:) (in GuessWhoSync) + 20 | GuessWhoSync |
| 6681 | 33.8% | `0x18d5b0994` | Foundation |
| 6679 | 33.7% | `0x1a5f57fcc` | FileProvider |
| 6678 | 33.7% | `0x18bc7dbc8` | libc++.1.dylib |
| 6678 | 33.7% | `0x18bb08ae8` | libdispatch.dylib |
| 6676 | 33.7% | closure #1 in FileSystemSidecarStore.coordinatedRead(key:at:_:) (/<compiler-generated>:0) | GuessWhoSync |
| 6674 | 33.7% | FileSystemSidecarStore.runWithBusyHandling(key:operation:) (FileSystemSidecarStore.swift:700) | GuessWhoSync |
| 6462 | 32.7% | `0x18d5b0c94` | Foundation |

## Symbolication failures

These binaries had samples but couldn't be symbolicated:

- `/usr/lib/system/libdispatch.dylib` — binary not at trace-recorded path
- `/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation` — binary not at trace-recorded path
- `/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider` — binary not at trace-recorded path
- `/usr/lib/libc++.1.dylib` — binary not at trace-recorded path
- `/usr/lib/system/libsystem_trace.dylib` — binary not at trace-recorded path
- `/System/Library/PrivateFrameworks/ContactsFoundation.framework/Versions/A/ContactsFoundation` — binary not at trace-recorded path
- `/System/Library/Frameworks/Contacts.framework/Versions/A/Contacts` — binary not at trace-recorded path
- `/System/Library/PrivateFrameworks/ContactsPersistence.framework/Versions/A/ContactsPersistence` — binary not at trace-recorded path
- `/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData` — binary not at trace-recorded path

_Hint: if these are your own binaries, the trace was captured against a build whose UUID no longer matches what's on disk. Rebuild against the same source (or point atos at the matching .dSYM) to recover symbols._
