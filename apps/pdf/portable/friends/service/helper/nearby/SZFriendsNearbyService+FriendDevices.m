// Friends reach whichever of a person's devices they find (friends-multi-device.md § Sync, Friends; ADR 0012).
//
// A person's first device keeps advertising the person's presence tags, which every friend recognises; each of their
// other devices advertises tags of its own, from the person's presence secret and its device key, so a friend who holds
// the person's chain knows which device it sees and dials it with IK to the static key the chain gives that device.
// Online, the driver is asked for each of the person's devices (each publishes its record under its own key). The
// session then belongs to the person's conversation like any other: whatever is queued for them goes, and what they
// send arrives, on whichever device it is; that device's sync passes it to the others.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/online/SZFriendsOnlineTransport.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

// What the merger names a friend's other device: "fdev-", its key in hex, "-", the conversation.
static NSString *const SZFriendsFriendDevicePrefix = @"fdev-";

NSString *_Nullable SZFriendsNearbyFriendDeviceConversation(NSString *_Nullable name,
                                                           NSData *_Nullable *_Nullable key) {
    NSUInteger keyStart = SZFriendsFriendDevicePrefix.length;
    if (![name hasPrefix:SZFriendsFriendDevicePrefix] || name.length < keyStart + 66 ||
        [name characterAtIndex:keyStart + 64] != '-') {
        return nil;
    }
    NSData *device = SZFriendsLinkBytesFromHex([name substringWithRange:NSMakeRange(keyStart, 32)]);
    NSData *rest = SZFriendsLinkBytesFromHex([name substringWithRange:NSMakeRange(keyStart + 32, 32)]);
    if (device == nil || rest == nil) return nil;
    NSMutableData *full = [device mutableCopy];
    [full appendData:rest];
    if (key) *key = full;
    return [name substringFromIndex:keyStart + 65];
}

@implementation SZFriendsNearbyService (FriendDevices)

#pragma mark - Being found

- (nullable NSData *)ownFriendPresenceTagAtDate:(NSDate *)date {
    SZFriendsStore *store = self.services.store;
    NSData *local = [self localIdentityKey], *secret = store.ownPresenceSecret;
    NSData *root = local.length == 32 ? [store rootKeyForDeviceKey:local] : nil;
    if (root == nil || [root isEqualToData:local] || secret.length != 32) return nil; // the first device: as before
    NSData *mine = SZFriendsSyncFriendDeviceTagSecret(secret, local);
    return mine ? SZFriendsPresenceTag(mine, SZFriendsPresenceWindowIndex(date)) : nil;
}

#pragma mark - Finding friends' other devices

- (NSDictionary<NSString *, NSArray<NSData *> *> *)friendDeviceTagSecrets {
    NSMutableDictionary<NSString *, NSArray<NSData *> *> *secrets = [NSMutableDictionary dictionary];
    SZFriendsStore *store = self.services.store;
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        if (person.relation != SZFriendsRelationFriend || person.presenceSecret.length != 32 ||
            person.identityKey.length != 32) {
            continue;
        }
        for (SZFriendsDeviceRecord *device in [store devicesOfRootKey:person.identityKey]) {
            if (device.isRoot || device.state != SZFriendsChainDeviceAuthorized) continue;
            NSData *secret = SZFriendsSyncFriendDeviceTagSecret(person.presenceSecret, device.deviceKey);
            NSString *name = [NSString stringWithFormat:@"%@%@-%@", SZFriendsFriendDevicePrefix,
                                                        SZFriendsLinkHex(device.deviceKey), person.conversationID];
            if (secret) secrets[name] = @[ secret ];
        }
    }
    return secrets;
}

- (nullable SZFriendsHandshakeOptions *)ikOptionsForPerson:(SZFriendsPersonRecord *)person
                                                    device:(NSData *)deviceKey
                                                     route:(SZFriendsRouteMethod)route {
    NSData *staticKey = person.identityKey ? [self.services.store staticKeyForDeviceKey:deviceKey
                                                                              ofRootKey:person.identityKey]
                                           : nil;
    if (staticKey == nil || person.relation != SZFriendsRelationFriend || person.keyChangePending) return nil;
    SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person route:route];
    options.remoteStaticKey = staticKey;
    options.expectedIdentityKey = deviceKey;
    return options;
}

- (BOOL)reachFriendDeviceCandidate:(SZFriendsCandidate *)candidate {
    NSData *device = nil;
    NSString *conversationID = SZFriendsNearbyFriendDeviceConversation(candidate.conversationID, &device);
    if (conversationID == nil) return NO;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:conversationID];
    // One session per conversation: a friend's other device is dialed while none of theirs carries one.
    if (person == nil || [self liveLinkForConversation:conversationID] != nil ||
        ![self mayDialConversation:conversationID]) {
        return YES;
    }
    BOOL started = NO;
    for (SZFriendsDialAttempt *attempt in [self.coordinator.racer attemptsForCandidate:candidate]) {
        if (![self.coordinator.racer shouldStartAttempt:attempt currentRoute:SZFriendsRouteMethodNone]) continue;
        SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person device:device
                                                                route:attempt.sighting.route];
        if (options == nil) return YES;
        SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:attempt.sighting
                                                              purpose:SZFriendsLinkPurposeFriend
                                                              options:options];
        plan.conversationID = conversationID;
        plan.delay = attempt.delay;
        started = [self dial:plan] || started;
    }
    if (started && [self hasDeliverableEntriesForPerson:person]) [self markConnectingForConversation:conversationID];
    return YES;
}

#pragma mark - Online

- (void)reachOtherDevicesOfFriendOnline:(SZFriendsPersonRecord *)person {
    if (person.identityKey.length != 32) return;
    for (SZFriendsDeviceRecord *device in [self.services.store devicesOfRootKey:person.identityKey]) {
        if (device.isRoot || device.state != SZFriendsChainDeviceAuthorized) continue;
        [self.onlineDriver reachFriend:device.deviceKey];
    }
}

- (nullable SZFriendsOnlineFriend *)onlineFriendDeviceWithKey:(NSData *)deviceKey {
    SZFriendsPersonRecord *person = [self.services.store personWithIdentityKey:deviceKey];
    if (person == nil || [person.identityKey isEqualToData:deviceKey]) return nil; // their first device: as before
    SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person device:deviceKey
                                                            route:SZFriendsRouteMethodInternet];
    if (options == nil) return nil;
    SZFriendsOnlineFriend *friend = [[SZFriendsOnlineFriend alloc] init];
    friend.identityKey = deviceKey;
    friend.staticKey = options.remoteStaticKey;
    friend.presenceSecret = person.presenceSecret;
    friend.requestToken = person.callbackToken;
    friend.rootKey = person.identityKey; // their records are filed under the person, which every device of theirs hears
    return friend;
}

- (BOOL)openFriendDeviceStream:(id<SZFriendsByteStream>)stream
                         route:(SZFriendsRouteMethod)route
                        device:(NSData *)deviceKey {
    SZFriendsPersonRecord *person = [self.services.store personWithIdentityKey:deviceKey];
    if (person == nil || [person.identityKey isEqualToData:deviceKey]) return NO;
    SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person device:deviceKey route:route];
    if (options == nil) {
        [stream close];
        return YES;
    }
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
    return YES;
}

@end
