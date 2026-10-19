#import "SPDFMacFriendsLinkSender.h"

NSString* const SPDFMacFriendsMessageStatusCapability = @"messages.status";

@implementation SPDFMacFriendsLinkSender {
    __weak SZFriendsHelperLink* _link; // the reader owns the link; a stale sender must not keep it alive
}

- (instancetype)initWithLink:(SZFriendsHelperLink*)link {
    if (!(self = [super init])) return nil;
    _link = link;
    return self;
}

- (BOOL)friendsReady { return _link.state == SZFriendsLinkStateReady; }
- (NSSet<NSString*>*)helperCapabilities { return _link.helperCapabilities ?: [NSSet set]; }
- (NSString*)staticStringForKey:(NSString*)key { return [_link staticStringForKey:key]; }

- (void)sendIntent:(NSString*)type fields:(NSDictionary*)fields reply:(SPDFMacFriendsIntentReply)reply {
    SZFriendsHelperLink* link = _link;
    SPDFMacFriendsIntentReply done = [reply copy];
    if (!link) {
        // Friends was turned off since the request began: nothing was sent.
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"not_ready", nil); });
        return;
    }
    [link sendIntent:type fields:fields reply:^(NSDictionary* result, SZFriendsLinkError* error) {
        if (error) done(nil, error.code.length ? error.code : @"internal", error.message);
        else done(result ?: @{}, nil, nil);
    }];
}

// PROTOCOL.md § Views, message_status: outgoing messages' status without opening their conversation, because
// open_conversation would mark the friend's chat read from AI chat, behind the person's back.
// Snapshot data: {"messages": [{"message_id", "status": {"state", "label"}}]}.
- (id)watchMessages:(NSArray<NSString*>*)messageIDs handler:(SPDFMacFriendsStatusHandler)handler {
    SZFriendsHelperLink* link = _link;
    if (!link || !messageIDs.count || ![link.helperCapabilities containsObject:SPDFMacFriendsMessageStatusCapability])
        return nil;
    SPDFMacFriendsStatusHandler deliver = [handler copy];
    return [link subscribeToView:@"message_status" params:@{@"message_ids" : messageIDs}
                         handler:^(NSDictionary* data, NSInteger rev) {
        (void)rev;
        NSMutableDictionary* statuses = [NSMutableDictionary dictionary];
        id messages = [data isKindOfClass:NSDictionary.class] ? data[@"messages"] : nil;
        for (NSDictionary* message in [messages isKindOfClass:NSArray.class] ? messages : @[]) {
            if (![message isKindOfClass:NSDictionary.class]) continue;
            id identifier = message[@"message_id"], status = message[@"status"];
            if ([identifier isKindOfClass:NSString.class] && [status isKindOfClass:NSDictionary.class])
                statuses[identifier] = status;
        }
        deliver(statuses);
    }];
}

- (void)stopWatching:(id)watch {
    // Later, not inside the snapshot that may have led here: the link is still delivering it.
    __weak SZFriendsHelperLink* weakLink = _link;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakLink unsubscribe:watch]; });
}

@end
