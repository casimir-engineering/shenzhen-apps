// Whom to connect to, and how (ADR 0004 § Route racing, § Add by ID nearby; ADR 0001 § Session race).
//
// One pass over the merger's candidates decides every attempt: IK to friends seen by tag on all their routes at
// once, staggered toward the faster ones; a browse-only XX to each public entry nobody has identified yet; a full
// XX to deliver a nearby friend request; IK probes at unrecognised devices for a person whose tags we cannot match
// but who has something waiting (a just-accepted request); and the NN Add by ID request to every device once per
// window. Nothing here sends application data; a live session does that (+Delivery).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/helper/nearby/SZFriendsNearbyJoin.h"

// Failed attempts back off per person: 1 s doubling to 5 minutes, so a friend who removed us costs little.
static const NSTimeInterval SZFriendsDialBackoffFirst = 1;
static const NSTimeInterval SZFriendsDialBackoffMax = 300;
// A session that stayed up this long was healthy: its end starts the backoff afresh.
static const NSTimeInterval SZFriendsHealthySession = 30;
// A browse that failed (a listener not ready yet) is tried again this soon.
static const NSTimeInterval SZFriendsBrowseRetry = 5;
// An Add by ID request goes to each device once a day, with that day's callback secret; one that did not reach a
// device (it left, or never answered) is tried again after this.
static const NSTimeInterval SZFriendsByIDRetry = 900;

static NSString *SZFriendsDialKey(SZFriendsLinkPurpose purpose, SZFriendsSighting *sighting) {
    return [NSString stringWithFormat:@"%ld|%ld|%@", (long)purpose, (long)sighting.method, sighting.endpointID];
}

BOOL SZFriendsNearbyDialIsPointless(SZFriendsRouteMethod live, SZFriendsRouteMethod sighting) {
    return !SZFriendsRouteIsBetter(sighting, live);
}

@implementation SZFriendsDialPlan

+ (instancetype)planWithSighting:(SZFriendsSighting *)sighting
                         purpose:(SZFriendsLinkPurpose)purpose
                         options:(SZFriendsHandshakeOptions *)options {
    SZFriendsDialPlan *plan = [[self alloc] init];
    plan.sighting = sighting;
    plan.purpose = purpose;
    plan.options = [options copy];
    return plan;
}

@end

@implementation SZFriendsNearbyService (Dial)

- (void)scheduleReconsider {
    if (self.reconsiderScheduled) return;
    self.reconsiderScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_async(self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.reconsiderScheduled = NO;
        [strongSelf reconsider];
    });
}

- (void)reconsider {
    SZFriendsStore *store = self.services.store;
    if (self.coordinator == nil || store == nil || self.services.identity == nil || self.shutDown || self.resetting) {
        return;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates.copy) {
        if ([self reachOwnDeviceCandidate:candidate]) continue; // another device of ours (+Sync)
        if ([self reachFriendDeviceCandidate:candidate]) continue; // a friend's other device (+FriendDevices)
        NSString *conversationID = candidate.conversationID;
        if (conversationID == nil && candidate.identityKey != nil) {
            // Browsed as a stranger, in the list since (send_request): the merger learns whose entry it is, so a
            // later presence tag joins the same candidate. A removed person stays a stranger here: Nearby offers
            // them a new request like anyone visible.
            SZFriendsPersonRecord *known = [store personWithIdentityKey:candidate.identityKey];
            if (known != nil && known.relation != SZFriendsRelationBlocked &&
                known.relation != SZFriendsRelationRemoved) {
                conversationID = known.conversationID;
                for (SZFriendsSighting *sighting in candidate.sightings) {
                    [self.coordinator.merger identifyEndpoint:sighting.endpointID method:sighting.method
                                                  identityKey:candidate.identityKey conversationID:conversationID];
                }
            }
        }
        if (conversationID == nil) {
            if (candidate.isPublic && !candidate.isIdentified) [self browseCandidate:candidate];
            continue;
        }
        SZFriendsPersonRecord *person = [store personWithConversationID:conversationID];
        if (person == nil) continue;
        [seen addObject:person.conversationID];
        [self reachPerson:person candidate:candidate];
    }
    [self probeForPeopleNotSeen:seen];
    [self offerRequestsByID];
    [self reachFriendsOnline];
    [self reachOwnDevices];
    [self offerRequestsByIDOnline];
    [self offerJoinNearby];
    [self offerJoinOnline];
}

#pragma mark - People in the list

- (SZFriendsHandshakeOptions *)ikOptionsForPerson:(SZFriendsPersonRecord *)person route:(SZFriendsRouteMethod)route {
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = SZFriendsHandshakeIK;
    options.route = route;
    options.remoteStaticKey = person.staticKey;
    options.expectedIdentityKey = person.identityKey;
    // Until our ACCEPT reaches an Add by ID requester, its listener knows us only by the token it issued.
    options.requestToken = person.callbackToken;
    return options;
}

// Friends (and removed people with an answer still to deliver) are dialed with IK on every route the racer
// allows; an outgoing nearby request goes to their public entry with XX.
- (void)reachPerson:(SZFriendsPersonRecord *)person candidate:(SZFriendsCandidate *)candidate {
    NSString *conversationID = person.conversationID;
    SZFriendsPeerLink *live = [self liveLinkForConversation:conversationID];
    BOOL deliverable = [self hasDeliverableEntriesForPerson:person];
    switch (person.relation) {
    case SZFriendsRelationBlocked:
    case SZFriendsRelationIncomingRequest:
        return; // nothing is sent to them until this person answers
    case SZFriendsRelationOutgoingRequest:
        if (live != nil || person.identityKey == nil || !deliverable || ![self mayDialConversation:conversationID]) {
            return;
        }
        for (SZFriendsSighting *sighting in candidate.sightings) {
            if (!sighting.isPublic) continue;
            SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
            options.pattern = SZFriendsHandshakeXX;
            options.route = sighting.route;
            // The person whose entry we browsed, or nobody: anyone else answering there is refused before message 3
            // would tell them who we are.
            options.expectedIdentityKey = person.identityKey;
            SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                                  purpose:SZFriendsLinkPurposeRequest
                                                                  options:options];
            plan.conversationID = conversationID;
            if ([self dial:plan]) [self markConnectingForConversation:conversationID];
            return;
        }
        return;
    case SZFriendsRelationRemoved:
        if (!deliverable) return; // a decline or a withdrawn request still has to reach them
        break;
    case SZFriendsRelationFriend:
        break;
    }
    if (person.staticKey == nil || person.identityKey == nil || ![self mayDialConversation:conversationID]) return;
    SZFriendsRouteMethod current = live != nil ? live.raceRoute : SZFriendsRouteMethodNone;
    BOOL started = NO;
    for (SZFriendsDialAttempt *attempt in [self.coordinator.racer attemptsForCandidate:candidate]) {
        if (![self.coordinator.racer shouldStartAttempt:attempt currentRoute:current]) continue;
        SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person route:attempt.sighting.route];
        SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:attempt.sighting
                                                              purpose:SZFriendsLinkPurposeFriend
                                                              options:options];
        plan.conversationID = conversationID;
        plan.delay = attempt.delay;
        started = [self dial:plan] || started;
    }
    if (started && live == nil && deliverable) [self markConnectingForConversation:conversationID];
}

// A person with something to deliver whose tags we cannot match (we lack their presence secret, or they are a
// removed person waiting for our answer): IK at each unrecognised device, once per device and window. A wrong
// device cannot decrypt IK's first message and learns nothing; the right one accepts a key it knows.
- (void)probeForPeopleNotSeen:(NSSet<NSString *> *)seen {
    NSArray<SZFriendsCandidate *> *devices = self.coordinator.merger.unmatchedDevices;
    if (devices.count == 0) return;
    int64_t window = [self currentWindow];
    NSDate *windowEnd = SZFriendsPresenceWindowEnd([NSDate date]);
    for (SZFriendsPersonRecord *person in [self.services.store peopleByLatestInteraction]) {
        NSString *conversationID = person.conversationID;
        BOOL relation = person.relation == SZFriendsRelationFriend || person.relation == SZFriendsRelationRemoved;
        if (!relation || [seen containsObject:conversationID] || person.staticKey == nil ||
            person.identityKey == nil || [self liveLinkForConversation:conversationID] != nil ||
            ![self hasDeliverableEntriesForPerson:person]) {
            continue;
        }
        BOOL started = NO;
        for (SZFriendsCandidate *device in devices) {
            SZFriendsSighting *sighting = device.sightings.firstObject;
            if (sighting == nil || sighting.isPublic) continue;
            NSString *key = [NSString stringWithFormat:@"probe|%@|%@|%lld", conversationID, sighting.endpointID,
                                                       (long long)window];
            if (self.attempts[key] != nil) continue;
            self.attempts[key] = windowEnd;
            SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person route:sighting.route];
            SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                                  purpose:SZFriendsLinkPurposeFriend
                                                                  options:options];
            plan.conversationID = conversationID;
            plan.probe = YES;
            started = [self dial:plan] || started;
        }
        if (started) [self markConnectingForConversation:conversationID];
    }
}

#pragma mark - Strangers

// Who is behind a public entry? A browse-only XX returns their key and public profile and stops before revealing
// us (ADR 0004 § Public visibility).
- (void)browseCandidate:(SZFriendsCandidate *)candidate {
    for (SZFriendsSighting *sighting in candidate.sightings) {
        if (!sighting.isPublic) continue;
        NSString *key = [@"browse|" stringByAppendingString:sighting.endpointID];
        NSDate *notBefore = self.attempts[key];
        if (notBefore != nil && notBefore.timeIntervalSinceNow > 0) continue;
        // Until it answers or fails; a success keeps it (the merger remembers the identity until the entry goes).
        self.attempts[key] = [NSDate distantFuture];
        SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
        options.pattern = SZFriendsHandshakeXX;
        options.route = sighting.route;
        options.browseOnly = YES;
        [self dial:[SZFriendsDialPlan planWithSighting:sighting purpose:SZFriendsLinkPurposeBrowse options:options]];
    }
}

- (void)browseOfEndpointFailed:(NSString *)endpointID {
    self.attempts[[@"browse|" stringByAppendingString:endpointID]] =
        [NSDate dateWithTimeIntervalSinceNow:SZFriendsBrowseRetry];
    [self scheduleReconsiderAfter:SZFriendsBrowseRetry];
}

// Each pending Add by ID goes to every device we cannot recognise, hidden or public, once per device per day of the
// request (ADR 0004 step 1), carrying that day's callback secret; every device answers alike, so the holder stays
// as anonymous as everyone else.
- (void)offerRequestsByID {
    NSDate *now = [NSDate date];
    NSArray<SZFriendsIDRequestRecord *> *requests = [self.services.store pendingIDRequestsAtDate:now];
    if (requests.count == 0) return;
    NSMutableArray<SZFriendsCandidate *> *devices = [self.coordinator.merger.unmatchedDevices mutableCopy];
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates) {
        if (candidate.conversationID == nil && candidate.isPublic) [devices addObject:candidate];
    }
    // Pending means unanswered: once someone answered, the request admits its token until it expires but goes to no
    // further device.
    for (SZFriendsIDRequestRecord *request in requests) {
        NSString *token = SZFriendsLinkHex(request.requestToken);
        int64_t day = SZFriendsCallbackDay(request.createdAt, now);
        NSDate *dayEnd = [request.createdAt dateByAddingTimeInterval:(double)(day + 1) * 86400];
        for (SZFriendsCandidate *device in devices) {
            SZFriendsSighting *sighting = device.sightings.firstObject;
            if (sighting == nil) continue;
            NSString *key = [NSString stringWithFormat:@"byid|%@|%@|%lld", token, sighting.endpointID, (long long)day];
            if (self.attempts[key] != nil) continue;
            self.attempts[key] = dayEnd;
            SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
            options.pattern = SZFriendsHandshakeNN;
            options.route = sighting.route;
            // NN carries the token inside REQUEST_BY_ID, never in the handshake.
            SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                                  purpose:SZFriendsLinkPurposeByID
                                                                  options:options];
            plan.requestToken = request.requestToken;
            plan.attemptKey = key;
            [self dial:plan];
        }
    }
}

#pragma mark - Dialing

- (BOOL)dial:(SZFriendsDialPlan *)plan {
    SZFriendsSighting *sighting = plan.sighting;
    NSString *key = SZFriendsDialKey(plan.purpose, sighting);
    if ([self.dialing containsObject:key]) return NO;
    id<SZFriendsDiscoveryAdapter> adapter = nil;
    for (id<SZFriendsDiscoveryAdapter> candidate in self.adapters) {
        if (candidate.method == sighting.method) adapter = candidate;
    }
    if (adapter == nil) return NO;
    [self.dialing addObject:key];
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(plan.delay * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        // Asked again when the stagger ends: a faster session may have won meanwhile (the racer's rule).
        NSString *conversationID = plan.conversationID;
        SZFriendsPeerLink *live = conversationID ? [strongSelf liveLinkForConversation:conversationID] : nil;
        BOOL pointless = plan.purpose == SZFriendsLinkPurposeFriend && live != nil &&
                         SZFriendsNearbyDialIsPointless(live.raceRoute, sighting.route);
        if (strongSelf.shutDown || pointless) {
            [strongSelf.dialing removeObject:key];
            return;
        }
        [adapter openStreamToEndpoint:sighting.endpointID
                           completion:^(id<SZFriendsByteStream> stream, NSError *error) {
                               (void)error;
                               dispatch_async(strongSelf.queue, ^{
                                   [strongSelf dialed:plan stream:stream key:key];
                               });
                           }];
    });
    return YES;
}

- (void)dialed:(SZFriendsDialPlan *)plan stream:(nullable id<SZFriendsByteStream>)stream key:(NSString *)key {
    if (stream == nil || self.shutDown) {
        [self.dialing removeObject:key];
        [stream close];
        // Unreachable endpoints are normal (a device that just left); only a person's own attempts back off.
        if (plan.purpose == SZFriendsLinkPurposeBrowse) {
            [self browseOfEndpointFailed:plan.sighting.endpointID];
        } else if (plan.attemptKey != nil) {
            [self byIDAttemptFailed:plan.attemptKey];
        } else if (plan.conversationID != nil && !plan.probe && plan.purpose == SZFriendsLinkPurposeFriend) {
            [self noteFailureForConversation:plan.conversationID];
        }
        if (plan.purpose == SZFriendsLinkPurposeFriend) {
            [self noteDialToEndpoint:plan.sighting.endpointID method:plan.sighting.method
                        conversation:plan.conversationID succeeded:NO];
        }
        return;
    }
    SZFriendsPeerLink *link = [self linkForInitiatorStream:stream plan:plan];
    link.dialKey = key;
    link.attemptKey = plan.attemptKey;
    [self startLink:link];
}

- (void)byIDAttemptFailed:(NSString *)attemptKey {
    self.attempts[attemptKey] = [NSDate dateWithTimeIntervalSinceNow:SZFriendsByIDRetry];
    [self scheduleReconsiderAfter:SZFriendsByIDRetry];
}

#pragma mark - Backoff

- (BOOL)mayDialConversation:(NSString *)conversationID {
    NSDate *after = self.retryAfter[conversationID];
    return after == nil || after.timeIntervalSinceNow <= 0;
}

- (void)noteFailureForConversation:(NSString *)conversationID {
    NSUInteger count = (NSUInteger)self.failures[conversationID].integerValue + 1;
    self.failures[conversationID] = @(count);
    NSTimeInterval delay = MIN(SZFriendsDialBackoffMax, SZFriendsDialBackoffFirst * pow(2, MIN(count - 1, 10u)));
    self.retryAfter[conversationID] = [NSDate dateWithTimeIntervalSinceNow:delay];
    [self scheduleReconsiderAfter:delay];
}

- (void)noteSuccessForConversation:(NSString *)conversationID {
    [self.failures removeObjectForKey:conversationID];
    [self.retryAfter removeObjectForKey:conversationID];
}

// A live session ended: one that lasted was healthy and starts the backoff afresh.
- (void)noteEndOfLink:(SZFriendsPeerLink *)link {
    if (link.conversationID == nil || link.probe) return;
    if (link.liveAt != nil && -link.liveAt.timeIntervalSinceNow >= SZFriendsHealthySession) {
        [self noteSuccessForConversation:link.conversationID];
        [self.keptElsewhere removeObjectForKey:link.conversationID];
    }
    [self noteFailureForConversation:link.conversationID];
}

// A friend holds one session per person: one with another of our computers wins the race, and this computer would
// dial again at once only to be closed again, many times a second. It waits instead, longer each time in a row (a
// session that lasted starts afresh), while the computer the friend kept delivers for all of ours (ADR 0014).
- (void)noteSessionKeptElsewhereForConversation:(NSString *)conversationID {
    NSUInteger count = (NSUInteger)self.keptElsewhere[conversationID].integerValue + 1;
    self.keptElsewhere[conversationID] = @(count);
    NSTimeInterval delay = MIN(SZFriendsDialBackoffMax, SZFriendsDialBackoffFirst * pow(2, MIN(count - 1, 10u)));
    self.retryAfter[conversationID] = [NSDate dateWithTimeIntervalSinceNow:delay];
    [self scheduleReconsiderAfter:delay];
}

- (void)noteDialToEndpoint:(nullable NSString *)endpointID
                    method:(NSInteger)method
              conversation:(nullable NSString *)conversationID
                 succeeded:(BOOL)succeeded {
    SZFriendsRouteRacer *racer = self.coordinator.racer;
    if (racer == nil || endpointID == nil || conversationID == nil) return;
    SZFriendsDiscoveryMethod discoveryMethod = (SZFriendsDiscoveryMethod)method;
    if (succeeded) {
        [racer noteHandshakeSucceededAtEndpoint:endpointID method:discoveryMethod conversationID:conversationID];
        return;
    }
    [racer noteHandshakeFailedAtEndpoint:endpointID method:discoveryMethod conversationID:conversationID];
    NSDate *end = racer.nextBackoffEnd;
    if (end != nil) [self scheduleReconsiderAfter:MAX(0, end.timeIntervalSinceNow)];
}

- (void)scheduleReconsiderAfter:(NSTimeInterval)delay {
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 0.01) * NSEC_PER_SEC)), self.queue, ^{
        [weakSelf scheduleReconsider];
    });
}

- (void)pruneAttempts {
    NSDate *now = [NSDate date];
    for (NSString *key in self.attempts.allKeys) {
        if ([self.attempts[key] compare:now] == NSOrderedAscending) [self.attempts removeObjectForKey:key];
    }
}

@end
