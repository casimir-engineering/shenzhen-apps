// Telling a computer it was removed (PROTOCOL.md § Devices, This computer was removed; ADR 0012). A computer removed
// while it was away hears nothing by itself: its sessions with our computers are gone, and the secrets it finds them by
// were drawn again. So our computers look for it too, by the tags it still advertises (under the own-devices secret it
// holds, the current one or one replaced since), and dial it; and when it dials one of them, its handshake completes.
// Either way the session carries one frame, our chain, which says it was removed and which it can verify itself, and
// then closes. Nothing else reaches it: no sync, no friend's message.

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

static NSString *const SZFriendsRemovedDevicePrefix = @"rmv-";
// A removed computer seen nearby is dialed again where it was seen at most this often, however the last try ended.
static const NSTimeInterval SZFriendsRemovedDeviceRedial = 60;

static NSData *_Nullable SZFriendsRemovedKeyFromHex(NSString *hex) {
    if (hex.length != 64) return nil;
    NSMutableData *key = [NSMutableData dataWithLength:32];
    for (NSUInteger i = 0; i < 32; i++) {
        unsigned value = 0;
        if (sscanf([hex substringWithRange:NSMakeRange(i * 2, 2)].UTF8String, "%2x", &value) != 1) return nil;
        ((uint8_t *)key.mutableBytes)[i] = (uint8_t)value;
    }
    return key;
}

@implementation SZFriendsNearbyService (Removed)

- (BOOL)isOwnRemovedDeviceKey:(NSData *)key {
    if (key.length != 32 || self.removedFromProfile || self.services.identity == nil) return NO;
    SZFriendsStore *store = self.services.store;
    NSData *root = [store rootKeyForDeviceKey:[self localIdentityKey]];
    if (root == nil) return NO; // this computer was removed too
    // The store's index of our chain, not the chain itself: asked on every handshake such a computer starts.
    for (SZFriendsDeviceRecord *device in [store devicesOfRootKey:root]) {
        if ([device.deviceKey isEqualToData:key]) return device.state == SZFriendsChainDeviceRevoked;
    }
    return NO;
}

- (NSDictionary<NSString *, NSArray<NSData *> *> *)removedDeviceTagSecrets {
    SZFriendsSyncEngine *engine = [self activeSyncEngine];
    NSData *current = [engine ownDevicesSecret];
    if (engine == nil || current == nil || self.removedFromProfile) return @{};
    NSArray<NSData *> *held = [@[ current ] arrayByAddingObjectsFromArray:[engine previousOwnDevicesSecrets]];
    NSMutableDictionary<NSString *, NSArray<NSData *> *> *secrets = [NSMutableDictionary dictionary];
    NSData *root = engine.rootKey;
    for (SZFriendsDeviceRecord *device in root ? [self.services.store devicesOfRootKey:root] : @[]) {
        if (device.state != SZFriendsChainDeviceRevoked) continue;
        NSMutableArray<NSData *> *tags = [NSMutableArray array];
        for (NSData *secret in held) {
            NSData *tagSecret = SZFriendsSyncDeviceTagSecret(secret, device.deviceKey);
            if (tagSecret) [tags addObject:tagSecret];
        }
        NSString *name = [SZFriendsRemovedDevicePrefix stringByAppendingString:SZFriendsLinkHex(device.deviceKey)];
        if (tags.count > 0) secrets[name] = tags;
    }
    return secrets;
}

- (BOOL)reachRemovedDeviceCandidate:(SZFriendsCandidate *)candidate {
    NSString *name = candidate.conversationID;
    if (![name hasPrefix:SZFriendsRemovedDevicePrefix]) return NO;
    NSString *hex = [name substringFromIndex:SZFriendsRemovedDevicePrefix.length];
    NSData *device = SZFriendsRemovedKeyFromHex(hex);
    SZFriendsChainDevice *known = device ? [self.services.store.ownDeviceChain deviceWithKey:device] : nil;
    if (known == nil || known.state != SZFriendsChainDeviceRevoked || ![self isOwnRemovedDeviceKey:device]) return YES;
    for (SZFriendsSighting *sighting in candidate.sightings) {
        if (sighting.isPublic) continue;
        // Per place it was seen: a sighting from before it went away must not hold back the one where it is now.
        NSString *throttle = [NSString stringWithFormat:@"removed|%@|%@", hex, sighting.endpointID];
        NSDate *after = self.syncDialAfter[throttle];
        if (after != nil && [after timeIntervalSinceNow] > 0) continue;
        SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
        options.pattern = SZFriendsHandshakeIK;
        options.route = sighting.route;
        options.remoteStaticKey = known.staticKey;
        options.expectedIdentityKey = device;
        SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                              purpose:SZFriendsLinkPurposeOwnDevice
                                                              options:options];
        if ([self dial:plan]) {
            self.syncDialAfter[throttle] = [NSDate dateWithTimeIntervalSinceNow:SZFriendsRemovedDeviceRedial];
            break;
        }
    }
    return YES;
}

- (void)tellRemovedComputerOnLink:(SZFriendsPeerLink *)link {
    SZFriendsSecureChannel *channel = link.channel;
    NSData *chain = self.services.store.ownDeviceChain.encodedData;
    if (!link.closed && channel.pattern == SZFriendsHandshakeIK && channel.negotiatedMinor >= 2 && chain != nil) {
        SZFriendsHelperLog(@"told a computer removed from the profile that it was removed");
        [channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                                  fields:@{@(SZFriendsFieldChain) : chain}]];
    }
    [channel closeWithReason:SZFriendsCloseReasonNormal];
}

@end
