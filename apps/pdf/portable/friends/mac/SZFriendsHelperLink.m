// SZFriendsHelperLink: subscriptions that survive reconnects, replies matched to intents, the static strings.

#import "mac/SZFriendsLinkTransport.h"

void SZFriendsSpawnHelperInBackground(id<SZFriendsHost> host); // SZFriendsClientTransport.m

@implementation SZFriendsLinkError
- (instancetype)initWithCode:(NSString *)code message:(NSString *)message retryable:(BOOL)retryable
                     details:(NSDictionary *)details {
    if (!(self = [super init])) return nil;
    _code = [code copy];
    _message = [message copy];
    _retryable = retryable;
    _details = [details copy] ?: @{};
    return self;
}
@end

// One view subscription as the views see it: a stable local token, re-sent after every reconnect because helper
// subscription ids never survive one (PROTOCOL.md § Lifecycle, reconnect).
@interface SZFLinkSubscription : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *view;
@property(nonatomic, copy) NSDictionary *params;
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, copy) NSString *messageID;
@property(nonatomic, copy) NSString *filter;
@property(nonatomic) NSInteger earlierCount;
@property(nonatomic, copy) NSString *serverID;
@property(nonatomic, copy) SZFriendsSnapshotHandler handler;
@end
@implementation SZFLinkSubscription
@end

@interface SZFriendsHelperLink ()
@property(nonatomic, readwrite) SZFriendsLinkState state;
@property(nonatomic, readwrite, copy) NSString *statusText;
@property(nonatomic, readwrite, copy) NSSet<NSString *> *helperCapabilities;
@end

@implementation SZFriendsHelperLink {
    id<SZFriendsLinkTransport> _transport;
    NSMutableDictionary<NSString *, SZFLinkSubscription *> *_subscriptions;   // local token -> subscription
    NSMutableDictionary<NSString *, SZFLinkSubscription *> *_byServerID;      // helper subscription id -> same
    NSMutableDictionary<NSString *, NSString *> *_subscribeFrames;            // frame id -> local token
    NSMutableDictionary<NSString *, NSString *> *_abandonedFrames;            // frame id -> "" (unsubscribed early)
    NSMutableDictionary<NSString *, SZFriendsReplyHandler> *_replies;        // frame id -> reply handler
    NSMutableDictionary<NSString *, NSMutableArray *> *_earlySnapshots;       // helper id -> snapshots
    NSDictionary<NSString *, NSString *> *_strings;
    NSUInteger _nextToken;
}

+ (void)spawnHelperInBackgroundForHost:(id<SZFriendsHost>)host {
    SZFriendsSpawnHelperInBackground(host);
}

- (instancetype)initWithHost:(id<SZFriendsHost>)host {
    if (!(self = [super init])) return nil;
    [self setUpWithTransport:[[SZFriendsClientTransport alloc] initWithHost:host]];
    return self;
}

- (instancetype)initWithHost:(id<SZFriendsHost>)host transport:(id<SZFriendsLinkTransport>)transport {
    (void)host;
    if (!(self = [super init])) return nil;
    [self setUpWithTransport:transport];
    return self;
}

- (void)setUpWithTransport:(id<SZFriendsLinkTransport>)transport {
    _transport = transport;
    _transport.delegate = self;
    _subscriptions = [NSMutableDictionary new];
    _byServerID = [NSMutableDictionary new];
    _subscribeFrames = [NSMutableDictionary new];
    _abandonedFrames = [NSMutableDictionary new];
    _replies = [NSMutableDictionary new];
    _earlySnapshots = [NSMutableDictionary new];
    _strings = @{};
    _helperCapabilities = [NSSet set];
    _state = SZFriendsLinkStateIdle;
}

- (void)start {
    [_transport start];
}

- (void)stopDisablingFriends:(BOOL)disabling {
    [_transport stopDisablingFriends:disabling];
}

- (NSString *)staticStringForKey:(NSString *)key {
    NSString *value = _strings[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

#pragma mark - Subscriptions

- (NSString *)addSubscription:(SZFLinkSubscription *)subscription {
    subscription.token = [NSString stringWithFormat:@"v%lu", (unsigned long)++_nextToken];
    _subscriptions[subscription.token] = subscription;
    if (self.state == SZFriendsLinkStateReady) [self sendSubscribe:subscription];
    return subscription.token;
}

- (NSString *)subscribeToView:(NSString *)view params:(NSDictionary *)params handler:(SZFriendsSnapshotHandler)handler {
    SZFLinkSubscription *subscription = [SZFLinkSubscription new];
    subscription.view = view;
    subscription.params = params;
    subscription.handler = handler;
    return [self addSubscription:subscription];
}

- (NSString *)openConversation:(NSString *)conversationID messageID:(NSString *)messageID
                       handler:(SZFriendsSnapshotHandler)handler {
    SZFLinkSubscription *subscription = [SZFLinkSubscription new];
    subscription.view = @"conversation";
    subscription.conversationID = conversationID;
    subscription.messageID = messageID;
    subscription.handler = handler;
    return [self addSubscription:subscription];
}

- (void)sendSubscribe:(SZFLinkSubscription *)subscription {
    NSString *type = subscription.conversationID ? @"open_conversation" : @"subscribe";
    NSMutableDictionary *fields = [NSMutableDictionary new];
    if (subscription.conversationID) {
        fields[@"conversation_id"] = subscription.conversationID;
        if (subscription.messageID) fields[@"message_id"] = subscription.messageID;
    } else {
        fields[@"view"] = subscription.view;
        if (subscription.params) fields[@"params"] = subscription.params;
    }
    NSString *errorCode = nil;
    NSString *frameID = [_transport sendIntent:type fields:fields errorCode:&errorCode];
    if (frameID) _subscribeFrames[frameID] = subscription.token;
}

- (void)setFilter:(NSString *)query forSubscription:(NSString *)token {
    SZFLinkSubscription *subscription = _subscriptions[token];
    if (!subscription) return;
    subscription.filter = query;
    if (subscription.serverID)
        [self sendIntent:@"set_filter" fields:@{@"subscription" : subscription.serverID, @"query" : query ?: @""}
                   reply:nil];
}

- (void)loadEarlierForSubscription:(NSString *)token {
    SZFLinkSubscription *subscription = _subscriptions[token];
    if (!subscription) return;
    subscription.earlierCount += 1;
    if (subscription.serverID)
        [self sendIntent:@"load_earlier" fields:@{@"subscription" : subscription.serverID} reply:nil];
}

- (void)unsubscribe:(NSString *)token {
    SZFLinkSubscription *subscription = _subscriptions[token];
    if (!subscription) return;
    [_subscriptions removeObjectForKey:token];
    if (subscription.serverID) {
        [_byServerID removeObjectForKey:subscription.serverID];
        [self sendIntent:@"unsubscribe" fields:@{@"subscription" : subscription.serverID} reply:nil];
    }
    // A subscribe still in flight is answered later; its reply then unsubscribes at once.
    for (NSString *frameID in [_subscribeFrames allKeysForObject:token]) {
        [_subscribeFrames removeObjectForKey:frameID];
        _abandonedFrames[frameID] = @"";
    }
}

#pragma mark - Intents

- (void)failReply:(SZFriendsReplyHandler)reply code:(NSString *)code {
    if (!reply) return;
    SZFriendsLinkError *error = [[SZFriendsLinkError alloc] initWithCode:code message:self.statusText retryable:YES
                                                                 details:@{}];
    // Exactly once and never re-entrantly: a view may be mid-update when it sends.
    dispatch_async(dispatch_get_main_queue(), ^{ reply(nil, error); });
}

- (void)sendIntent:(NSString *)type fields:(NSDictionary *)fields reply:(SZFriendsReplyHandler)reply {
    if (self.state != SZFriendsLinkStateReady) {
        [self failReply:reply code:@"not_ready"];
        return;
    }
    NSString *errorCode = nil;
    NSString *frameID = [_transport sendIntent:type fields:fields ?: @{} errorCode:&errorCode];
    if (!frameID) {
        [self failReply:reply code:errorCode ?: @"internal"];
        return;
    }
    if (reply) _replies[frameID] = [reply copy];
}

#pragma mark - Transport delegate

- (void)transportDidChangeState:(SZFriendsLinkState)state statusText:(NSString *)statusText {
    SZFriendsLinkState previous = self.state;
    self.statusText = state == SZFriendsLinkStateReady ? nil : statusText;
    self.state = state;
    if (previous == SZFriendsLinkStateReady && state != SZFriendsLinkStateReady) {
        // The intent may or may not have reached the helper; sends carry a client_token, so a retry is safe.
        NSDictionary *pending = [_replies copy];
        [_replies removeAllObjects];
        for (NSString *frameID in pending) [self failReply:pending[frameID] code:@"connection_lost"];
        [_subscribeFrames removeAllObjects];
        [_abandonedFrames removeAllObjects];
    }
    if (state == SZFriendsLinkStateReady) {
        [_byServerID removeAllObjects];
        [_earlySnapshots removeAllObjects];
        for (SZFLinkSubscription *subscription in _subscriptions.allValues) {
            subscription.serverID = nil;
            [self sendSubscribe:subscription];
        }
    }
    if (self.onStateChange) self.onStateChange(state);
}

- (void)transportDidReceiveFrame:(NSDictionary *)frame {
    NSString *type = frame[@"type"];
    if (![type isKindOfClass:NSString.class]) return;
    if ([type isEqualToString:@"snapshot"]) [self receiveSnapshot:frame];
    else if ([type isEqualToString:@"reply"]) [self receiveReply:frame];
    else if ([type isEqualToString:@"welcome"]) [self receiveWelcome:frame];
    // goodbye: the client library reconnects by itself and reports the state; nothing for the views to do.
}

- (void)receiveWelcome:(NSDictionary *)frame {
    NSDictionary *strings = frame[@"strings"];
    _strings = [strings isKindOfClass:NSDictionary.class] ? [strings copy] : @{};
    NSArray *capabilities = frame[@"capabilities"];
    self.helperCapabilities = [capabilities isKindOfClass:NSArray.class] ? [NSSet setWithArray:capabilities]
                                                                         : [NSSet set];
}

- (void)receiveSnapshot:(NSDictionary *)frame {
    NSString *serverID = frame[@"subscription"];
    NSDictionary *data = frame[@"data"];
    if (![serverID isKindOfClass:NSString.class] || ![data isKindOfClass:NSDictionary.class]) return;
    SZFLinkSubscription *subscription = _byServerID[serverID];
    if (subscription) {
        subscription.handler(data, [frame[@"rev"] integerValue]);
        return;
    }
    // The first snapshot precedes its subscribe reply (PROTOCOL.md § Snapshots), so it waits for the mapping.
    // Only the newest matters: snapshots are complete, never diffs.
    _earlySnapshots[serverID] = [NSMutableArray arrayWithObject:frame];
}

- (void)receiveReply:(NSDictionary *)frame {
    NSString *frameID = frame[@"re"];
    if (![frameID isKindOfClass:NSString.class]) return;
    BOOL ok = [frame[@"ok"] boolValue];
    NSDictionary *result = [frame[@"result"] isKindOfClass:NSDictionary.class] ? frame[@"result"] : @{};
    NSString *token = _subscribeFrames[frameID];
    if (token || _abandonedFrames[frameID]) {
        [_subscribeFrames removeObjectForKey:frameID];
        BOOL abandoned = _abandonedFrames[frameID] != nil;
        [_abandonedFrames removeObjectForKey:frameID];
        [self subscriptionReply:token abandoned:abandoned ok:ok result:result];
        return;
    }
    SZFriendsReplyHandler reply = _replies[frameID];
    if (!reply) return;
    [_replies removeObjectForKey:frameID];
    if (ok) {
        reply(result, nil);
        return;
    }
    NSDictionary *error = [frame[@"error"] isKindOfClass:NSDictionary.class] ? frame[@"error"] : @{};
    NSString *code = [error[@"code"] isKindOfClass:NSString.class] ? error[@"code"] : @"internal";
    NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
    NSDictionary *details = [error[@"details"] isKindOfClass:NSDictionary.class] ? error[@"details"] : @{};
    reply(nil, [[SZFriendsLinkError alloc] initWithCode:code message:message retryable:[error[@"retryable"] boolValue]
                                                details:details]);
}

- (void)subscriptionReply:(NSString *)token abandoned:(BOOL)abandoned ok:(BOOL)ok result:(NSDictionary *)result {
    NSString *serverID = [result[@"subscription"] isKindOfClass:NSString.class] ? result[@"subscription"] : nil;
    if (!ok || !serverID) return; // views keep their last snapshot; the next reconnect subscribes again
    NSArray *early = _earlySnapshots[serverID];
    [_earlySnapshots removeObjectForKey:serverID];
    SZFLinkSubscription *subscription = token ? _subscriptions[token] : nil;
    if (abandoned || !subscription) {
        [self sendIntent:@"unsubscribe" fields:@{@"subscription" : serverID} reply:nil];
        return;
    }
    subscription.serverID = serverID;
    // A highlight belongs to the moment it was asked for, not to every reconnect afterwards.
    subscription.messageID = nil;
    _byServerID[serverID] = subscription;
    for (NSDictionary *frame in early) subscription.handler(frame[@"data"], [frame[@"rev"] integerValue]);
    if (subscription.filter.length)
        [self sendIntent:@"set_filter" fields:@{@"subscription" : serverID, @"query" : subscription.filter} reply:nil];
    for (NSInteger i = 0; i < subscription.earlierCount; i++)
        [self sendIntent:@"load_earlier" fields:@{@"subscription" : serverID} reply:nil];
}

@end
