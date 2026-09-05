| Window | wall s | all-thread CPU ms | main-thread CPU ms |
|---|---|---|---|
| readiness+attendee (arm->A) | 53.90 | 10924 | 1885 |
| A full | 8.55 | 691 | 451 |
| B full | 8.56 | 489 | 337 |
| org full | 6.42 | 1717 | 831 |
| event full | 6.31 | 974 | 680 |
| phantom full | 5.38 | 373 | 261 |
| A load | 0.95 | 606 | 385 |
| B load | 0.51 | 403 | 271 |
| org load | 1.14 | 907 | 490 |

### readiness+attendee (arm->A) — top app-binary stack presence
- 8329 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 4759 ms  `Result<>.init(catching:)`  (GuessWhoSync)
- 4415 ms  `static EKEventStoreAdapter.fetchEventsDirectly(store:interval:)`  (GuessWhoSync)
- 4415 ms  `closure #1 in EKEventStoreAdapter.init(store:)`  (GuessWhoSync)
- 4415 ms  `partial apply for closure #1 in EKEventStoreAdapter.init(store:)`  (GuessWhoSync)
- 3920 ms  `WindowSingleFlightCache.value(interval:build:)`  (GuessWhoSync)

### A full — top app-binary stack presence
- 394 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 394 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 394 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 179 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 174 ms  `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)`  (GuessWhoSync)
- 70 ms  `closure #1 in CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)`  (GuessWhoSync)

### B full — top app-binary stack presence
- 283 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 283 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 283 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 138 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 131 ms  `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)`  (GuessWhoSync)
- 64 ms  `closure #1 in CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)`  (GuessWhoSync)

### org full — top app-binary stack presence
- 735 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 735 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 735 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 361 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 149 ms  `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)`  (GuessWhoSync)
- 85 ms  `closure #2 in FileSystemSidecarStore.runWithBusyHandling(key:queue:operation:)`  (GuessWhoSync)

### event full — top app-binary stack presence
- 341 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 340 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 340 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 261 ms  `static DetailLoadSignpost.measure<A>(_:_:_:)`  (GuessWho.debug.dylib)
- 260 ms  `static GuideAddressMatcher.matches(guides:places:isMatch:)`  (GuessWhoSync)
- 260 ms  `static GuideAddressMatcher.guides(appearingIn:guides:places:)`  (GuessWhoSync)

### phantom full — top app-binary stack presence
- 193 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 193 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 193 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 89 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 51 ms  `ProductionSidecarFileCoordinator.coordinateReading(at:_:)`  (GuessWhoSync)
- 51 ms  `protocol witness for SidecarFileCoordinating.coordinateReading(at:_:) in conformance Pr...`  (GuessWhoSync)

### A load — top app-binary stack presence
- 348 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 348 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 348 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 172 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 169 ms  `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)`  (GuessWhoSync)
- 70 ms  `closure #1 in CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)`  (GuessWhoSync)

### B load — top app-binary stack presence
- 243 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 243 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 243 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 127 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 126 ms  `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)`  (GuessWhoSync)
- 64 ms  `closure #1 in CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)`  (GuessWhoSync)

### org load — top app-binary stack presence
- 449 ms  `static UIApplicationDelegate.main()`  (GuessWho.debug.dylib)
- 449 ms  `static GuessWhoAppDelegate.$main()`  (GuessWho.debug.dylib)
- 449 ms  `__debug_main_executable_dylib_entry_point`  (GuessWho.debug.dylib)
- 251 ms  `thunk for @escaping @callee_guaranteed @Sendable () -> ()`  (GuessWhoSync)
- 149 ms  `closure #1 in closure #1 in CNContactStoreAdapter.runOnWorkQueue<A>(_:)`  (GuessWhoSync)
- 77 ms  `closure #1 in CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)`  (GuessWhoSync)
