// Intent dispatch: routing, shared field checks, and the intents about connections and subscriptions.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

// PROTOCOL.md § Limits: filter and search queries.
static const NSUInteger SZFriendsQueryMax = 200;
// open_conversation with message_id grows the window toward the message at most this far.
static const NSUInteger SZFriendsHighlightWindowMax = 10000;
// message_status ids per subscription (PROTOCOL.md § Limits): a host follows only the few sends its cards show.
static const NSUInteger SZFriendsMessageStatusMax = 16;

@implementation SZFriendsIntentRouter

- (instancetype)initWithServices:(SZFriendsHelperServices *)services publisher:(SZFriendsPublisher *)publisher {
    if ((self = [super init])) {
        _services = services;
        _publisher = publisher;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)welcomeForClient:(SZFriendsClientContext *)client {
    SZFriendsAudience *audience = [[SZFriendsAudience alloc] init];
    audience.appName = client.appName;
    audience.revealIn = client.revealIn;
    audience.locale = client.locale;
    audience.capabilities = client.capabilities;
    audience.openFormats = client.openFormats;
    audience.timeZone = [NSTimeZone localTimeZone];
    NSArray<NSString *> *capabilities = SZFriendsHelperCapabilityList(self.services);
    audience.helperCapabilities = [NSSet setWithArray:capabilities];
    SZFriendsStrings *strings = [[SZFriendsStrings alloc] initWithAudience:audience];
    return @{@"capabilities" : capabilities, @"strings" : [strings staticStrings] ?: @{}};
}

#pragma mark - Dispatch

// Every intent of protocol 1.0 this helper implements. assistant_* belong to a family whose capability
// (assistant.scopes) it does not announce, so they are unknown_intent (PROTOCOL.md § Capabilities).
+ (NSSet<NSString *> *)knownIntents {
    static NSSet *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [NSSet setWithArray:@[
            @"ping", @"activate", @"subscribe", @"unsubscribe", @"set_filter", @"open_conversation", @"load_earlier",
            @"send_message", @"send_files", @"cancel_transfer", @"accept_offer", @"decline_offer", @"retry_item",
            @"accept_request", @"decline_request", @"cancel_request", @"send_request", @"add_by_id", @"block",
            @"unblock", @"remove_friend", @"mark_verified", @"accept_key_change", @"set_name", @"set_picture",
            @"set_auto_accept", @"dismiss_banner", @"start_visibility", @"stop_visibility", @"search_messages",
            @"delete_history", @"reset_friends", @"disable", @"cancel_message", @"add_from_mention", @"open_link",
            @"add_from_link", @"receive_link", @"make_download_link", @"reset_friend_link", @"revoke_link",
            @"join_profile", @"enter_join_code", @"cancel_join", @"approve_join", @"deny_join", @"revoke_device",
            @"rename_device", @"fetch_from_device", @"fetch_from_friend", @"set_received_folder"
        ]];
    });
    return known;
}

+ (NSSet<NSString *> *)devicesIntents {
    return [NSSet setWithArray:@[ @"revoke_device", @"rename_device", @"fetch_from_device", @"join_profile",
                                  @"enter_join_code", @"cancel_join", @"approve_join", @"deny_join" ]];
}

// What a removed computer still does: read, search, Start Over, leave.
+ (NSSet<NSString *> *)intentsOnRemovedComputer {
    return [NSSet setWithArray:@[ @"ping", @"activate", @"subscribe", @"unsubscribe", @"set_filter",
                                  @"open_conversation", @"load_earlier", @"search_messages", @"reset_friends",
                                  @"disable", @"dismiss_banner" ]];
}

// What still works while the identity key cannot be read (PROTOCOL.md identity_unavailable): reads, the reset
// that fixes it, and leaving.
+ (NSSet<NSString *> *)intentsWithoutIdentity {
    static NSSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSSet setWithArray:@[
            @"ping", @"activate", @"subscribe", @"unsubscribe", @"set_filter", @"open_conversation", @"load_earlier",
            @"search_messages", @"delete_history", @"reset_friends", @"disable", @"set_received_folder"
        ]];
    });
    return allowed;
}

// What works without a store: nothing that reads or writes Friends data.
+ (NSSet<NSString *> *)intentsWithoutStore {
    static NSSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed =
            [NSSet setWithArray:@[ @"ping", @"activate", @"subscribe", @"unsubscribe", @"set_filter", @"disable" ]];
    });
    return allowed;
}

- (void)connection:(SZFriendsIPCConnection *)connection
      handleIntent:(NSDictionary<NSString *, id> *)intent
             reply:(SZFriendsIntentReply)reply {
    NSString *type = intent[@"type"];
    if (![[[self class] knownIntents] containsObject:type]) {
        [self fail:reply code:@"unknown_intent" details:nil connection:connection];
        return;
    }
    if (self.services.store == nil && ![[[self class] intentsWithoutStore] containsObject:type]) {
        // A store a newer helper owns is not ours to touch: that is a state, not a bug.
        NSString *code = self.services.updateNeed == SZFriendsUpdateNeedStore ? @"not_allowed" : @"internal";
        [self fail:reply code:code details:nil connection:connection];
        return;
    }
    if (self.services.identity == nil && ![[[self class] intentsWithoutIdentity] containsObject:type]) {
        [self fail:reply code:@"identity_unavailable" details:nil connection:connection];
        return;
    }
    // One profile on several computers: only while the helper announces it (PROTOCOL.md § Capabilities).
    if ([[[self class] devicesIntents] containsObject:type] &&
        ![SZFriendsHelperCapabilityList(self.services) containsObject:@"devices"]) {
        [self fail:reply code:@"unknown_intent" details:nil connection:connection];
        return;
    }
    if ([type isEqualToString:@"fetch_from_friend"] &&
        ![SZFriendsHelperCapabilityList(self.services) containsObject:@"files.again"]) {
        [self fail:reply code:@"unknown_intent" details:nil connection:connection];
        return;
    }
    // A computer another of the person's computers removed reads, and sends or changes nothing (§ Devices).
    if (![[[self class] intentsOnRemovedComputer] containsObject:type] &&
        [self refusesOnRemovedComputer:reply connection:connection]) {
        return;
    }
    // Only names from the table above reach here, so a client cannot steer this to any other method.
    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"intent_%@:connection:reply:", type]);
    if (![self respondsToSelector:selector]) {
        [self fail:reply code:@"unknown_intent" details:nil connection:connection];
        return;
    }
    void (*handler)(id, SEL, NSDictionary *, SZFriendsIPCConnection *, SZFriendsIntentReply) =
        (void *)[self methodForSelector:selector];
    handler(self, selector, intent, connection, reply);
}

- (void)connectionDidClose:(SZFriendsIPCConnection *)connection {
    // Subscriptions die with their connection (PROTOCOL.md § Lifecycle, Reconnect).
    connection.dispatchState = nil;
}

#pragma mark - Shared helpers

- (void)fail:(SZFriendsIntentReply)reply
        code:(NSString *)code
     details:(nullable NSDictionary<NSString *, id> *)details
  connection:(SZFriendsIPCConnection *)connection {
    SZFriendsClientState *state = [self.publisher stateForConnection:connection];
    NSString *message = [state.strings messageForErrorCode:code details:details ?: @{}];
    reply(nil, code, message, details ?: @{});
}

- (void)succeed:(SZFriendsIntentReply)reply result:(nullable NSDictionary<NSString *, id> *)result {
    [self.publisher publishAllImmediately];
    reply(result ?: @{}, nil, nil, nil);
}

- (nullable NSString *)requiredString:(NSString *)key
                                   in:(NSDictionary *)intent
                            maxLength:(NSUInteger)maxLength
                                reply:(SZFriendsIntentReply)reply
                           connection:(SZFriendsIPCConnection *)connection {
    NSString *value = intent[key];
    if (!SZFriendsJSONIsString(value) || value.length == 0 || value.length > maxLength) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : key} connection:connection];
        return nil;
    }
    return value;
}

- (nullable SZFriendsPersonRecord *)personForIntent:(NSDictionary *)intent
                                              reply:(SZFriendsIntentReply)reply
                                         connection:(SZFriendsIPCConnection *)connection {
    NSString *conversationID = [self requiredString:@"conversation_id" in:intent maxLength:64 reply:reply
                                         connection:connection];
    if (conversationID == nil) return nil;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:conversationID];
    if (person == nil) {
        [self fail:reply code:@"not_found" details:@{@"field" : @"conversation_id"} connection:connection];
    }
    return person;
}

- (void)recordEvent:(NSString *)eventKind inConversation:(NSString *)conversationID {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = SZFriendsNewIdentifier();
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindEvent;
    item.direction = SZFriendsDirectionOutgoing;
    item.sentAt = [NSDate date];
    item.receivedAt = item.sentAt;
    item.eventKind = eventKind;
    NSError *error = nil;
    if (![self.services.store insertItem:item error:&error]) {
        SZFriendsHelperLog(@"could not record a %@ event: %@", eventKind, error.localizedDescription);
    }
}

- (SZFriendsOutboxEntry *)entryOfKind:(SZFriendsOutboxKind)kind conversationID:(NSString *)conversationID {
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = conversationID;
    entry.kind = kind;
    entry.state = SZFriendsOutboxStateQueued;
    entry.createdAt = [NSDate date];
    return entry;
}

- (BOOL)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
               item:(SZFriendsItemRecord *)item
        clientToken:(nullable NSString *)clientToken
              error:(NSError **)error {
    SZFriendsOutboxEntry *entry = [self entryOfKind:kind conversationID:conversationID];
    entry.itemID = item.itemID;
    entry.clientToken = clientToken;
    if (![self.services.outbox enqueue:entry item:item error:error]) return NO;
    [self.services.nearby outboxChangedForConversation:conversationID];
    return YES;
}

- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
               item:(SZFriendsItemRecord *)item
        clientToken:(nullable NSString *)clientToken {
    NSError *error = nil;
    if (![self enqueueKind:kind conversationID:conversationID item:item clientToken:clientToken error:&error]) {
        SZFriendsHelperLog(@"could not queue an outbox entry: %@", error.localizedDescription);
    }
}

- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
            payload:(nullable NSDictionary<NSString *, id> *)payload {
    SZFriendsOutboxEntry *entry = [self entryOfKind:kind conversationID:conversationID];
    if (payload != nil) entry.payload = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSError *error = nil;
    if (![self.services.outbox enqueue:entry error:&error]) {
        SZFriendsHelperLog(@"could not queue an outbox entry: %@", error.localizedDescription);
        return;
    }
    [self.services.nearby outboxChangedForConversation:conversationID];
}

#pragma mark - Connection and subscription intents

- (void)intent_ping:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
              reply:(SZFriendsIntentReply)reply {
    reply(@{}, nil, nil, nil);
}

- (void)intent_activate:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                  reply:(SZFriendsIntentReply)reply {
    // An identity that could not be read at start (a keychain still locked, say) is read again when the person opens
    // Friends; when it works, Nearby and the check-in start, and every client reconnects to see the helper whole.
    BOOL recovered = self.services.identity == nil && [self.services retryIdentity];
    if (recovered && self.onIdentityAvailable) self.onIdentityAvailable();
    // The person opened Friends: Nearby starts, which may show the permission prompts the first time (ADR 0004).
    [self.services.nearby activate];
    reply(@{}, nil, nil, nil);
    if (recovered && self.onReset) self.onReset();
}

- (void)intent_disable:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                 reply:(SZFriendsIntentReply)reply {
    reply(@{}, nil, nil, nil);
    if (self.onDisable) self.onDisable(connection);
}

- (void)intent_subscribe:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                   reply:(SZFriendsIntentReply)reply {
    NSString *view = intent[@"view"];
    NSMutableSet *views = [NSMutableSet setWithArray:@[ @"badge", @"list", @"nearby", @"details", @"profile",
                                                        @"settings", @"message_status", @"join" ]];
    if ([SZFriendsHelperCapabilityList(self.services) containsObject:@"received.folder"]) [views addObject:@"received"];
    if (!SZFriendsJSONIsString(view) || ![views containsObject:view]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"view"} connection:connection];
        return;
    }
    id params = intent[@"params"];
    if (params != nil && params != [NSNull null] && ![params isKindOfClass:[NSDictionary class]]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"params"} connection:connection];
        return;
    }
    NSString *conversationID = nil;
    if ([view isEqualToString:@"details"]) {
        conversationID = [params isKindOfClass:[NSDictionary class]] ? params[@"conversation_id"] : nil;
        if (!SZFriendsJSONIsString(conversationID) || conversationID.length == 0) {
            [self fail:reply code:@"invalid_field" details:@{@"field" : @"params.conversation_id"}
                connection:connection];
            return;
        }
        if ([self.services.store personWithConversationID:conversationID] == nil) {
            [self fail:reply code:@"not_found" details:@{@"field" : @"params.conversation_id"} connection:connection];
            return;
        }
    }
    NSArray<NSString *> *messageIDs = nil;
    if ([view isEqualToString:@"message_status"]) {
        messageIDs = [self messageIDsIn:params reply:reply connection:connection];
        if (messageIDs == nil) return;
    }
    [self subscribeView:view conversationID:conversationID messageIDs:messageIDs highlight:nil window:0
             connection:connection reply:reply];
}

// message_status's 1 to 16 ids, or nil after replying. Which of them are this person's outgoing messages is the
// snapshot's business: an id that names none (history deleted since) only has no row there, so subscribing again
// after a reconnect never fails over it.
- (nullable NSArray<NSString *> *)messageIDsIn:(id)params
                                         reply:(SZFriendsIntentReply)reply
                                    connection:(SZFriendsIPCConnection *)connection {
    id ids = [params isKindOfClass:[NSDictionary class]] ? params[@"message_ids"] : nil;
    BOOL valid = [ids isKindOfClass:[NSArray class]] && [ids count] > 0 && [ids count] <= SZFriendsMessageStatusMax;
    for (id identifier in valid ? ids : @[])
        valid = valid && SZFriendsJSONIsString(identifier) && [identifier length] > 0 && [identifier length] <= 64;
    if (!valid) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"params.message_ids"} connection:connection];
        return nil;
    }
    return ids;
}

- (void)subscribeView:(NSString *)view
       conversationID:(nullable NSString *)conversationID
           messageIDs:(nullable NSArray<NSString *> *)messageIDs
            highlight:(nullable NSString *)highlightItemID
               window:(NSUInteger)window
           connection:(SZFriendsIPCConnection *)connection
                reply:(SZFriendsIntentReply)reply {
    SZFriendsSubscription *subscription = [self.publisher addSubscriptionWithView:view conversationID:conversationID
                                                                     toConnection:connection];
    if (subscription == nil) {
        [self fail:reply code:@"too_many_subscriptions" details:nil connection:connection];
        return;
    }
    if (window > 0) subscription.window = window;
    subscription.highlightItemID = highlightItemID;
    subscription.messageIDs = messageIDs;
    SZFriendsClientState *state = [self.publisher stateForConnection:connection];
    // The first snapshot goes before the reply (PROTOCOL.md § Snapshots).
    if (![self.publisher sendSubscription:subscription toConnection:connection pass:nil]) {
        [state.subscriptions removeObjectForKey:subscription.subscriptionID];
        [self fail:reply code:@"not_found" details:nil connection:connection];
        return;
    }
    NSMutableDictionary *result = [@{@"subscription" : subscription.subscriptionID} mutableCopy];
    if ([view isEqualToString:@"conversation"]) {
        result[@"conversation_id"] = conversationID;
        // Opening marks it read, which changes the badge and list in every window.
        [self succeed:reply result:result];
        return;
    }
    reply(result, nil, nil, nil);
}

- (nullable SZFriendsSubscription *)subscriptionForIntent:(NSDictionary *)intent
                                               connection:(SZFriendsIPCConnection *)connection
                                                    reply:(SZFriendsIntentReply)reply {
    NSString *identifier = [self requiredString:@"subscription" in:intent maxLength:64 reply:reply
                                     connection:connection];
    if (identifier == nil) return nil;
    SZFriendsSubscription *subscription = [self.publisher stateForConnection:connection].subscriptions[identifier];
    if (subscription == nil) {
        [self fail:reply code:@"not_found" details:@{@"field" : @"subscription"} connection:connection];
    }
    return subscription;
}

- (void)intent_unsubscribe:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                     reply:(SZFriendsIntentReply)reply {
    SZFriendsSubscription *subscription = [self subscriptionForIntent:intent connection:connection reply:reply];
    if (subscription == nil) return;
    [[self.publisher stateForConnection:connection].subscriptions removeObjectForKey:subscription.subscriptionID];
    reply(@{}, nil, nil, nil);
}

- (void)intent_set_filter:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                    reply:(SZFriendsIntentReply)reply {
    SZFriendsSubscription *subscription = [self subscriptionForIntent:intent connection:connection reply:reply];
    if (subscription == nil) return;
    NSString *query = intent[@"query"];
    if (!SZFriendsJSONIsString(query) || query.length > SZFriendsQueryMax) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"query"} connection:connection];
        return;
    }
    if (![subscription.view isEqualToString:@"list"] && ![subscription.view isEqualToString:@"nearby"]) {
        [self fail:reply code:@"not_allowed" details:@{@"field" : @"subscription"} connection:connection];
        return;
    }
    subscription.query = query;
    [self.publisher sendSubscription:subscription toConnection:connection pass:nil];
    reply(@{}, nil, nil, nil);
}

- (void)intent_open_conversation:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                           reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    if (person == nil) return;
    id messageID = intent[@"message_id"];
    if (messageID == [NSNull null]) messageID = nil;
    if (messageID != nil && (!SZFriendsJSONIsString(messageID) || [messageID length] == 0)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"message_id"} connection:connection];
        return;
    }
    NSUInteger window = SZFriendsConversationWindow;
    if (messageID != nil) {
        // Grow the window like load_earlier until it holds the message, so the view can scroll to it.
        BOOL found = NO;
        for (;;) {
            BOOL hasEarlier = NO;
            NSArray<SZFriendsItemRecord *> *items = [self.services.store itemsInConversation:person.conversationID
                                                                                 beforeItemID:nil
                                                                                        limit:window
                                                                                   hasEarlier:&hasEarlier];
            for (SZFriendsItemRecord *item in items) found = found || [item.itemID isEqualToString:messageID];
            if (found || !hasEarlier || window >= SZFriendsHighlightWindowMax) break;
            window += SZFriendsConversationWindow;
        }
        if (!found) {
            [self fail:reply code:@"not_found" details:@{@"field" : @"message_id"} connection:connection];
            return;
        }
    }
    [self.services.store markConversationRead:person.conversationID error:NULL];
    [self.services.nearby conversationOpened:person.conversationID];
    [self subscribeView:@"conversation" conversationID:person.conversationID messageIDs:nil highlight:messageID
                 window:window connection:connection reply:reply];
}

- (void)intent_load_earlier:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    SZFriendsSubscription *subscription = [self subscriptionForIntent:intent connection:connection reply:reply];
    if (subscription == nil) return;
    if (![subscription.view isEqualToString:@"conversation"]) {
        [self fail:reply code:@"not_allowed" details:@{@"field" : @"subscription"} connection:connection];
        return;
    }
    subscription.window += SZFriendsConversationWindow;
    [self.publisher sendSubscription:subscription toConnection:connection pass:nil];
    reply(@{}, nil, nil, nil);
}

@end
