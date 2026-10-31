// Route racing, dial staggering, per-tag dial backoff, the session tie-break and the launch permission decision
// (ADR 0004 § Route racing, § Permissions at launch; ADR 0001 § Session race). Pure: no radios, and the one clock
// (for backoffs) is injected.

#import "service/discovery/SZFriendsDiscoveryInternal.h"

const NSTimeInterval SZFriendsDialDelayLAN = 0;
const NSTimeInterval SZFriendsDialDelayPeerToPeerWiFi = 0.15;
const NSTimeInterval SZFriendsDialDelayInternet = 0.3;
const NSTimeInterval SZFriendsDialDelayBluetooth = 0.5;
const NSTimeInterval SZFriendsDialDelayRelay = 5;
const NSTimeInterval SZFriendsEndpointBackoffFirst = 2;
const NSTimeInterval SZFriendsEndpointBackoffMax = 900;
// A bound on remembered backoffs and endpoint tags, so endpoints and tags that come and go (both rotate per window)
// cannot grow the tables without end; the oldest-ending backoffs go first.
static const NSUInteger kBackoffEntriesMax = 1024;

BOOL SZFriendsStartAdapterAtLaunch(SZFriendsPermission permission, BOOL nearbyPermissionsRequested) {
    switch (permission) {
    case SZFriendsPermissionAllowed:
        return YES;
    case SZFriendsPermissionDenied:
    case SZFriendsPermissionNotDetermined:
        return NO;
    case SZFriendsPermissionUnknown:
        // Local Network has no read API and browsing is the ask, so only someone who has already been asked
        // (by opening Friends once) gets browsing at launch.
        return nearbyPermissionsRequested;
    }
    return NO;
}

// One delay per route, in rank order. Every case is spelled out: a default used to give Internet and the relay
// Bluetooth's delay.
NSTimeInterval SZFriendsDialDelayForRoute(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodLAN:
        return SZFriendsDialDelayLAN;
    case SZFriendsRouteMethodPeerToPeerWiFi:
        return SZFriendsDialDelayPeerToPeerWiFi;
    case SZFriendsRouteMethodInternet:
        return SZFriendsDialDelayInternet;
    case SZFriendsRouteMethodBluetooth:
        return SZFriendsDialDelayBluetooth;
    case SZFriendsRouteMethodRelay:
    case SZFriendsRouteMethodNone:
        break;
    }
    return SZFriendsDialDelayRelay;
}

@interface SZFriendsDialAttempt ()
- (instancetype)initWithSighting:(SZFriendsSighting *)sighting delay:(NSTimeInterval)delay;
@end

@implementation SZFriendsDialAttempt

- (instancetype)initWithSighting:(SZFriendsSighting *)sighting delay:(NSTimeInterval)delay {
    if ((self = [super init])) {
        _sighting = sighting;
        _delay = delay;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<dial %@ route %ld after %.2fs>", self.sighting.endpointID,
                                      (long)self.sighting.route, self.delay];
}

@end

// One tag's (or tagless endpoint's) backoff for one person.
@interface SZFriendsEndpointBackoff : NSObject
@property(nonatomic) NSUInteger failures;
@property(nonatomic) NSDate *until;
@end

@implementation SZFriendsEndpointBackoff
@end

static NSString *EndpointKey(SZFriendsDiscoveryMethod method, NSString *endpointID) {
    return [NSString stringWithFormat:@"%ld/%@", (long)method, endpointID];
}

@implementation SZFriendsRouteRacer {
    NSMutableDictionary<NSString *, SZFriendsEndpointBackoff *> *_backoffs;
    NSMutableDictionary<NSString *, NSData *> *_endpointTags; // EndpointKey -> the tag it showed when handed out
}

- (instancetype)init {
    if ((self = [super init])) {
        _backoffs = [NSMutableDictionary dictionary];
        _endpointTags = [NSMutableDictionary dictionary];
        _peerToPeerWiFi = SZFriendsPlatformPeerToPeerWiFi;
        _clock = ^NSDate * {
            return [NSDate date];
        };
    }
    return self;
}

// A backoff that ended more than this long ago is forgotten: the endpoint's next failure starts from the first step.
static BOOL BackoffIsStale(SZFriendsEndpointBackoff *backoff, NSDate *now) {
    return [[backoff.until dateByAddingTimeInterval:SZFriendsEndpointBackoffMax] compare:now] != NSOrderedDescending;
}

// Drops forgotten backoffs, then the soonest-ending ones past the bound.
- (void)pruneBackoffsAt:(NSDate *)now {
    for (NSString *key in _backoffs.allKeys) {
        if (BackoffIsStale(_backoffs[key], now)) [_backoffs removeObjectForKey:key];
    }
    if (_backoffs.count <= kBackoffEntriesMax) return;
    NSArray<NSString *> *byEnd = [_backoffs keysSortedByValueUsingComparator:^NSComparisonResult(
                                                SZFriendsEndpointBackoff *a, SZFriendsEndpointBackoff *b) {
        return [a.until compare:b.until];
    }];
    for (NSUInteger i = 0; i < byEnd.count - kBackoffEntriesMax; i++) [_backoffs removeObjectForKey:byEnd[i]];
}

// What a failure is held against: the tag the endpoint showed for this person, or the endpoint when it had none.
- (NSString *)backoffKeyForEndpoint:(NSString *)endpointID
                             method:(SZFriendsDiscoveryMethod)method
                                tag:(NSData *)tag
                     conversationID:(NSString *)conversationID {
    NSString *what = tag ? [@"tag:" stringByAppendingString:SZFriendsHexFromData(tag)]
                         : [@"endpoint:" stringByAppendingString:endpointID];
    return [NSString stringWithFormat:@"%@|%ld|%@", conversationID, (long)method, what];
}

- (NSString *)backoffKeyForEndpoint:(NSString *)endpointID
                             method:(SZFriendsDiscoveryMethod)method
                     conversationID:(NSString *)conversationID {
    return [self backoffKeyForEndpoint:endpointID
                                method:method
                                   tag:_endpointTags[EndpointKey(method, endpointID)]
                        conversationID:conversationID];
}

// The tag of `sighting` that names `conversationID`: the one a relayer had to copy to be dialed at all.
- (NSData *)matchedTagOfSighting:(SZFriendsSighting *)sighting conversationID:(NSString *)conversationID {
    SZFriendsTagMatcher matcher = self.tagMatcher;
    if (matcher == nil) return sighting.presenceTag;
    NSMutableArray<NSData *> *tags = [NSMutableArray arrayWithArray:sighting.callbackTags];
    if (sighting.presenceTag) [tags insertObject:sighting.presenceTag atIndex:0];
    for (NSData *tag in tags) {
        if ([matcher(tag) isEqualToString:conversationID]) return tag;
    }
    return sighting.presenceTag;
}

- (void)noteHandshakeFailedAtEndpoint:(NSString *)endpointID
                               method:(SZFriendsDiscoveryMethod)method
                       conversationID:(NSString *)conversationID {
    NSDate *now = self.clock();
    NSString *key = [self backoffKeyForEndpoint:endpointID method:method conversationID:conversationID];
    // A failure counts on from an entry still remembered, so a relayed tag dialed again right after its backoff
    // ended waits twice as long next time.
    SZFriendsEndpointBackoff *backoff = _backoffs[key];
    if (backoff == nil || BackoffIsStale(backoff, now)) backoff = [SZFriendsEndpointBackoff new];
    backoff.failures++;
    NSTimeInterval delay = MIN(SZFriendsEndpointBackoffMax,
                               SZFriendsEndpointBackoffFirst * pow(2, (double)MIN(backoff.failures - 1, 20u)));
    backoff.until = [now dateByAddingTimeInterval:delay];
    _backoffs[key] = backoff;
    if (_backoffs.count > kBackoffEntriesMax) [self pruneBackoffsAt:now];
}

- (void)noteHandshakeSucceededAtEndpoint:(NSString *)endpointID
                                  method:(SZFriendsDiscoveryMethod)method
                          conversationID:(NSString *)conversationID {
    [_backoffs removeObjectForKey:[self backoffKeyForEndpoint:endpointID method:method conversationID:conversationID]];
}

- (void)endBackoffsForConversation:(NSString *)conversationID {
    NSDate *now = self.clock();
    NSString *prefix = [conversationID stringByAppendingString:@"|"];
    for (NSString *key in _backoffs) {
        SZFriendsEndpointBackoff *backoff = _backoffs[key];
        if ([key hasPrefix:prefix] && [backoff.until compare:now] == NSOrderedDescending) backoff.until = now;
    }
}

- (BOOL)isBackingOff:(NSString *)key at:(NSDate *)now {
    SZFriendsEndpointBackoff *backoff = _backoffs[key];
    return backoff != nil && [backoff.until compare:now] == NSOrderedDescending;
}

- (NSDate *)nextBackoffEnd {
    NSDate *now = self.clock(), *next = nil;
    for (SZFriendsEndpointBackoff *backoff in _backoffs.allValues) {
        if ([backoff.until compare:now] != NSOrderedDescending) continue;
        next = next ? [next earlierDate:backoff.until] : backoff.until;
    }
    return next;
}

- (NSArray<SZFriendsDialAttempt *> *)attemptsForCandidate:(SZFriendsCandidate *)candidate {
    NSDate *now = self.clock();
    NSMutableArray<SZFriendsDialAttempt *> *attempts = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    // A friend who is also visible shows a public entry beside the hidden one. IK belongs on the hidden listener,
    // so the public entry is dialed only when it is all we have.
    BOOL hasHiddenEndpoint = NO;
    for (SZFriendsSighting *sighting in candidate.sightings) {
        hasHiddenEndpoint = hasHiddenEndpoint || !sighting.isPublic;
    }
    BOOL skipPublic = candidate.conversationID != nil && hasHiddenEndpoint;
    // Peer-to-peer Wi-Fi only where it keeps the Wi-Fi connection: otherwise the next route carries the session.
    BOOL skipPeerToPeer = !SZFriendsPeerToPeerWiFiUsable(self.peerToPeerWiFi);
    NSString *conversationID = candidate.conversationID;
    for (SZFriendsSighting *sighting in candidate.sightings) {
        if (skipPublic && sighting.isPublic) continue;
        if (skipPeerToPeer && sighting.route == SZFriendsRouteMethodPeerToPeerWiFi) continue;
        NSString *endpoint = EndpointKey(sighting.method, sighting.endpointID);
        if (conversationID) {
            NSData *tag = [self matchedTagOfSighting:sighting conversationID:conversationID];
            NSString *key = [self backoffKeyForEndpoint:sighting.endpointID
                                                 method:sighting.method
                                                    tag:tag
                                         conversationID:conversationID];
            if ([self isBackingOff:key at:now]) continue;
            // Remembered for the failure report, which names only the endpoint.
            if (_endpointTags.count >= kBackoffEntriesMax && !_endpointTags[endpoint]) [_endpointTags removeAllObjects];
            if (tag) _endpointTags[endpoint] = tag;
            else [_endpointTags removeObjectForKey:endpoint];
        }
        // One attempt per endpoint even if a caller hands a candidate with a repeated sighting.
        if ([seen containsObject:endpoint]) continue;
        [seen addObject:endpoint];
        [attempts addObject:[[SZFriendsDialAttempt alloc] initWithSighting:sighting
                                                                     delay:SZFriendsDialDelayForRoute(sighting.route)]];
    }
    // Stable sort: equal delays keep the candidate's best-route-first order.
    [attempts sortWithOptions:NSSortStable
              usingComparator:^NSComparisonResult(SZFriendsDialAttempt *a, SZFriendsDialAttempt *b) {
                  if (a.delay < b.delay) return NSOrderedAscending;
                  if (a.delay > b.delay) return NSOrderedDescending;
                  return NSOrderedSame;
              }];
    return attempts;
}

// Both decisions compare by rank, never by number: by number Bluetooth (3) would beat Internet (4).
- (BOOL)shouldStartAttempt:(SZFriendsDialAttempt *)attempt currentRoute:(SZFriendsRouteMethod)current {
    if (current == SZFriendsRouteMethodNone) return YES;
    return SZFriendsRouteIsBetter(attempt.sighting.route, current);
}

- (SZFriendsRaceDecision)decisionForCompletedRoute:(SZFriendsRouteMethod)route
                                      currentRoute:(SZFriendsRouteMethod)current {
    if (current == SZFriendsRouteMethodNone) return SZFriendsRaceDecisionAdopt;
    // Strictly better only: an equal class is a duplicate, and moving traffic would gain nothing.
    if (route != SZFriendsRouteMethodNone && SZFriendsRouteIsBetter(route, current)) {
        return SZFriendsRaceDecisionUpgrade;
    }
    return SZFriendsRaceDecisionClose;
}

@end

BOOL SZFriendsSessionAWins(SZFriendsRouteMethod routeA, NSData *initiatorKeyA, SZFriendsRouteMethod routeB,
                           NSData *initiatorKeyB) {
    NSInteger rankA = SZFriendsRouteRank(routeA), rankB = SZFriendsRouteRank(routeB);
    if (rankA != rankB) return rankA < rankB;
    NSUInteger common = MIN(initiatorKeyA.length, initiatorKeyB.length);
    int order = common ? memcmp(initiatorKeyA.bytes, initiatorKeyB.bytes, common) : 0;
    if (order != 0) return order < 0;
    return initiatorKeyA.length <= initiatorKeyB.length;
}
