// Sync between this person's own devices in the helper (friends-multi-device.md § Sync; service/sync/SZFriendsSync.h).
//
// Our devices find each other nearby by tags only they can match (each device advertises a tag from the own-devices
// secret and its device key, and matches the others'), and online through the host's records per device key, as the
// online driver reaches a friend. They connect with IK using each other's keys from our chain, send the chain first,
// then run the sync exchange over SYNC frames until the session ends. Nothing of this runs at launch: the engine is
// made the first time our chain holds another device, and changes are captured only while such a session is live
// (a later session's first capture finds whatever happened meanwhile).

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "avatars/SZFriendsAvatars.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/online/SZFriendsOnlineTransport.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

// What the merger names our own devices' sightings by: "dev-" and the device key in hex.
static NSString *const SZFriendsOwnDevicePrefix = @"dev-";
// A dial to one of our devices that did not go live is not tried again before this.
static const NSTimeInterval SZFriendsOwnDeviceRedial = 30;
// Changes are captured at most this often while a session with another of our devices is live.
static const NSTimeInterval SZFriendsSyncCaptureDelay = 0.3;

static NSString *SZFriendsKeyHex(NSData *key) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:key.length * 2];
    const uint8_t *bytes = key.bytes;
    for (NSUInteger i = 0; i < key.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSData *_Nullable SZFriendsKeyFromHex(NSString *hex) {
    if (hex.length != 64) return nil;
    NSMutableData *key = [NSMutableData dataWithLength:32];
    for (NSUInteger i = 0; i < 32; i++) {
        unsigned value = 0;
        if (sscanf([hex substringWithRange:NSMakeRange(i * 2, 2)].UTF8String, "%2x", &value) != 1) return nil;
        ((uint8_t *)key.mutableBytes)[i] = (uint8_t)value;
    }
    return key;
}

@implementation SZFriendsNearbyService (Sync)

#pragma mark - The engine

- (nullable SZFriendsSyncEngine *)activeSyncEngine {
    SZFriendsStore *store = self.services.store;
    SZFriendsIdentity *identity = self.services.identity;
    if (store == nil || identity == nil || self.shutDown || self.resetting) return nil;
    if (self.syncEngine == nil) {
        // Cheap until our chain holds another device: two reads of the store's device index, no engine.
        NSData *root = [store rootKeyForDeviceKey:identity.publicKey];
        if (root == nil || [store devicesOfRootKey:root].count < 2) return nil;
        NSString *received = self.services.transfers.receivedDirectory;
        SZFriendsSyncEngine *engine = [[SZFriendsSyncEngine alloc] initWithStore:store identity:identity
                                                               receivedDirectory:received];
        __weak SZFriendsNearbyService *weakSelf = self;
        engine.onChange = ^(NSSet<NSString *> *conversations) {
            SZFriendsNearbyService *strongSelf = weakSelf;
            [strongSelf rebuildTagMatcher];
            [strongSelf refreshAdvertisement];
            // Two of our computers drew new secrets for the same removal and the other's won (+Devices).
            if ([strongSelf.syncEngine takePresenceSecretRetell]) [strongSelf tellFriendsPresenceSecret];
            // What another of our devices queued for a friend may leave from here (ADR 0014): on a session we hold
            // with that friend now, or one we dial for it.
            for (NSString *conversationID in conversations) [strongSelf outboxChangedForConversation:conversationID];
            [strongSelf changed];
        };
        engine.onNewEvents = ^{ [weakSelf pumpSyncExchanges]; };
        // A friend's message that reached another of the person's devices first notifies here too while fresh and
        // unread (ADR 0017); everything the person did there never does.
        engine.onItemsArrived = ^(NSArray<SZFriendsItemRecord *> *items) {
            [weakSelf.services.notifier noteSyncedItems:items];
        };
        NSString *pictures = self.services.paths.picturesDirectory;
        engine.storePicture = ^SZFriendsPicture *_Nullable(NSData *bytes) {
            // Bytes another of our devices stored after re-encoding them; checked and re-encoded here all the same.
            NSData *normalized = [SZFriendsPicturePipeline normalizedReceivedImage:bytes error:NULL];
            return normalized ? [SZFriendsPicturePipeline storeImage:normalized inDirectory:pictures error:NULL] : nil;
        };
        self.syncEngine = engine;
        // The first device's tags exist from now on, so our other devices can find it before any sync.
        if (engine.active) [engine ensureOwnDevicesSecret];
    }
    return self.syncEngine.active ? self.syncEngine : nil;
}

- (BOOL)isOwnDeviceKey:(NSData *)key {
    SZFriendsStore *store = self.services.store;
    NSData *local = [self localIdentityKey];
    NSData *root = local.length == 32 ? [store rootKeyForDeviceKey:local] : nil;
    if (key.length != 32 || root == nil || [key isEqualToData:[self localIdentityKey]]) return NO;
    return [[store rootKeyForDeviceKey:key] isEqualToData:root];
}

// Made on first use, so a helper with no other device of ours holds no tables for them.
- (NSMutableDictionary<NSString *, SZFriendsPeerLink *> *)syncLinks {
    if (self.syncLinkTable == nil) self.syncLinkTable = [NSMutableDictionary dictionary];
    return self.syncLinkTable;
}

- (NSMutableDictionary<NSString *, NSDate *> *)syncDialAfter {
    if (self.syncDialAfterTable == nil) self.syncDialAfterTable = [NSMutableDictionary dictionary];
    return self.syncDialAfterTable;
}

#pragma mark - Sessions

- (BOOL)syncAdoptsLiveLink:(SZFriendsPeerLink *)link {
    NSData *key = link.channel.remoteIdentityKey;
    if (![self isOwnDeviceKey:key]) return NO;
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    if (link.channel.pattern != SZFriendsHandshakeIK || engine == nil) {
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        return YES;
    }
    link.ownDevice = YES;
    NSString *hex = SZFriendsKeyHex(key);
    SZFriendsPeerLink *current = self.syncLinks[hex];
    if (current != nil && !current.closed && current != link) {
        // Both dialed at once: both sides keep the session the lower key opened, whichever arrived first.
        NSData *local = [self localIdentityKey];
        NSData *mine = [link initiatorKeyWithLocalKey:local], *theirs = [current initiatorKeyWithLocalKey:local];
        BOOL keepNew = mine && theirs && memcmp(mine.bytes, theirs.bytes, 32) < 0;
        SZFriendsPeerLink *loser = keepNew ? current : link;
        [loser.channel closeWithReason:SZFriendsCloseReasonSuperseded];
        if (!keepNew) return YES;
    }
    self.syncLinks[hex] = link;
    [self.syncDialAfter removeObjectForKey:hex];
    // Our chain first, so a device that missed an addition or a revocation hears it before any event.
    NSData *chain = self.services.store.ownDeviceChain.encodedData;
    if (chain != nil) {
        [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                                      fields:@{@(SZFriendsFieldChain) : chain}]];
    }
    __weak SZFriendsPeerLink *weakLink = link;
    SZFriendsSyncExchange *exchange = [[SZFriendsSyncExchange alloc]
        initWithEngine:engine
               peerKey:key
                  send:^(NSData *message) {
                      SZFriendsPeerLink *strongLink = weakLink;
                      if (strongLink == nil || strongLink.closed) return;
                      [strongLink.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeSync
                                                                           fields:@{@(SZFriendsFieldSync) : message}]];
                  }];
    link.syncExchange = exchange;
    [engine captureLocalChanges];
    [exchange start];
    [self changed];
    return YES;
}

- (void)link:(SZFriendsPeerLink *)link receivedOwnDeviceFrame:(SZFriendsFrame *)frame {
    SZFriendsStore *store = self.services.store;
    if (frame.type == SZFriendsFrameTypeChain) {
        // Removed already (by an earlier copy of the same news), this computer still reads its profile's chain.
        NSData *root = [store rootKeyForDeviceKey:[self localIdentityKey]] ?: store.ownDeviceChain.rootKey;
        NSData *data = [frame dataForTag:SZFriendsFieldChain];
        NSError *error = nil;
        SZFriendsDeviceChain *chain = root && data ? [SZFriendsDeviceChain chainWithData:data expectedRootKey:root
                                                                                   error:&error]
                                                   : nil;
        SZFriendsChainMergeResult result = chain ? [store mergeOwnDeviceChain:chain error:&error]
                                                 : SZFriendsChainMergeRefused;
        if (result == SZFriendsChainMergeRefused) {
            SZFriendsHelperLog(@"refused a chain from one of our devices: %@", error.localizedDescription);
            [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
            return;
        }
        SZFriendsDeviceChain *held = store.ownDeviceChain;
        if ([held revokesDeviceKey:[self localIdentityKey]] || ![self isOwnDeviceKey:link.channel.remoteIdentityKey]) {
            // This computer, or the one at the other end, was removed from the profile: the session ends here.
            [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        }
        if (result == SZFriendsChainMergeChanged) {
            [self rebuildTagMatcher];
            [self refreshAdvertisement];
            [self changed];
        }
        return;
    }
    if (frame.type != SZFriendsFrameTypeSync) return; // nothing else travels between our own devices
    // A chain just closed this session (one of us was removed): what the other side sent before it is moot.
    if (link.closed || ![self isOwnDeviceKey:link.channel.remoteIdentityKey]) return;
    NSData *message = [frame dataForTag:SZFriendsFieldSync];
    NSError *error = nil;
    if (message == nil || ![link.syncExchange receiveMessage:message error:&error]) {
        BOOL left = [error.domain isEqualToString:SZFriendsSyncErrorDomain] && error.code == SZFriendsSyncErrorInactive;
        SZFriendsHelperLog(@"sync with one of our devices %@: %@", left ? @"ended" : @"failed",
                           error.localizedDescription ?: @"no message");
        [link.channel closeWithReason:left ? SZFriendsCloseReasonNormal : SZFriendsCloseReasonProtocolError];
    }
}

- (void)syncLinkClosed:(SZFriendsPeerLink *)link {
    if (!link.ownDevice) {
        if (link.purpose == SZFriendsLinkPurposeOwnDevice && !link.live) [self noteOwnDeviceDialFailed:link];
        return;
    }
    [link.syncExchange stop];
    NSString *hex = SZFriendsKeyHex(link.channel.remoteIdentityKey);
    if (self.syncLinks[hex] == link) [self.syncLinks removeObjectForKey:hex];
    [self scheduleReconsider];
}

- (void)noteOwnDeviceDialFailed:(SZFriendsPeerLink *)link {
    NSString *hex = link.syncDeviceHex;
    if (hex) self.syncDialAfter[hex] = [NSDate dateWithTimeIntervalSinceNow:SZFriendsOwnDeviceRedial];
}

- (void)pumpSyncExchanges {
    for (SZFriendsPeerLink *link in self.syncLinks.allValues) [link.syncExchange pump];
}

// From -changed, at most once per SZFriendsSyncCaptureDelay: our devices as the store's index lists them (a device
// joined or was revoked: matched, advertised and dialed anew), and what changed in the store becomes events while a
// session can carry them.
- (void)scheduleSyncCapture {
    if (self.syncCaptureScheduled || self.shutDown) return;
    self.syncCaptureScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsSyncCaptureDelay * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.syncCaptureScheduled = NO;
        [strongSelf noticeOwnDevicesChange];
        if (strongSelf.syncLinks.count > 0) [[strongSelf activeSyncEngine] captureLocalChanges];
    });
}

- (void)noticeOwnDevicesChange {
    SZFriendsStore *store = self.services.store;
    NSData *local = [self localIdentityKey];
    NSData *root = local.length == 32 ? [store rootKeyForDeviceKey:local] : nil;
    NSMutableString *devices = [NSMutableString stringWithFormat:@"%d|", [self computeThisComputerRemoved]];
    for (SZFriendsDeviceRecord *device in root ? [store devicesOfRootKey:root] : @[]) {
        [devices appendFormat:@"%@:%ld:%@;", SZFriendsKeyHex(device.deviceKey), (long)device.state, device.name];
    }
    if ([devices isEqualToString:self.syncKnownDevices ?: @""]) return;
    self.syncKnownDevices = devices;
    [self ownDevicesChanged]; // removed computers, new secrets (+Devices)
    [self rebuildTagMatcher];
    [self refreshAdvertisement];
}

#pragma mark - Finding our devices nearby

- (NSDictionary<NSString *, NSArray<NSData *> *> *)ownDeviceTagSecrets {
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    NSData *secret = [engine ownDevicesSecret];
    if (secret == nil) return @{};
    NSMutableDictionary<NSString *, NSArray<NSData *> *> *secrets = [NSMutableDictionary dictionary];
    for (NSData *device in engine.otherDeviceKeys) {
        NSData *tagSecret = SZFriendsSyncDeviceTagSecret(secret, device);
        NSString *name = [SZFriendsOwnDevicePrefix stringByAppendingString:SZFriendsKeyHex(device)];
        if (tagSecret) secrets[name] = @[ tagSecret ];
    }
    [secrets addEntriesFromDictionary:[self removedDeviceTagSecrets]];
    return secrets;
}

- (nullable NSData *)ownDeviceTagAtDate:(NSDate *)date {
    NSData *secret = [[self activeSyncEngine] ownDevicesSecret];
    NSData *mine = secret ? SZFriendsSyncDeviceTagSecret(secret, [self localIdentityKey]) : nil;
    return mine ? SZFriendsPresenceTag(mine, SZFriendsPresenceWindowIndex(date)) : nil;
}

- (BOOL)reachOwnDeviceCandidate:(SZFriendsCandidate *)candidate {
    if ([self reachRemovedDeviceCandidate:candidate]) return YES; // one we removed, to tell it so (+Removed)
    NSString *name = candidate.conversationID;
    if (![name hasPrefix:SZFriendsOwnDevicePrefix]) return NO;
    NSString *hex = [name substringFromIndex:SZFriendsOwnDevicePrefix.length];
    NSData *device = SZFriendsKeyFromHex(hex);
    SZFriendsStore *store = self.services.store;
    NSData *root = [self activeSyncEngine].rootKey;
    NSData *staticKey = device && root ? [store staticKeyForDeviceKey:device ofRootKey:root] : nil;
    if (staticKey == nil || ![self isOwnDeviceKey:device]) return YES;
    SZFriendsPeerLink *live = self.syncLinks[hex];
    if (live != nil && !live.closed) return YES;
    NSDate *after = self.syncDialAfter[hex];
    if (after != nil && [after timeIntervalSinceNow] > 0) return YES;
    for (SZFriendsSighting *sighting in candidate.sightings) {
        if (sighting.isPublic) continue;
        SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
        options.pattern = SZFriendsHandshakeIK;
        options.route = sighting.route;
        options.remoteStaticKey = staticKey;
        options.expectedIdentityKey = device;
        SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                              purpose:SZFriendsLinkPurposeOwnDevice
                                                              options:options];
        plan.ownDeviceHex = hex;
        if ([self dial:plan]) {
            // Not again for a while, however it ends: a session that goes live clears this (-syncAdoptsLiveLink:).
            self.syncDialAfter[hex] = [NSDate dateWithTimeIntervalSinceNow:SZFriendsOwnDeviceRedial];
            break;
        }
    }
    return YES;
}

#pragma mark - Reaching our devices

- (void)reachOwnDevices {
    [self probeForOwnDevices];
    [self reachOwnDevicesOnline];
}

// A device that has not learned the own-devices secret yet (it just joined) cannot match its siblings' tags: it tries
// IK at each unrecognised device nearby, once per device and presence window, for each of our devices with no session.
// A device that is not ours cannot decrypt IK's first message and learns nothing (as a friend's probe, +Dial).
- (void)probeForOwnDevices {
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    if (engine == nil || [engine ownDevicesSecret] != nil) return;
    NSArray<SZFriendsCandidate *> *unmatched = self.coordinator.merger.unmatchedDevices;
    SZFriendsStore *store = self.services.store;
    int64_t window = [self currentWindow];
    NSDate *windowEnd = SZFriendsPresenceWindowEnd([NSDate date]);
    for (NSData *device in engine.otherDeviceKeys) {
        NSString *hex = SZFriendsKeyHex(device);
        SZFriendsPeerLink *live = self.syncLinks[hex];
        NSData *staticKey = [store staticKeyForDeviceKey:device ofRootKey:engine.rootKey];
        if ((live != nil && !live.closed) || staticKey == nil) continue;
        for (SZFriendsCandidate *candidate in unmatched) {
            SZFriendsSighting *sighting = candidate.sightings.firstObject;
            if (sighting == nil || sighting.isPublic) continue;
            NSString *key = [NSString stringWithFormat:@"own|%@|%@|%lld", hex, sighting.endpointID, (long long)window];
            if (self.attempts[key] != nil) continue;
            self.attempts[key] = windowEnd;
            SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
            options.pattern = SZFriendsHandshakeIK;
            options.route = sighting.route;
            options.remoteStaticKey = staticKey;
            options.expectedIdentityKey = device;
            SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                                  purpose:SZFriendsLinkPurposeOwnDevice
                                                                  options:options];
            plan.ownDeviceHex = hex;
            plan.probe = YES;
            [self dial:plan];
        }
    }
}

- (void)reachOwnDevicesOnline {
    SZFriendsOnlineDriver *driver = self.onlineDriver;
    SZFriendsSyncEngine *engine = driver.available ? [self activeSyncEngine] : nil;
    for (NSData *device in engine.otherDeviceKeys) {
        SZFriendsPeerLink *live = self.syncLinks[SZFriendsKeyHex(device)];
        if (live != nil && !live.closed && !SZFriendsRouteIsBetter(SZFriendsRouteMethodInternet, live.raceRoute)) {
            continue;
        }
        [driver reachFriend:device];
    }
}

- (nullable SZFriendsOnlineFriend *)onlineOwnDeviceWithKey:(NSData *)deviceKey {
    NSData *root = [self isOwnDeviceKey:deviceKey] ? [self activeSyncEngine].rootKey : nil;
    if (root == nil) return nil;
    SZFriendsStore *store = self.services.store;
    NSData *staticKey = [store staticKeyForDeviceKey:deviceKey ofRootKey:root];
    if (staticKey.length != 32) return nil;
    SZFriendsOnlineFriend *device = [[SZFriendsOnlineFriend alloc] init];
    device.identityKey = deviceKey;
    device.staticKey = staticKey;
    // Every device of ours publishes its record under the one presence secret they share (a synced setting), filed
    // under our root, so an open to it reaches each of them and the one it is sealed to answers.
    device.presenceSecret = store.ownPresenceSecret;
    device.rootKey = root;
    return device;
}

- (SZFriendsRouteMethod)nearbyRouteToOwnDevice:(NSData *)deviceKey {
    SZFriendsPeerLink *live = self.syncLinks[SZFriendsKeyHex(deviceKey)];
    SZFriendsRouteMethod route = live && !live.closed ? live.raceRoute : SZFriendsRouteMethodNone;
    BOOL online = route == SZFriendsRouteMethodInternet || route == SZFriendsRouteMethodRelay;
    return online ? SZFriendsRouteMethodNone : route;
}

- (BOOL)openOwnDeviceStream:(id<SZFriendsByteStream>)stream route:(SZFriendsRouteMethod)route device:(NSData *)key {
    SZFriendsOnlineFriend *device = [self onlineOwnDeviceWithKey:key];
    if (device == nil) return NO;
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = SZFriendsHandshakeIK;
    options.route = route;
    options.remoteStaticKey = device.staticKey;
    options.expectedIdentityKey = key;
    SZFriendsSecureChannel *channel = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                                       identity:self.services.identity
                                                                                        options:options
                                                                                          queue:self.queue];
    SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:channel
                                                                 purpose:SZFriendsLinkPurposeOwnDevice
                                                                   route:route];
    link.syncDeviceHex = SZFriendsKeyHex(key);
    [self startLink:link];
    return YES;
}

@end

@implementation SZFriendsNearbyService (SyncHistory)

- (BOOL)eraseHistoryInConversation:(nullable NSString *)conversationID {
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    if (engine == nil) return [self.services.store deleteHistoryInConversation:conversationID error:NULL];
    return [engine deleteHistoryInConversation:conversationID error:NULL];
}

@end
