// Friends reached over the Internet (SZFriendsOnlineDriver.h): the nearby service is the driver's delegate, so an
// online stream becomes a session exactly like a nearby one, and the session race (explicit rank: LAN, peer-to-peer
// Wi-Fi, Internet, Bluetooth, relay) keeps the best of them. The driver exists only once the check-in client is up
// (SZFriendsHostCheckIn.m) and does nothing until the host's welcome says it takes online messages; nothing here runs
// at launch.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import "service/identity/SZFriendsIdentity.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"

// The technique log (ADR 0011 § Technique log): numbers only, beside the store.
static NSString *const SZFriendsOnlineTechniqueLogName = @"online-techniques.json";
// How long Connecting shows after something new was queued for a friend, or their conversation was opened: about one
// attempt's budget (an answer in 15 s, the direct phase, the relay). Past it the words go back to Not connected, even
// while an attempt still runs or an offer still waits for an answer.
static const NSTimeInterval SZFriendsOnlineJustOpened = 45;

@implementation SZFriendsNearbyService (Online)

- (void)attachOnlineHost:(SZFriendsHostOnline *)online {
    SZFriendsIdentity *identity = self.services.identity;
    if (identity == nil || self.shutDown || self.resetting) return;
    if (self.onlineDriver == nil) {
        SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:identity queue:self.queue];
        driver.delegate = self;
        __weak SZFriendsNearbyService *weakSelf = self;
        driver.ownPresenceSecret = ^NSData * { return weakSelf.services.store.ownPresenceSecret; };
        driver.hostList = ^SZFriendsHostList * { return weakSelf.services.hostListCache.currentList; };
        driver.techniqueLogPath =
            [self.services.paths.stateDirectory stringByAppendingPathComponent:SZFriendsOnlineTechniqueLogName];
        self.onlineDriver = driver;
    }
    [self.onlineDriver attachHostOnline:online];
}

- (void)stopOnline {
    [self.onlineDriver stop];
    self.onlineDriver = nil;
    if (self.onlineOffered) {
        self.onlineOffered = NO;
        [self changed];
    }
}

- (BOOL)reachesFriendsOnline {
    return self.onlineOffered && self.onlineDriver != nil;
}

- (void)conversationOpened:(NSString *)conversationID {
    if (self.conversationsOpenedAt == nil) self.conversationsOpenedAt = [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    self.conversationsOpenedAt[conversationID] = now;
    // The person is looking now: a failure before this is old news, and a retry running shows as Connecting.
    NSData *key = [self.services.store personWithConversationID:conversationID].identityKey;
    if (key != nil) [self.onlineDriver forgetFailureForFriend:key];
    [self refreshOnlineReachAt:[now dateByAddingTimeInterval:SZFriendsOnlineJustOpened]];
}

// When a Connecting window runs out, an attempt still running goes back to Not connected. One timer at a time: the
// earliest deadline; a pass then schedules the next.
- (void)refreshOnlineReachAt:(NSDate *)deadline {
    NSDate *pending = self.onlineReachRefreshAt;
    if (pending != nil && [pending compare:deadline] != NSOrderedDescending) {
        return;
    }
    self.onlineReachRefreshAt = deadline;
    NSTimeInterval wait = MAX(0, [deadline timeIntervalSinceNow]) + 0.5;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if ([strongSelf.onlineReachRefreshAt isEqualToDate:deadline]) strongSelf.onlineReachRefreshAt = nil;
        [strongSelf changed];
    });
}

// A message or file still on its way to a friend: what the person would wait on. Answers, presence secrets and the like
// travel too, but nobody watches for them. Returns when the newest of them was queued (Try again counts), else nil.
- (nullable NSDate *)latestWaitingMessageOrFileForPerson:(SZFriendsPersonRecord *)person {
    NSDate *latest = nil;
    for (SZFriendsOutboxEntry *entry in [self.services.outbox pendingEntriesForConversation:person.conversationID]) {
        if (entry.kind != SZFriendsOutboxKindMessage && entry.kind != SZFriendsOutboxKindOffer) continue;
        NSDate *queued = entry.queuedAt ?: entry.createdAt ?: [NSDate distantPast];
        if (latest == nil || [queued compare:latest] == NSOrderedDescending) latest = queued;
    }
    return latest;
}

- (void)onlineOutboxChangedForConversation:(NSString *)conversationID {
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:conversationID];
    NSDate *since = person.identityKey ? [self.onlineDriver failedSinceForFriend:person.identityKey] : nil;
    NSDate *queued = since ? [self latestWaitingMessageOrFileForPerson:person] : nil;
    if (queued != nil && [queued compare:since] == NSOrderedDescending) {
        [self.onlineDriver forgetFailureForFriend:person.identityKey];
    }
}

- (SZFriendsOnlineReach)onlineReachForPerson:(SZFriendsPersonRecord *)person now:(NSDate *)now {
    SZFriendsOnlineDriver *driver = self.onlineDriver;
    if (!self.reachesFriendsOnline || person.relation != SZFriendsRelationFriend || person.identityKey == nil ||
        person.keyChangePending) {
        return SZFriendsOnlineReachUnknown;
    }
    SZFriendsOnlineFriendReach reach = [driver reachOfFriend:person.identityKey];
    if (reach == SZFriendsOnlineFriendReachIdle) return SZFriendsOnlineReachUnknown;
    NSDate *queued = [self latestWaitingMessageOrFileForPerson:person];
    if (reach == SZFriendsOnlineFriendReachFailed) {
        return queued != nil ? SZFriendsOnlineReachUnreachable : SZFriendsOnlineReachUnknown;
    }
    NSDate *opened = self.conversationsOpenedAt[person.conversationID];
    BOOL queuedLater = queued != nil && opened != nil && [queued compare:opened] == NSOrderedDescending;
    NSDate *since = opened == nil || queuedLater ? queued : opened;
    if (since == nil || [now timeIntervalSinceDate:since] >= SZFriendsOnlineJustOpened) {
        return SZFriendsOnlineReachUnknown;
    }
    [self refreshOnlineReachAt:[since dateByAddingTimeInterval:SZFriendsOnlineJustOpened]];
    return SZFriendsOnlineReachConnecting;
}

// Every friend who has something waiting for them, or something on its way to us, and no session on a route that
// ranks before Internet. The driver decides the rest (an attempt already running, a backoff, a friend offline).
- (void)reachFriendsOnline {
    SZFriendsOnlineDriver *driver = self.onlineDriver;
    if (!driver.available || self.shutDown || self.resetting) return;
    [driver nearbyRoutesChanged];
    SZFriendsStore *store = self.services.store;
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        if (person.relation != SZFriendsRelationFriend || person.identityKey == nil || person.keyChangePending) {
            continue;
        }
        SZFriendsPeerLink *live = [self liveLinkForConversation:person.conversationID];
        if (live != nil && !SZFriendsRouteIsBetter(SZFriendsRouteMethodInternet, live.raceRoute)) continue;
        if (![self hasDeliverableEntriesForPerson:person] &&
            [self.services.transfers unfinishedIncomingTransfersForConversation:person.conversationID].count == 0) {
            continue;
        }
        [driver reachFriend:person.identityKey];
        [self reachOtherDevicesOfFriendOnline:person];
    }
}

- (void)onlineRoutesChanged {
    [self.onlineDriver nearbyRoutesChanged];
}

#pragma mark - SZFriendsOnlineDriverDelegate

- (void)onlineDriverDidBecomeAvailable:(SZFriendsOnlineDriver *)driver {
    (void)driver;
    if (!self.onlineOffered) {
        // From now on the words say "online or nearby", and the next welcome announces `online`.
        self.onlineOffered = YES;
        [self changed];
    }
    [self scheduleReconsider];
}

// An attempt started or ended, or a failure was forgotten: Connecting and Couldn’t connect follow.
- (void)onlineDriver:(SZFriendsOnlineDriver *)driver reachChangedForFriend:(NSData *)identityKey {
    (void)driver;
    (void)identityKey;
    [self changed];
}

// Friends only, with the static key we hold for them and no key change waiting for review: the same people IK
// reaches nearby.
- (nullable SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver
                           friendWithIdentityKey:(NSData *)identityKey {
    (void)driver;
    SZFriendsOnlineFriend *ownDevice = [self onlineOwnDeviceWithKey:identityKey]; // another device of ours (+Sync)
    if (ownDevice != nil) return ownDevice;
    SZFriendsOnlineFriend *friendDevice = [self onlineFriendDeviceWithKey:identityKey]; // +FriendDevices
    if (friendDevice != nil) return friendDevice;
    SZFriendsPersonRecord *person = [self.services.store personWithIdentityKey:identityKey];
    if (person.relation != SZFriendsRelationFriend || person.keyChangePending || person.staticKey.length != 32 ||
        ![person.identityKey isEqualToData:identityKey]) {
        return nil;
    }
    SZFriendsOnlineFriend *friend = [[SZFriendsOnlineFriend alloc] init];
    friend.identityKey = person.identityKey;
    friend.staticKey = person.staticKey;
    friend.presenceSecret = person.presenceSecret;
    // Their Add by ID we accepted: until our ACCEPT reaches them, their side knows us only by its token.
    friend.requestToken = person.callbackToken;
    return friend;
}

// A session over a nearby route; one the driver opened (Internet, relay) is the driver's own business.
- (SZFriendsRouteMethod)onlineDriver:(SZFriendsOnlineDriver *)driver nearbyRouteForFriend:(NSData *)identityKey {
    (void)driver;
    if ([self isOwnDeviceKey:identityKey]) return [self nearbyRouteToOwnDevice:identityKey];
    SZFriendsPersonRecord *person = [self.services.store personWithIdentityKey:identityKey];
    SZFriendsPeerLink *live = person ? [self liveLinkForConversation:person.conversationID] : nil;
    SZFriendsRouteMethod route = live ? live.raceRoute : SZFriendsRouteMethodNone;
    BOOL ours = route == SZFriendsRouteMethodInternet || route == SZFriendsRouteMethodRelay;
    return ours ? SZFriendsRouteMethodNone : route;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
       didOpenStream:(id<SZFriendsByteStream>)stream
               route:(SZFriendsRouteMethod)route
           initiator:(BOOL)initiator
              friend:(NSData *)identityKey {
    (void)driver;
    if (self.shutDown || self.resetting) {
        [stream close];
        return;
    }
    if (!initiator) {
        // The friend's side dials: a responder session, whose key policy admits friends as a hidden listener does.
        [self acceptStream:stream route:route publicEntry:NO];
        return;
    }
    if ([self openOwnDeviceStream:stream route:route device:identityKey]) return; // another device of ours (+Sync)
    if ([self openFriendDeviceStream:stream route:route device:identityKey]) return; // +FriendDevices
    SZFriendsPersonRecord *person = [self.services.store personWithIdentityKey:identityKey];
    if (person.relation != SZFriendsRelationFriend || person.staticKey == nil) {
        [stream close];
        return;
    }
    // As nearby dials them: with their Add by ID token while our ACCEPT is on its way, and then our attestation, and
    // that session runs the code exchange that creates the friendship (+Sessions, -linkForInitiatorStream:plan:).
    SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person route:route];
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                                       identity:self.services.identity
                                                                                        options:options
                                                                                          queue:self.queue];
    if (options.requestToken != nil) channel.localAttestation = [self attestationForOurAnswer];
    SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:channel
                                                                 purpose:SZFriendsLinkPurposeFriend
                                                                   route:route];
    link.conversationID = person.conversationID;
    link.requestToken = options.requestToken;
    link.createsFriendship = options.requestToken != nil;
    [self startLink:link];
}

@end
