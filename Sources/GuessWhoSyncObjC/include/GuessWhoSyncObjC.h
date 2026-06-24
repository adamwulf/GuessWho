#import <Foundation/Foundation.h>

#if __has_include(<Contacts/Contacts.h>)
#import <Contacts/Contacts.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin shim over `-[CNContactStore enumeratorForChangeHistoryFetchRequest:error:]`,
/// which is marked `NS_SWIFT_UNAVAILABLE` and therefore cannot be called from
/// pure Swift. The shim runs the fetch, collects the change-history events into
/// an ordered array, and reports the resulting history token. The Swift side
/// still does all event classification via the `CNChangeHistoryEventVisitor`
/// protocol (`-[CNChangeHistoryEvent acceptEventVisitor:]`, which IS imported
/// into Swift) — this shim exists only to bridge the one unavailable call.
///
/// @param store The contact store to read history from.
/// @param request A configured change-history fetch request.
/// @param outToken On success, set to the current history token (may be nil).
/// @param error On failure, set to the underlying `NSError`.
/// @return The change-history events in history order, or nil on failure.
NSArray<CNChangeHistoryEvent *> * _Nullable
GWSyncFetchContactChangeHistory(CNContactStore *store,
                                CNChangeHistoryFetchRequest *request,
                                NSData * _Nullable * _Nullable outToken,
                                NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#endif
