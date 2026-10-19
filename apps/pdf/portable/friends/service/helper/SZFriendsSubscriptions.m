// Subscriptions and snapshot publishing (SZFriendsSubscriptions.h).

#import "service/helper/SZFriendsSubscriptions.h"

#import "client/szfriends_client.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"
#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

const NSUInteger SZFriendsMaxSubscriptions = 32;
const NSUInteger SZFriendsConversationWindow = 200;

// PROTOCOL.md § Snapshots: at most 10 snapshots per second per subscription.
static const CFTimeInterval SZFriendsSnapshotInterval = 0.1;

@implementation SZFriendsSubscription
@end

@implementation SZFriendsClientState {
    NSUInteger _nextSubscription;
}

- (instancetype)initWithClient:(SZFriendsClientContext *)client animalSet:(nullable SZFriendsAnimalSet *)animalSet {
    if ((self = [super init])) {
        SZFriendsAudience *audience = [[SZFriendsAudience alloc] init];
        audience.appName = client.appName;
        audience.revealIn = client.revealIn;
        audience.locale = client.locale;
        audience.capabilities = client.capabilities;
        audience.openFormats = client.openFormats;
        audience.timeZone = [NSTimeZone localTimeZone];
        _audience = audience;
        _strings = [[SZFriendsStrings alloc] initWithAudience:audience];
        _builder = [[SZFriendsSnapshotBuilder alloc] initWithStrings:_strings audience:audience];
        // The set loaded at start, not the bundle's current one: the updater may replace the bundle meanwhile.
        _builder.animalSet = animalSet;
        _subscriptions = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)nextSubscriptionID {
    return [NSString stringWithFormat:@"s_%lu", (unsigned long)++_nextSubscription];
}

@end

@implementation SZFriendsPublisher {
    SZFriendsHelperServices *_services;
    __weak SZFriendsIPCServer *_server;
    dispatch_queue_t _queue;
    dispatch_source_t _tickTimer;
    dispatch_source_t _midnightTimer;
    dispatch_source_t _hourlyTimer;
    BOOL _ticking;
}

- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                          server:(SZFriendsIPCServer *)server
                           queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _services = services;
        _server = server;
        _queue = queue;
    }
    return self;
}

- (nullable SZFriendsClientState *)stateForConnection:(SZFriendsIPCConnection *)connection {
    if (connection.client == nil) return nil;
    if (![connection.dispatchState isKindOfClass:[SZFriendsClientState class]]) {
        connection.dispatchState = [[SZFriendsClientState alloc] initWithClient:connection.client
                                                                      animalSet:_services.resources.animalSet];
    }
    return connection.dispatchState;
}

- (nullable SZFriendsSubscription *)addSubscriptionWithView:(NSString *)view
                                             conversationID:(nullable NSString *)conversationID
                                               toConnection:(SZFriendsIPCConnection *)connection {
    SZFriendsClientState *state = [self stateForConnection:connection];
    if (state == nil || state.subscriptions.count >= SZFriendsMaxSubscriptions) return nil;
    SZFriendsSubscription *subscription = [[SZFriendsSubscription alloc] init];
    subscription.subscriptionID = [state nextSubscriptionID];
    subscription.view = view;
    subscription.conversationID = conversationID;
    subscription.query = @"";
    subscription.window = SZFriendsConversationWindow;
    state.subscriptions[subscription.subscriptionID] = subscription;
    return subscription;
}

- (nullable NSDictionary<NSString *, id> *)dataForSubscription:(SZFriendsSubscription *)subscription
                                                         state:(SZFriendsClientState *)state
                                                          pass:(SZFriendsFactsPass *)pass {
    SZFriendsSnapshotBuilder *builder = state.builder;
    // Worded for what the helper does now: once online works, "Not connected right now", not "Not nearby".
    state.audience.helperCapabilities = pass.helperCapabilities;
    // Mentions resolve against the facts this very snapshot shows (PROTOCOL.md § Mentions).
    builder.mentionDirectory = pass.mentionDirectory;
    builder.devices = pass.devices; // several computers, while the helper announces devices
    NSString *view = subscription.view;
    // Join requests (PROTOCOL.md § Joining) wait at the top of the list and count on the badge.
    SZFriendsNearbyService *nearby = _services.nearby;
    NSArray<SZFriendsJoinRequestFacts *> *joins = nearby ? [nearby joinRequestFacts] : @[];
    if ([view isEqualToString:@"badge"]) return [builder badgeWithPeople:pass.people joinRequests:joins];
    if ([view isEqualToString:@"list"]) {
        NSMutableDictionary *list = [[builder listWithPeople:pass.people previewItems:pass.previewItems
                                                     profile:pass.profile query:subscription.query now:pass.now]
            mutableCopy];
        if (pass.devices == nil) return list;
        list[@"join_requests"] = [builder joinRequestRowsWithFacts:joins now:pass.now];
        return [builder listWithDevices:list people:pass.people query:subscription.query now:pass.now];
    }
    if ([view isEqualToString:@"join"]) {
        return [builder joinWithFacts:nearby ? [nearby joiningFacts] : [SZFriendsJoiningFacts new]];
    }
    if ([view isEqualToString:@"nearby"]) {
        return [builder nearbyWithFacts:pass.nearby profile:pass.profile query:subscription.query now:pass.now];
    }
    if ([view isEqualToString:@"profile"]) {
        return [builder profileWithFacts:[pass profileWithLinks] waitingElsewhere:[pass waitingCountExcluding:nil]];
    }
    if ([view isEqualToString:@"settings"]) return [builder settingsWithProfile:pass.profile people:pass.people];
    if ([view isEqualToString:@"message_status"]) {
        NSMutableDictionary<NSString *, SZFriendsPersonFacts *> *people = [NSMutableDictionary dictionary];
        for (SZFriendsPersonFacts *person in pass.people) people[person.conversationID] = person;
        return [builder messageStatusWithMessages:[pass outgoingMessagesWithIDs:subscription.messageIDs ?: @[]]
                                           people:people];
    }
    NSString *conversationID = subscription.conversationID;
    SZFriendsPersonFacts *person = conversationID ? [pass personWithConversationID:conversationID] : nil;
    if (person == nil) return nil; // deleted meanwhile (Reset Friends); the client is told by goodbye
    NSInteger waiting = [pass waitingCountExcluding:conversationID];
    if ([view isEqualToString:@"details"]) {
        return [builder detailsForPerson:person waitingElsewhere:waiting now:pass.now];
    }
    BOOL hasEarlier = NO;
    NSArray *items = [pass itemsInConversation:conversationID window:subscription.window hasEarlier:&hasEarlier];
    return [builder conversationForPerson:person items:items hasEarlier:hasEarlier
                          highlightItemID:subscription.highlightItemID waitingElsewhere:waiting now:pass.now];
}

- (BOOL)sendSubscription:(SZFriendsSubscription *)subscription
            toConnection:(SZFriendsIPCConnection *)connection
                    pass:(nullable SZFriendsFactsPass *)pass {
    SZFriendsClientState *state = [self stateForConnection:connection];
    if (state == nil) return NO;
    if (pass == nil) pass = [[SZFriendsFactsPass alloc] initWithServices:_services now:[NSDate date]];
    NSDictionary *data = [self dataForSubscription:subscription state:state pass:pass];
    if (data == nil) return NO;
    // A window of 200 long messages can exceed the 8 MiB frame cap (each message's text travels twice, as text and
    // as segments). Rather than drop the snapshot and leave the view stale, show fewer items: the view then offers
    // load_earlier for the rest.
    while ([subscription.view isEqualToString:@"conversation"] && subscription.window > 1 &&
           ![self dataFits:data subscription:subscription]) {
        subscription.window = MAX((NSUInteger)1, subscription.window / 2);
        data = [self dataForSubscription:subscription state:state pass:pass];
        if (data == nil) return NO;
    }
    if (subscription.rev > 0 && [data isEqual:subscription.lastData]) return YES;
    subscription.rev += 1;
    subscription.lastData = data;
    subscription.lastSentAt = CFAbsoluteTimeGetCurrent();
    [connection sendFrame:@{
        @"type" : @"snapshot",
        @"subscription" : subscription.subscriptionID,
        @"view" : subscription.view,
        @"rev" : @(subscription.rev),
        @"data" : data,
    }];
    return YES;
}

- (BOOL)dataFits:(NSDictionary *)data subscription:(SZFriendsSubscription *)subscription {
    NSDictionary *frame = @{@"type" : @"snapshot", @"subscription" : subscription.subscriptionID,
                            @"view" : subscription.view, @"rev" : @(subscription.rev + 1), @"data" : data};
    NSData *json = [NSJSONSerialization isValidJSONObject:frame]
                       ? [NSJSONSerialization dataWithJSONObject:frame options:NSJSONWritingWithoutEscapingSlashes
                                                           error:NULL]
                       : nil;
    return json != nil && json.length <= SZFRIENDS_MAX_FRAME_BYTES;
}

// A conversation on screen is read: new items in it never count as unread while it is subscribed. Only a
// conversation subscription counts; message_status follows sent messages from elsewhere (AI chat) and reads nothing.
- (void)markSubscribedConversationsRead {
    SZFriendsStore *store = _services.store;
    if (store == nil) return;
    NSMutableSet<NSString *> *open = [NSMutableSet set];
    for (SZFriendsIPCConnection *connection in _server.connections) {
        SZFriendsClientState *state = [self stateForConnection:connection];
        for (SZFriendsSubscription *subscription in state.subscriptions.allValues) {
            if ([subscription.view isEqualToString:@"conversation"] && subscription.conversationID != nil) {
                [open addObject:subscription.conversationID];
            }
        }
    }
    for (NSString *conversationID in open) {
        if ([store personWithConversationID:conversationID].unreadCount > 0) {
            [store markConversationRead:conversationID error:NULL];
        }
    }
}

- (void)publishAllImmediately {
    [self publishViews:nil rateLimited:NO];
}

- (void)publishAllCoalesced {
    [self publishViews:nil rateLimited:YES];
}

// `views` nil means every view; the countdown tick names only Nearby, so the other views are not rebuilt each second.
- (void)publishViews:(nullable NSSet<NSString *> *)views rateLimited:(BOOL)rateLimited {
    [self markSubscribedConversationsRead];
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:_services now:[NSDate date]];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (SZFriendsIPCConnection *connection in _server.connections) {
        SZFriendsClientState *state = [self stateForConnection:connection];
        for (SZFriendsSubscription *subscription in state.subscriptions.allValues) {
            if (views != nil && ![views containsObject:subscription.view]) continue;
            CFTimeInterval since = now - subscription.lastSentAt;
            if (rateLimited && since < SZFriendsSnapshotInterval) {
                [self deferSubscription:subscription connection:connection after:SZFriendsSnapshotInterval - since];
                continue;
            }
            [self sendSubscription:subscription toConnection:connection pass:pass];
        }
    }
    [self scheduleTimers];
}

- (void)deferSubscription:(SZFriendsSubscription *)subscription
               connection:(SZFriendsIPCConnection *)connection
                    after:(CFTimeInterval)delay {
    if (subscription.deferred) return;
    subscription.deferred = YES;
    __weak SZFriendsPublisher *weakSelf = self;
    __weak SZFriendsIPCConnection *weakConnection = connection;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        subscription.deferred = NO;
        SZFriendsIPCConnection *strongConnection = weakConnection;
        SZFriendsClientState *state = strongConnection.dispatchState;
        // Still subscribed? An unsubscribe or a closed connection meanwhile drops the deferred send.
        if (state.subscriptions[subscription.subscriptionID] != subscription) return;
        [weakSelf sendSubscription:subscription toConnection:strongConnection pass:nil];
    });
}

#pragma mark - Timers

// While visible, Nearby's countdown changes every second; when the deadline passes, visibility ends on its own.
// Time labels ("Today" becoming "Yesterday") change at local midnight.
- (void)scheduleTimers {
    NSDate *deadline = _services.store.visibilityDeadline;
    BOOL visible = deadline != nil && deadline.timeIntervalSinceNow > 0;
    if (deadline != nil && !visible) {
        _services.store.visibilityDeadline = nil; // expired while nobody looked; never extended (PROTOCOL.md)
    }
    if (visible && !_ticking) {
        _ticking = YES;
        if (_tickTimer == nil) {
            _tickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
            __weak SZFriendsPublisher *weakSelf = self;
            dispatch_source_set_event_handler(_tickTimer, ^{ [weakSelf visibilityTick]; });
            dispatch_resume(_tickTimer);
        }
        dispatch_source_set_timer(_tickTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC,
                                  50 * NSEC_PER_MSEC);
    } else if (!visible && _ticking) {
        _ticking = NO;
        dispatch_source_set_timer(_tickTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    }
    if (_hourlyTimer == nil) {
        // Outbox and request expiry run hourly: an item crossing 30 days unsent turns Failed within the hour, and a
        // request unanswered for 14 days lapses within the hour.
        _hourlyTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        __weak SZFriendsPublisher *weakSelf = self;
        dispatch_source_set_event_handler(_hourlyTimer, ^{ [weakSelf hourly]; });
        dispatch_source_set_timer(_hourlyTimer, dispatch_time(DISPATCH_TIME_NOW, 3600 * NSEC_PER_SEC),
                                  3600 * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
        dispatch_resume(_hourlyTimer);
    }
    if (_midnightTimer == nil) {
        _midnightTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        __weak SZFriendsPublisher *weakSelf = self;
        dispatch_source_set_event_handler(_midnightTimer, ^{ [weakSelf midnight]; });
        dispatch_resume(_midnightTimer);
        [self armMidnightTimer];
    }
}

- (void)visibilityTick {
    // When the deadline passes, every view may change (the list's rows can show it too); otherwise only Nearby.
    NSDate *deadline = _services.store.visibilityDeadline;
    BOOL expired = deadline == nil || deadline.timeIntervalSinceNow <= 0;
    [self publishViews:expired ? nil : [NSSet setWithObject:@"nearby"] rateLimited:YES];
}

- (void)armMidnightTimer {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    // By calendar day, not 86,400 s: a day with a daylight-saving change is 23 or 25 hours long.
    NSDate *tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay
                                            value:1
                                           toDate:[calendar startOfDayForDate:[NSDate date]]
                                          options:0];
    // Wall-clock based, so a Mac that slept through midnight still refreshes when it wakes. One second late so
    // the labels are computed on the new day.
    struct timespec when = {.tv_sec = (time_t)(tomorrow.timeIntervalSince1970 + 1), .tv_nsec = 0};
    dispatch_source_set_timer(_midnightTimer, dispatch_walltime(&when, 0), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
}

- (void)hourly {
    [_services expireOutbox];
    // A lapsed request's key stops matching anything we advertise or accept at once.
    BOOL incoming = [_services expireIncomingRequests], outgoing = [_services expireOutgoingRequests];
    if (incoming || outgoing) [_services.nearby peopleChanged];
    [self publishAllCoalesced];
}

- (void)midnight {
    [self armMidnightTimer];
    [self publishAllCoalesced];
}

- (void)stop {
    if (_tickTimer != nil) dispatch_source_cancel(_tickTimer);
    if (_midnightTimer != nil) dispatch_source_cancel(_midnightTimer);
    if (_hourlyTimer != nil) dispatch_source_cancel(_hourlyTimer);
}

@end
