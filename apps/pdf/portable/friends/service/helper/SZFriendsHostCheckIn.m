// The helper's host check-in (SZFriendsHostCheckIn.h).

#import "service/helper/SZFriendsHostCheckIn.h"

#import "client/szfriends_client.h"
#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperLinks.h"
#import "service/helper/SZFriendsHelperServices.h"
#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/host/SZFriendsHostRendezvous.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/store/SZFriendsStoreSync.h"

NSString *const SZFriendsCheckInPreJoinReleaseKey = @"checkin_release_pre_join";
NSString *const SZFriendsCheckInRemovedByHostKey = @"checkin_removed_by_host";

@implementation SZFriendsCheckInSetup

- (instancetype)initWithList:(NSData *)list keys:(NSArray<NSData *> *)keys loopbackOnly:(BOOL)loopbackOnly {
    if ((self = [super init])) {
        _bootstrapData = [list copy];
        _pinnedKeys = [keys copy];
        _loopbackOnly = loopbackOnly;
    }
    return self;
}

+ (nullable instancetype)setupWithEnvironment:(NSDictionary<NSString *, NSString *> *)env
                                  bundledList:(nullable NSData *)bundledList
                                  bundledKeys:(nullable NSData *)bundledKeys
                                          why:(NSString **)why {
    NSString *reason = nil;
    SZFriendsCheckInSetup *setup = nil;
    if (env[@SZFRIENDS_ENV_STATE_DIR] == nil) {
        NSArray<NSData *> *keys = bundledKeys ? SZFriendsHostPinnedKeysFromData(bundledKeys, NULL, NULL) : nil;
        if (bundledList == nil || keys.count == 0) reason = @"no bundled host list or pinned keys";
        else setup = [[self alloc] initWithList:bundledList keys:keys loopbackOnly:NO];
    } else {
        NSString *listPath = env[@"SZFRIENDS_TEST_HOST_LIST"], *keysPath = env[@"SZFRIENDS_TEST_HOST_KEYS"];
        NSData *list = listPath.absolutePath ? [NSData dataWithContentsOfFile:listPath] : nil;
        NSData *keysData = keysPath.absolutePath ? [NSData dataWithContentsOfFile:keysPath] : nil;
        NSArray<NSData *> *keys = keysData ? SZFriendsHostPinnedKeysFromData(keysData, NULL, NULL) : nil;
        SZFriendsHostList *parsed = (list && keys.count) ? [SZFriendsHostList listFromSignedData:list pinnedKeys:keys
                                                                                           error:NULL]
                                                         : nil;
        if (listPath == nil && keysPath == nil) reason = @"tests never check in without a loopback host list";
        else if (parsed == nil) reason = @"the test host list is missing or does not verify";
        else if (!SZFriendsHostListIsLoopbackOnly(parsed)) reason = @"the test host list names a non-loopback host";
        else setup = [[self alloc] initWithList:list keys:keys loopbackOnly:YES];
    }
    if (why) *why = reason;
    return setup;
}

@end

// "stun:127.0.0.1:3478", "turn:[::1]:3478?transport=udp" -> "127.0.0.1", "::1"; "" for anything else.
static NSString *SZFriendsHostOfICEURI(NSString *uri) {
    NSRange colon = [uri rangeOfString:@":"];
    NSString *scheme = colon.location == NSNotFound ? @"" : [uri substringToIndex:colon.location].lowercaseString;
    if (![@[ @"stun", @"turn", @"turns" ] containsObject:scheme]) return @"";
    NSString *rest = [uri substringFromIndex:colon.location + 1];
    NSRange query = [rest rangeOfString:@"?"];
    if (query.location != NSNotFound) rest = [rest substringToIndex:query.location];
    if ([rest hasPrefix:@"["]) {
        NSRange close = [rest rangeOfString:@"]"];
        return close.location == NSNotFound ? @"" : [rest substringWithRange:NSMakeRange(1, close.location - 1)];
    }
    NSArray<NSString *> *parts = [rest componentsSeparatedByString:@":"];
    return parts.count <= 2 ? parts[0].lowercaseString : @"";
}

BOOL SZFriendsHostListIsLoopbackOnly(SZFriendsHostList *list) {
    NSSet<NSString *> *hosts = [NSSet setWithArray:@[ @"127.0.0.1", @"::1", @"[::1]", @"localhost" ]];
    for (SZFriendsHostEntry *entry in list.entries) {
        for (NSURL *url in entry.urls) {
            NSString *scheme = url.scheme.lowercaseString;
            if (!([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"]) ||
                ![hosts containsObject:url.host.lowercaseString ?: @""]) {
                return NO;
            }
        }
        // STUN and TURN too (online Friends' tests run them on loopback): stun:, turn: or turns:, then the host.
        for (NSString *uri in entry.turnURIs) {
            if (![hosts containsObject:SZFriendsHostOfICEURI(uri)]) return NO;
        }
    }
    return YES;
}

void SZFriendsConfigureCheckInMembership(SZFriendsCheckInClient *client, SZFriendsStore *store, NSData *localKey) {
    client.membershipProvider = ^NSData *(NSData **chain) {
        NSData *root = [store rootKeyForDeviceKey:localKey];
        if (root == nil) return nil;
        // The first computer is the person: it brings the chain once there are others, so the host turns away the
        // computers it removed.
        if ([root isEqualToData:localKey] && [store devicesOfRootKey:root].count < 2) return nil;
        *chain = store.ownDeviceChain.encodedData;
        return root;
    };
    NSData *root = [store rootKeyForDeviceKey:localKey];
    client.drawsIDs = root == nil || [root isEqualToData:localKey];
}

@implementation SZFriendsHelperCheckIn {
    SZFriendsHelperServices *_services;
    SZFriendsCheckInSetup *_setup;
    SZFriendsHostListCache *_cache;
    dispatch_queue_t _queue;
    SZFriendsCheckInClient *_client;
    // The client doing Reset Friends' release, held until it finishes: the client keeps only weak references to
    // itself in its timers, so dropping it here used to free it mid-release and the reset never answered.
    SZFriendsCheckInClient *_releasing;
    SZFriendsIDStatus *_claim; // the ID most recently claimed in this connection's run of collisions
    SZFriendsHostState _state;
    BOOL _preJoinReleaseTried; // once per launch: a host that does not answer is asked again at the next start
    BOOL _wanted;              // started and not stopped since: a release that finishes later checks in only then
}

- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                           setup:(SZFriendsCheckInSetup *)setup
                           cache:(SZFriendsHostListCache *)cache
                           queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _services = services;
        _setup = setup;
        _cache = cache;
        _queue = queue;
    }
    return self;
}

- (void)start {
    _wanted = YES;
    SZFriendsStore *store = _services.store;
    if (_client != nil || _services.identity == nil || store == nil || _services.codec == nil) return;
    // A list the local test host pushed must still be loopback-only before anything connects.
    if (_setup.loopbackOnly && !SZFriendsHostListIsLoopbackOnly(_cache.currentList)) {
        SZFriendsHelperLog(@"check-in skipped: the current host list names a non-loopback host");
        return;
    }
    // A computer another of the person's computers removed never checks in again (the host would refuse it).
    if ([store isRevokedDeviceKey:_services.identity.publicKey] ||
        [[store syncStateForKey:SZFriendsCheckInRemovedByHostKey] boolValue]) {
        SZFriendsHelperLog(@"check-in skipped: this computer was removed from its profile");
        return;
    }
    BOOL owesRelease = [[store syncStateForKey:SZFriendsCheckInPreJoinReleaseKey] boolValue];
    if (_releasing == nil && !_preJoinReleaseTried && owesRelease) {
        [self releasePreJoinIDThenStart];
        return;
    }
    if (_releasing != nil) return; // the release before it is still running; it starts the check-in when done
    _client = [[SZFriendsCheckInClient alloc] initWithListCache:_cache
                                                       identity:_services.identity
                                                     appVersion:SZFriendsHelperVersionString()
                                                  socketFactory:SZFriendsHostWebSocketFactory(_queue)
                                                          queue:_queue];
    _client.delegate = self;
    _clientsStarted += 1;
    SZFriendsConfigureCheckInMembership(_client, store, _services.identity.publicKey);
    // Online Friends (protocol 2): the driver waits for a welcome that says online, and costs nothing until then.
    [_services.nearby attachOnlineHost:_client.online];
    // Download links: opens via a link id go to the link service, which registers its links once the host is online.
    [_services attachLinksToHostOnline:_client.online];
    _client.friendsIDReserved = store.friendsIDState != SZFriendsIDStateUnreserved;
    __weak SZFriendsHelperCheckIn *weakSelf = self;
    [_client startWithFriendsIDProvider:^NSString *(NSUInteger collisionsInARow) {
        SZFriendsHelperCheckIn *strongSelf = weakSelf;
        return strongSelf ? [strongSelf friendsIDForCollisionsInARow:collisionsInARow] : @"";
    }];
}

- (void)stop {
    _wanted = NO;
    [_client stop];
    _client = nil;
}

- (void)restartAfterRevoking {
    if (_client == nil) return; // not checking in: the next check-in brings the chain anyway
    [self stop];
    [self start];
}

- (void)restartAfterJoining {
    _preJoinReleaseTried = NO;
    [self stop];
    [self start];
}

// The ID this computer reserved for itself before it joined a profile stays its own on the host until released, an
// ID nobody would ever use: released first, with this computer's key, then the check-in for the person starts.
- (void)releasePreJoinIDThenStart {
    _preJoinReleaseTried = YES;
    SZFriendsCheckInClient *client =
        [[SZFriendsCheckInClient alloc] initWithListCache:_cache
                                                 identity:_services.identity
                                               appVersion:SZFriendsHelperVersionString()
                                            socketFactory:SZFriendsHostWebSocketFactory(_queue)
                                                    queue:_queue];
    // Its attestation file is the one the check-in keeps for the person's ID: a release must not delete it.
    client.attestationPath = nil;
    _releasing = client;
    __weak SZFriendsHelperCheckIn *weakSelf = self;
    SZFriendsStore *store = _services.store;
    [client releaseIdentityWithCompletion:^(BOOL released) {
        SZFriendsHelperLog(@"the ID from before joining: release %@", released ? @"confirmed" : @"not confirmed");
        if (released) [store setSyncState:nil forKey:SZFriendsCheckInPreJoinReleaseKey error:NULL];
        SZFriendsHelperCheckIn *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf->_releasing = nil;
        if (strongSelf->_wanted) [strongSelf start]; // not after Disable or exit meanwhile
    }];
}

// The person's first computer while the profile has others: its key is the person's, and so is the ID the others
// check in with. Reset Friends here must not free it.
static BOOL SZFriendsCheckInIDIsShared(SZFriendsStore *store, NSData *localKey) {
    NSData *root = [store rootKeyForDeviceKey:localKey];
    if (root == nil || ![root isEqualToData:localKey]) return NO;
    for (SZFriendsDeviceRecord *device in [store devicesOfRootKey:root]) {
        if (device.state == SZFriendsChainDeviceAuthorized && ![device.deviceKey isEqualToData:localKey]) return YES;
    }
    return NO;
}

- (void)releaseIdentityWithCompletion:(void (^)(void))completion {
    SZFriendsCheckInClient *client = _client;
    _client = nil;
    if (client != nil && SZFriendsCheckInIDIsShared(_services.store, _services.identity.publicKey)) {
        SZFriendsHelperLog(@"Reset Friends on the profile's first computer: its ID stays with the other computers");
        [client stop];
        client = nil;
    }
    if (client == nil) {
        completion();
        return;
    }
    // The host forgets this identity and frees its ID; the reset goes ahead whether or not it answered.
    _releasing = client;
    __weak SZFriendsHelperCheckIn *weakSelf = self;
    [client releaseIdentityWithCompletion:^(BOOL released) {
        SZFriendsHelperLog(@"identity release %@", released ? @"confirmed" : @"not confirmed");
        SZFriendsHelperCheckIn *strongSelf = weakSelf;
        if (strongSelf != nil) strongSelf->_releasing = nil;
        completion();
    }];
}

#pragma mark - The Friends ID (ADR 0006)

- (SZFriendsIDStatus *)storedStatus {
    SZFriendsStore *store = _services.store;
    return [[SZFriendsIDStatus alloc] initWithFriendsID:store.friendsID ?: @""
                                                  state:(SZFriendsIDState)store.friendsIDState
                                             previousID:store.previousFriendsID
                                       collisionsInARow:store.idCollisionsInARow];
}

- (void)storeStatus:(SZFriendsIDStatus *)status {
    SZFriendsStore *store = _services.store;
    store.friendsID = status.friendsID;
    store.friendsIDState = status.state;
    store.previousFriendsID = status.previousID;
    store.idCollisionsInARow = status.collisionsInARow;
    if (self.onChange) self.onChange();
}

- (NSString *)friendsIDForCollisionsInARow:(NSUInteger)collisionsInARow {
    if (collisionsInARow == 0) {
        _claim = [self storedStatus];
        return _claim.friendsID;
    }
    // The stored ID stays what the person knows until a new one is reserved; only the collision count is kept,
    // so three in a row move to three-word IDs even across launches.
    SZFriendsIDStatus *collided = [(_claim ?: [self storedStatus]) statusAfterCollision];
    _services.store.idCollisionsInARow = collided.collisionsInARow;
    NSString *next = [collided replacementIDWithCodec:_services.codec
                                       listNewIDWords:_cache.currentList.newIDWords
                                            generator:SZFriendsSystemRandomUniform()];
    _claim = [[SZFriendsIDStatus alloc] initWithFriendsID:next
                                                    state:SZFriendsIDStateUnreserved
                                               previousID:nil
                                         collisionsInARow:collided.collisionsInARow];
    return next;
}

- (nullable SZFriendsHostAttestation *)attestationForFriendsID:(NSString *)friendsID {
    return [_client attestationForFriendsID:friendsID];
}

#pragma mark - SZFriendsCheckInDelegate

- (void)checkInStateDidChange:(SZFriendsHostState)state {
    // Quiet by design: an unreachable host changes nothing the person sees (Nearby is unaffected).
    if (state == SZFriendsHostStateConnected && _state != state) SZFriendsHelperLog(@"checked in");
    _state = state;
}

// An ID the host hands back becomes the person's own shareable ID and appears in the notice they read, so it must be
// one the word list could have made: anything else (a long string, direction overrides, a newline) is not stored
// (review: the host client adopted any string). nil when it is not.
- (nullable NSString *)acceptableID:(NSString *)friendsID {
    NSString *normalized = [friendsID isKindOfClass:[NSString class]] ? [_services.codec normalizedID:friendsID] : nil;
    if (normalized == nil || ![normalized isEqualToString:friendsID]) {
        SZFriendsHelperLog(@"the host answered with an ID that is not a Friends ID; ignored");
        return nil;
    }
    return normalized;
}

- (void)checkInDidReserveID:(NSString *)friendsID {
    NSString *reserved = [self acceptableID:friendsID];
    if (reserved == nil) return;
    [self storeStatus:[[self storedStatus] statusAfterReservationOf:reserved]];
}

- (void)checkInDidRenameIDFrom:(NSString *)friendsID to:(NSString *)newID {
    NSString *renamed = [self acceptableID:newID];
    if (renamed == nil) return;
    // Keys, friends and history stay: friends are stored by key. The list tells the person once.
    [self storeStatus:[[self storedStatus] statusAfterRenameFrom:friendsID to:renamed]];
}

- (void)checkInDeviceWasRevoked {
    // The host knew first: the chain carrying the revocation reaches this computer later, or never.
    [_services.store setSyncState:@YES forKey:SZFriendsCheckInRemovedByHostKey error:NULL];
    _client = nil;
    SZFriendsHelperLog(@"the host says this computer was removed from its profile");
    [_services.nearby hostSaysThisComputerWasRemoved];
    if (self.onChange) self.onChange();
}

- (void)checkInRequiresUpdate {
    // Online Friends needs a newer app; reading and Nearby keep working. A store another app migrated says more.
    if (_services.updateNeed == SZFriendsUpdateNeedNone) _services.updateNeed = SZFriendsUpdateNeedOnline;
    if (self.onChange) self.onChange();
}

@end
