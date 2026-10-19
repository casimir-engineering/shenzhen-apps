// SZFriendsServicesProvider: what Friends offers the host's own features, backed by the link.
//
// Cmd+K search and citations open the dropdown at a message; scoped chat access serves one assistant request that
// explicitly brought chats in (brief § AI boundaries). A host that does not claim friendsAssistantReadsChats gets
// not_allowed without the helper being asked, so an M1 host exporting search never also gains chat access.

#import "mac/SZFriendsDropdownInternal.h"

static NSString *const SZFServicesErrorDomain = @"SZFriendsServices";

static NSError *SZFServicesError(SZFriendsLinkError *error, NSString *fallbackCode) {
    NSString *code = error.code ?: fallbackCode;
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:code forKey:@"code"];
    if (error.message.length) info[NSLocalizedDescriptionKey] = error.message;
    return [NSError errorWithDomain:SZFServicesErrorDomain code:1 userInfo:info];
}

@interface SZFriendsChatScopeHandle : NSObject <SZFriendsChatScope>
- (instancetype)initWithLink:(SZFriendsHelperLink *)link scopeID:(NSString *)scopeID;
@end

@implementation SZFriendsChatScopeHandle {
    SZFriendsHelperLink *_link;
    NSString *_scopeID;
    BOOL _closed;
}

- (instancetype)initWithLink:(SZFriendsHelperLink *)link scopeID:(NSString *)scopeID {
    if (!(self = [super init])) return nil;
    _link = link;
    _scopeID = [scopeID copy];
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)searchFor:(NSString *)query completion:(SZFriendsScopeSearchCompletion)completion {
    if (_closed) {
        completion(@[], SZFServicesError(nil, @"scope_invalid"));
        return;
    }
    [_link sendIntent:@"assistant_search" fields:@{@"scope_id" : _scopeID, @"query" : query ?: @""}
                reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                    NSError *failure = error ? SZFServicesError(error, @"internal") : nil;
                    completion(error ? @[] : SZFArr(result, @"results"), failure);
                }];
}

- (void)readAroundMessage:(NSString *)messageID completion:(SZFriendsScopeReadCompletion)completion {
    if (_closed) {
        completion(nil, SZFServicesError(nil, @"scope_invalid"));
        return;
    }
    [_link sendIntent:@"assistant_read" fields:@{@"scope_id" : _scopeID, @"message_id" : messageID ?: @""}
                reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                    completion(error ? nil : result, error ? SZFServicesError(error, @"internal") : nil);
                }];
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    [_link sendIntent:@"assistant_close_scope" fields:@{@"scope_id" : _scopeID} reply:nil];
}

@end

@implementation SZFriendsServicesProvider {
    SZFriendsContext *_context;
    __weak SZFriendsDropdownController *_controller;
}

- (instancetype)initWithContext:(SZFriendsContext *)context controller:(SZFriendsDropdownController *)controller {
    if (!(self = [super init])) return nil;
    _context = context;
    _controller = controller;
    return self;
}

- (void)searchMessages:(NSString *)query limit:(NSUInteger)limit
            completion:(void (^)(NSArray<SZFriendsSearchResult *> *))completion {
    NSDictionary *fields = @{@"query" : query ?: @"", @"limit" : @(MAX(1u, MIN(limit, 50u)))};
    [_context.link sendIntent:@"search_messages" fields:fields
                        reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        NSMutableArray *results = [NSMutableArray array];
        if (!error) {
            for (NSDictionary *entry in SZFArr(result, @"results")) {
                SZFriendsSearchResult *item = [SZFriendsSearchResult new];
                item.conversationID = SZFStr(entry, @"conversation_id") ?: @"";
                item.messageID = SZFStr(entry, @"message_id") ?: @"";
                item.conversationTitle = SZFStr(entry, @"conversation_title") ?: @"";
                item.timeLabel = SZFStr(entry, @"time_label") ?: @"";
                item.senderLabel = SZFStr(entry, @"sender_label") ?: @"";
                item.excerpt = SZFArr(entry, @"excerpt");
                [results addObject:item];
            }
        }
        completion(results);
    }];
}

- (void)showMessage:(NSString *)messageID inConversation:(NSString *)conversationID {
    [_controller showConversation:conversationID highlightMessage:messageID];
}

- (void)openChatScopeForConversations:(NSArray<NSString *> *)conversationIDs
                           completion:(void (^)(id<SZFriendsChatScope>, NSError *))completion {
    id<SZFriendsHost> host = _context.host;
    BOOL allowed = [host respondsToSelector:@selector(friendsAssistantReadsChats)] && host.friendsAssistantReadsChats;
    if (!allowed) {
        completion(nil, SZFServicesError(nil, @"not_allowed"));
        return;
    }
    NSDictionary *scope = conversationIDs ? @{@"kind" : @"conversations", @"conversation_ids" : conversationIDs}
                                          : @{@"kind" : @"all"};
    SZFriendsHelperLink *link = _context.link;
    [link sendIntent:@"assistant_open_scope" fields:@{@"scope" : scope}
               reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                   NSString *scopeID = SZFStr(result, @"scope_id");
                   if (error || !scopeID) {
                       completion(nil, SZFServicesError(error, @"internal"));
                       return;
                   }
                   completion([[SZFriendsChatScopeHandle alloc] initWithLink:link scopeID:scopeID], nil);
               }];
}

@end
