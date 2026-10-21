// Deciding and wording notifications (SZFriendsNotify.h; ADR 0017 § What notifies, § What never notifies).
//
// Each commit point is called once, when an item first reaches this Mac's store, so a restart, a reconnect or a
// second client never posts again: nothing here re-reads the store for things to post. A burst (messages, or offers,
// committed in one conversation within a second) makes one notification; files offered together and accepted
// automatically make one once the last of them is received.

#import "service/notify/SZFriendsNotify.h"

#import "service/store/SZFriendsStoreSync.h"

// A friend's item that came by sync notifies only while this fresh (ADR 0017): older, another device of the person's
// already had it in front of them.
static const NSTimeInterval SZFriendsNotifySyncFreshness = 10 * 60;
// Requests and acceptances about one person within this long are one event: a friend link's acceptance comes as a
// link and then as the answer that carried it.
static const NSTimeInterval SZFriendsNotifyFriendshipWindow = 120;
// Notifications this helper remembers for a click or a reply after posting them.
static const NSUInteger SZFriendsNotifyRemembered = 256;

static NSString *SZFriendsNotifyTime(NSDate *date) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [formatter stringFromDate:date];
}

// Offers committed in one burst, by conversation.
@interface SZFriendsNotifyOfferBurst : NSObject
@property(nonatomic) NSMutableArray<SZFriendsTransferRecord *> *waiting;
@property(nonatomic) NSMutableArray<SZFriendsTransferRecord *> *automatic;
@end

@implementation SZFriendsNotifyOfferBurst
@end

// Files offered together and accepted automatically: notified once every one of them is settled.
@interface SZFriendsNotifyBatch : NSObject
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, copy) NSArray<NSString *> *transferIDs;
@end

@implementation SZFriendsNotifyBatch
@end

@implementation SZFriendsNotifier {
    SZFriendsStore *_store;
    SZFriendsTransfers *_transfers;
    dispatch_queue_t _queue;
    SZFriendsStrings *_strings;
    NSMutableDictionary<NSString *, NSDictionary *> *_posted;
    NSMutableArray<NSString *> *_postedOrder;
    // Conversations with notifications on screen that a read withdraws: YES once they were seen unread.
    NSMutableDictionary<NSString *, NSNumber *> *_delivered;
    NSMutableDictionary<NSString *, NSMutableArray<SZFriendsItemRecord *> *> *_messageBursts;
    NSMutableDictionary<NSString *, SZFriendsNotifyOfferBurst *> *_offerBursts;
    NSMutableArray<SZFriendsNotifyBatch *> *_batches;
    NSMutableSet<NSString *> *_seenJoins;
    NSMutableDictionary<NSString *, NSDate *> *_friendships;
}

- (instancetype)initWithStore:(SZFriendsStore *)store
                    transfers:(nullable SZFriendsTransfers *)transfers
                     settings:(SZFriendsNotifySettings *)settings
                       poster:(id<SZFriendsNotificationPoster>)poster
                        queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _store = store;
        _transfers = transfers;
        _settings = settings;
        _poster = poster;
        _queue = queue;
        _testHome = [poster isKindOfClass:[SZFriendsNotifyFileSink class]];
        _burstInterval = 1.0;
        SZFriendsAudience *audience = [[SZFriendsAudience alloc] init];
        audience.appName = @"Shenzhen Friends";
        audience.revealIn = @"Finder";
        audience.locale = @"en";
        audience.capabilities = [NSSet set];
        audience.openFormats = [NSSet set];
        audience.timeZone = [NSTimeZone localTimeZone];
        audience.helperCapabilities = [NSSet setWithObject:@"notifications"];
        _strings = [[SZFriendsStrings alloc] initWithAudience:audience];
        _posted = [NSMutableDictionary dictionary];
        _postedOrder = [NSMutableArray array];
        _delivered = [NSMutableDictionary dictionary];
        _messageBursts = [NSMutableDictionary dictionary];
        _offerBursts = [NSMutableDictionary dictionary];
        _batches = [NSMutableArray array];
        _seenJoins = [NSMutableSet set];
        _friendships = [NSMutableDictionary dictionary];
        __weak SZFriendsNotifier *weakSelf = self;
        poster.onResponse = ^(NSString *key, NSString *action, NSString *text, NSDictionary *request) {
            [weakSelf respondToKey:key action:action text:text request:request];
        };
    }
    return self;
}

#pragma mark - Settings and target

- (SZFriendsNotificationsFacts *)facts {
    SZFriendsNotificationsFacts *facts = [[SZFriendsNotificationsFacts alloc] init];
    facts.enabled = _settings.enabled;
    facts.preview = _settings.preview;
    facts.askDismissed = _settings.askDismissed;
    facts.used = _settings.used;
    switch (_poster.permission) {
    case SZFriendsNotifyPermissionGranted: facts.permission = SZFriendsNotifyPermissionFactsGranted; break;
    case SZFriendsNotifyPermissionDenied: facts.permission = SZFriendsNotifyPermissionFactsDenied; break;
    case SZFriendsNotifyPermissionNotAsked: facts.permission = SZFriendsNotifyPermissionFactsNotAsked; break;
    }
    return facts;
}

- (void)rememberAppID:(NSString *)appID urlScheme:(nullable NSString *)urlScheme appPath:(nullable NSString *)appPath {
    NSString *scheme = urlScheme ?: SZFriendsNotifyKnownScheme(appID);
    if (scheme.length == 0) return; // an app no click could open (a test client, a tool): the last real one stays
    SZFriendsNotifyTarget *target = [[SZFriendsNotifyTarget alloc] init];
    target.appID = appID;
    target.urlScheme = scheme;
    target.appPath = appPath;
    _settings.target = target;
}

- (void)askWithCompletion:(void (^)(void))completion {
    [_poster askWithCompletion:completion];
}

#pragma mark - Who may hear about what

- (BOOL)isFocused:(NSString *)conversationID {
    NSSet<NSString *> *focused = self.focusedConversations ? self.focusedConversations() : nil;
    return [focused containsObject:conversationID];
}

// The person a notification about `conversationID` is from, or nil when nothing about it may notify now.
- (nullable SZFriendsPersonRecord *)notifiablePersonFor:(NSString *)conversationID {
    if (!_settings.enabled || _poster.permission != SZFriendsNotifyPermissionGranted) return nil;
    if (conversationID.length == 0 || [conversationID isEqualToString:SZFriendsYouConversationID]) return nil;
    SZFriendsPersonRecord *person = [_store personWithConversationID:conversationID];
    if (person == nil || person.relation == SZFriendsRelationBlocked) return nil;
    if ([self isFocused:conversationID]) return nil;
    return person;
}

- (NSString *)titleFor:(SZFriendsPersonRecord *)person {
    return [_strings notificationTitleForName:person.name friendsID:person.friendsID];
}

#pragma mark - Posting

- (void)postKey:(NSString *)key
               kind:(NSString *)kind
            channel:(NSString *)channel
     conversationID:(nullable NSString *)conversationID
             thread:(NSString *)thread
              title:(NSString *)title
               body:(NSString *)body
               time:(NSDate *)time
          replyName:(nullable NSString *)replyName {
    SZFriendsNotifyTarget *target = _settings.target;
    id reply = [NSNull null];
    if (replyName != nil) {
        reply = @{
            @"label" : [_strings notificationText:@"notify.reply"],
            @"placeholder" : [_strings notificationReplyPlaceholderForName:replyName],
            @"send" : [_strings notificationText:@"notify.reply.send"]
        };
    }
    NSDictionary *request = @{
        @"key" : key,
        @"kind" : kind,
        @"channel" : channel,
        @"conversation_id" : conversationID ?: [NSNull null],
        @"thread" : thread,
        @"title" : title,
        @"body" : body,
        @"time" : SZFriendsNotifyTime(time),
        @"reply" : reply,
        @"open" : @{
            @"url" : [target URLForConversation:conversationID],
            @"app_id" : target.appID,
            @"app_path" : target.appPath ?: [NSNull null]
        }
    };
    if (_posted[key] == nil) [_postedOrder addObject:key];
    _posted[key] = request;
    while (_postedOrder.count > SZFriendsNotifyRemembered) {
        [_posted removeObjectForKey:_postedOrder.firstObject];
        [_postedOrder removeObjectAtIndex:0];
    }
    [_poster post:request];
}

// Messages and files: withdrawn once their conversation is read, here or on another device.
- (void)deliveredInConversation:(NSString *)conversationID {
    BOOL unread = [_store personWithConversationID:conversationID].unreadCount > 0;
    _delivered[conversationID] = @(unread || _delivered[conversationID].boolValue);
}

- (void)afterBurst:(void (^)(void))block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.burstInterval * NSEC_PER_SEC)), _queue, block);
}

#pragma mark - Messages

- (void)noteMessage:(SZFriendsItemRecord *)item {
    if (item.kind != SZFriendsItemKindMessage || item.direction != SZFriendsDirectionIncoming) return;
    if ([self notifiablePersonFor:item.conversationID] == nil) return;
    NSString *conversationID = item.conversationID;
    NSMutableArray *burst = _messageBursts[conversationID];
    if (burst != nil) {
        [burst addObject:item];
        return;
    }
    _messageBursts[conversationID] = [NSMutableArray arrayWithObject:item];
    __weak SZFriendsNotifier *weakSelf = self;
    [self afterBurst:^{ [weakSelf flushMessagesIn:conversationID]; }];
}

- (void)flushMessagesIn:(NSString *)conversationID {
    NSArray<SZFriendsItemRecord *> *items = _messageBursts[conversationID];
    [_messageBursts removeObjectForKey:conversationID];
    SZFriendsPersonRecord *person = [self notifiablePersonFor:conversationID];
    // Read meanwhile (opened, or read on another device), or now on screen: nothing to say.
    if (items.count == 0 || person == nil || person.unreadCount == 0) return;
    SZFriendsItemRecord *newest = items.lastObject;
    NSString *title = [self titleFor:person];
    NSString *body = _settings.preview ? [_strings notificationBodyForMessageText:newest.text ?: @"" count:1]
                                       : [_strings notificationBodyForMessageText:nil count:items.count];
    [self postKey:[@"message:" stringByAppendingString:newest.itemID] kind:@"message" channel:@"messages"
        conversationID:conversationID thread:conversationID title:title body:body time:newest.sentAt
             replyName:title];
    [self deliveredInConversation:conversationID];
}

// Whether an item that came by sync is still unread here: newer than the last one read (the unread count's newest).
- (BOOL)isUnread:(SZFriendsItemRecord *)item person:(SZFriendsPersonRecord *)person {
    if (person.unreadCount <= 0) return NO;
    SZFriendsItemRecord *lastRead = [_store incomingItemInConversation:item.conversationID
                                                            newerCount:(NSUInteger)person.unreadCount];
    if (lastRead == nil) return YES;
    NSComparisonResult order = [item.receivedAt compare:lastRead.receivedAt];
    return order == NSOrderedDescending ||
           (order == NSOrderedSame && [item.itemID compare:lastRead.itemID] == NSOrderedDescending);
}

- (void)noteSyncedItems:(NSArray<SZFriendsItemRecord *> *)items {
    NSDate *now = [NSDate date];
    for (SZFriendsItemRecord *arrived in items) {
        // Messages only: a file offered to another of the person's devices is answered there (its receiver lives
        // there), and the person's own messages, from any device, never notify.
        if (arrived.kind != SZFriendsItemKindMessage || arrived.direction != SZFriendsDirectionIncoming) continue;
        SZFriendsItemRecord *item = [_store itemWithID:arrived.itemID inConversation:arrived.conversationID] ?: arrived;
        SZFriendsPersonRecord *person = [self notifiablePersonFor:item.conversationID];
        if (person == nil || [now timeIntervalSinceDate:item.sentAt] > SZFriendsNotifySyncFreshness) continue;
        if (![self isUnread:item person:person]) continue;
        [self noteMessage:item];
    }
}

#pragma mark - Files

- (void)noteOffer:(SZFriendsTransferRecord *)transfer automatic:(BOOL)automatic {
    if (transfer.outgoing || [self notifiablePersonFor:transfer.conversationID] == nil) return;
    NSString *conversationID = transfer.conversationID;
    SZFriendsNotifyOfferBurst *burst = _offerBursts[conversationID];
    BOOL first = burst == nil;
    if (first) {
        burst = [[SZFriendsNotifyOfferBurst alloc] init];
        burst.waiting = [NSMutableArray array];
        burst.automatic = [NSMutableArray array];
        _offerBursts[conversationID] = burst;
    }
    [automatic ? burst.automatic : burst.waiting addObject:transfer];
    if (!first) return;
    __weak SZFriendsNotifier *weakSelf = self;
    [self afterBurst:^{ [weakSelf flushOffersIn:conversationID]; }];
}

- (void)flushOffersIn:(NSString *)conversationID {
    SZFriendsNotifyOfferBurst *burst = _offerBursts[conversationID];
    [_offerBursts removeObjectForKey:conversationID];
    if (burst.automatic.count > 0) {
        SZFriendsNotifyBatch *batch = [[SZFriendsNotifyBatch alloc] init];
        batch.conversationID = conversationID;
        batch.transferIDs = [burst.automatic valueForKey:@"transferID"];
        [_batches addObject:batch];
        [self settleBatches];
    }
    if (burst.waiting.count == 0) return;
    SZFriendsPersonRecord *person = [self notifiablePersonFor:conversationID];
    if (person == nil) return;
    // Still waiting for an answer: one accepted or declined on another device meanwhile is not news.
    NSMutableArray<SZFriendsTransferRecord *> *waiting = [NSMutableArray array];
    for (SZFriendsTransferRecord *offer in burst.waiting) {
        SZFriendsTransferRecord *now = [_transfers transferWithID:offer.transferID] ?: offer;
        if (now.state == SZFriendsTransferStateWaitingForYou) [waiting addObject:now];
    }
    if (waiting.count == 0) return;
    [self postFiles:waiting person:person offered:YES];
}

- (void)postFiles:(NSArray<SZFriendsTransferRecord *> *)files
           person:(SZFriendsPersonRecord *)person
          offered:(BOOL)offered {
    NSString *title = [self titleFor:person];
    NSArray *names = _settings.preview ? [files valueForKey:@"fileName"] : nil;
    NSString *body = [_strings notificationBodyForFiles:names count:files.count sender:title offered:offered];
    [self postKey:[@"file:" stringByAppendingString:files.firstObject.transferID] kind:@"file" channel:@"files"
        conversationID:person.conversationID thread:person.conversationID title:title body:body time:[NSDate date]
             replyName:nil];
    [self deliveredInConversation:person.conversationID];
}

- (void)noteTransferReceived:(NSString *)transferID {
    (void)transferID; // which batch it belongs to does not matter: every batch is looked at again
    [self settleBatches];
}

static BOOL SZFriendsNotifySettled(SZFriendsTransferState state) {
    return state == SZFriendsTransferStateReceived || state == SZFriendsTransferStateFailed ||
           state == SZFriendsTransferStateCancelled || state == SZFriendsTransferStateDeclined;
}

// A batch whose files are all received (or ended otherwise) posts once, naming what arrived.
- (void)settleBatches {
    for (SZFriendsNotifyBatch *batch in _batches.copy) {
        NSMutableArray<SZFriendsTransferRecord *> *received = [NSMutableArray array];
        BOOL settled = YES;
        for (NSString *transferID in batch.transferIDs) {
            SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
            if (record == nil) continue; // deleted with its history
            if (!SZFriendsNotifySettled(record.state)) settled = NO;
            if (record.state == SZFriendsTransferStateReceived) [received addObject:record];
        }
        if (!settled) continue;
        [_batches removeObject:batch];
        SZFriendsPersonRecord *person = [self notifiablePersonFor:batch.conversationID];
        if (person != nil && received.count > 0) [self postFiles:received person:person offered:NO];
    }
}

#pragma mark - Requests, links and joining

// One notification per friendship event: a friend link's acceptance arrives as the link and again as the answer.
- (BOOL)friendshipNotedRecently:(NSString *)conversationID {
    NSDate *noted = _friendships[conversationID];
    return noted != nil && -noted.timeIntervalSinceNow < SZFriendsNotifyFriendshipWindow;
}

- (void)postAbout:(SZFriendsPersonRecord *)person kind:(NSString *)kind bodyKey:(NSString *)bodyKey {
    if ([self notifiablePersonFor:person.conversationID] == nil) return;
    NSDate *now = [NSDate date];
    _friendships[person.conversationID] = now;
    NSString *key = [kind isEqualToString:@"link"]
                        ? [@"link:" stringByAppendingString:person.conversationID]
                        : [NSString stringWithFormat:@"request:%@:%lld", person.conversationID,
                                                     (long long)floor(now.timeIntervalSince1970)];
    [self postKey:key kind:kind channel:@"requests" conversationID:person.conversationID
           thread:person.conversationID title:[self titleFor:person] body:[_strings notificationText:bodyKey]
             time:now replyName:nil];
}

- (void)noteRequestFrom:(SZFriendsPersonRecord *)person {
    [self postAbout:person kind:@"request" bodyKey:@"notify.request"];
}

- (void)noteAcceptedBy:(SZFriendsPersonRecord *)person {
    if ([self friendshipNotedRecently:person.conversationID]) return;
    [self postAbout:person kind:@"request" bodyKey:@"notify.accepted"];
}

- (void)noteLinkUsedBy:(SZFriendsPersonRecord *)person {
    [self postAbout:person kind:@"link" bodyKey:@"notify.link.used"];
}

- (void)noteLinkAddedWith:(SZFriendsPersonRecord *)person {
    [self postAbout:person kind:@"link" bodyKey:@"notify.link.added"];
}

- (void)noteJoinRequest:(NSString *)joinID deviceName:(NSString *)deviceName {
    if ([_seenJoins containsObject:joinID]) return;
    [_seenJoins addObject:joinID];
    if (!_settings.enabled || _poster.permission != SZFriendsNotifyPermissionGranted) return;
    NSString *title = [_strings notificationJoinTitleForDevice:deviceName];
    [self postKey:[@"join:" stringByAppendingString:joinID] kind:@"join" channel:@"requests" conversationID:nil
           thread:@"join" title:title body:[_strings notificationText:@"notify.join.body"] time:[NSDate date]
        replyName:nil];
}

#pragma mark - Reads and responses

- (void)withdrawReadConversations {
    for (NSString *conversationID in _delivered.allKeys) {
        NSInteger unread = [_store personWithConversationID:conversationID].unreadCount;
        if (unread > 0) {
            _delivered[conversationID] = @YES;
        } else if (_delivered[conversationID].boolValue) {
            [_delivered removeObjectForKey:conversationID];
            [_poster withdrawThread:conversationID];
        }
    }
    // A batch whose last file failed or was cancelled settles here, with the next change.
    if (_batches.count > 0) [self settleBatches];
}

- (BOOL)respondToKey:(NSString *)key action:(NSString *)action text:(nullable NSString *)text {
    return [self respondToKey:key action:action text:text request:nil];
}

- (BOOL)respondToKey:(NSString *)key
              action:(NSString *)action
                text:(nullable NSString *)text
             request:(nullable NSDictionary *)given {
    // What this helper posted, or (after a restart) what the system kept with the notification.
    NSDictionary *request = _posted[key] ?: given;
    if (request == nil) return NO;
    id conversation = request[@"conversation_id"];
    NSString *conversationID = [conversation isKindOfClass:[NSString class]] ? conversation : nil;
    if ([action isEqualToString:@"reply"]) {
        if (conversationID == nil || text.length == 0 || ![request[@"kind"] isEqual:@"message"]) return NO;
        if (self.sendReply) self.sendReply(conversationID, text);
        return YES;
    }
    // A click goes to the app the person uses Friends from now, open on that conversation.
    SZFriendsNotifyTarget *target = _settings.target;
    [_poster openURL:[target URLForConversation:conversationID] appID:target.appID appPath:target.appPath];
    return YES;
}

@end
