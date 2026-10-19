// Friends messages in Cmd+K: a local search through the helper (no network), shown as their own palette section.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacFriendsPalette.h"

@implementation ShenzhenMacDelegate (SPDFMacFriendsPalette)

- (void)friendsSearchPaletteQuery:(NSString*)query progress:(NSProgress*)progress
                          publish:(void (^)(NSArray<NSDictionary*>* rows))publish {
    id<SZFriendsServices> services = [self friendsState].services;
    NSString* trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Friends off, not connected yet, or nothing typed: no section, and the helper is not asked.
    if (!services || !trimmed.length) return;
    void (^deliver)(NSArray*) = [publish copy];
    [services searchMessages:trimmed limit:SPDFMacFriendsPaletteLimit
                  completion:^(NSArray<SZFriendsSearchResult*>* results) {
        dispatch_block_t finish = ^{ if (!progress.cancelled) deliver(SPDFMacFriendsPaletteRows(results ?: @[])); };
        if (NSThread.isMainThread) finish(); else dispatch_async(dispatch_get_main_queue(), finish);
    }];
}

- (BOOL)friendsOpenPaletteResult:(NSDictionary*)result {
    if (!SPDFMacFriendsPaletteRowIsFriends(result)) return NO;
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (state.services) [state.services showMessage:result[@"messageID"] inConversation:result[@"conversationID"]];
    else [state.dropdown showConversation:result[@"conversationID"] highlightMessage:result[@"messageID"]];
    return YES;
}

@end
