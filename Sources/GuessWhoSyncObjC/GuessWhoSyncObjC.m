#import "GuessWhoSyncObjC.h"

#if __has_include(<Contacts/Contacts.h>)

NSArray<CNChangeHistoryEvent *> * _Nullable
GWSyncFetchContactChangeHistory(CNContactStore *store,
                                CNChangeHistoryFetchRequest *request,
                                NSData * _Nullable * _Nullable outToken,
                                NSError * _Nullable * _Nullable error) {
    NSError *fetchError = nil;
    CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *result =
        [store enumeratorForChangeHistoryFetchRequest:request error:&fetchError];
    if (result == nil) {
        if (error != NULL) {
            *error = fetchError;
        }
        return nil;
    }
    // Materialize the enumerator into an array so the Swift caller can walk it
    // (and call `acceptEventVisitor:` on each) in history order. The set is
    // bounded by the delta since the prior token, not the whole database.
    NSMutableArray<CNChangeHistoryEvent *> *events = [NSMutableArray array];
    for (CNChangeHistoryEvent *event in result.value) {
        [events addObject:event];
    }
    if (outToken != NULL) {
        *outToken = result.currentHistoryToken;
    }
    return events;
}

#endif
