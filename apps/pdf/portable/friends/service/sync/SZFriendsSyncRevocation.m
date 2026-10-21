// What a revoked device of ours still counts for (SZFriendsSync.h, SZFriendsSyncKindRevocation). A device that revokes
// another records how many of that device's events it held; our devices accept that device's events up to there and
// none after, whoever forwards them, so a stolen computer cannot keep writing into the person's chats once removed. A
// record counts only from the device that signed the revocation in our chain. The secrets our devices and friends
// find us by are drawn again after a revocation, by one authorized device: the first, or the next ones in turn when it
// has not after a wait.

#import <sodium.h>

#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Own-devices secrets kept after they were replaced, for finding a computer removed while away (SZFriendsSync.h).
static const NSUInteger SZFriendsSyncPreviousSecretsMax = 4;

static NSString *SZFriendsSyncRevocationKey(NSData *deviceKey) {
    return [@"rv/" stringByAppendingString:SZFriendsSyncHex(deviceKey)];
}

static NSData *SZFriendsSyncSeqValue(uint64_t seq) {
    NSMutableData *value = [NSMutableData data];
    SZFriendsSyncPutU64(value, seq);
    return value;
}

@implementation SZFriendsSyncEngine (Revocation)

// YES when our chain holds a revocation of `subject` signed by `signer`.
- (BOOL)chain:(nullable SZFriendsDeviceChain *)chain hasRevocationOf:(NSData *)subject by:(NSData *)signer {
    for (SZFriendsChainLink *link in chain.links) {
        if (link.kind == SZFriendsChainLinkRevoke && [link.subjectKey isEqualToData:subject] &&
            [link.signerKey isEqualToData:signer]) {
            return YES;
        }
    }
    return NO;
}

- (nullable NSNumber *)coverageInRecord:(SZFriendsSyncEvent *)event {
    SZFriendsSyncFields *fields = event.body ? [SZFriendsSyncFields fieldsWithData:event.body] : nil;
    return [fields hasTag:2] ? @([fields uint64ForTag:2]) : nil;
}

- (NSDictionary<NSData *, NSNumber *> *)revocationCoverageWithEvents:(NSArray<SZFriendsSyncEvent *> *)events
                                                              revoked:(NSSet<NSData *> *)revoked {
    NSMutableDictionary<NSData *, NSNumber *> *coverage = [NSMutableDictionary dictionary];
    if (revoked.count == 0) return coverage;
    for (NSData *device in revoked) {
        SZFriendsSyncRegister *held = [self.store syncRegisterForKey:SZFriendsSyncRevocationKey(device)];
        if (held.value.length == 8) coverage[device] = @(SZFriendsSyncGetU64(held.value.bytes));
    }
    // Records in this very batch count too: a device that hears a revocation and the revoked device's events in one
    // exchange takes what the record allows.
    SZFriendsDeviceChain *chain = nil;
    for (SZFriendsSyncEvent *event in events) {
        if (event.kind != SZFriendsSyncKindRevocation) continue;
        NSData *subject = SZFriendsSyncBytesFromHex(event.subject);
        NSNumber *covered = [self coverageInRecord:event];
        if (subject.length != 32 || covered == nil || ![revoked containsObject:subject]) continue;
        if (chain == nil) chain = self.store.ownDeviceChain;
        if (![self chain:chain hasRevocationOf:subject by:event.author]) continue;
        if (covered.unsignedLongLongValue > [coverage[subject] unsignedLongLongValue]) coverage[subject] = covered;
    }
    return coverage;
}

- (SZFriendsSyncApplyResult)applyRevocation:(SZFriendsSyncEvent *)event {
    NSData *subject = SZFriendsSyncBytesFromHex(event.subject);
    NSNumber *covered = [self coverageInRecord:event];
    if (subject.length != 32 || covered == nil) return SZFriendsSyncApplyDone;
    // The revocation itself reaches us by chain, perhaps after this record.
    if (![self chain:self.store.ownDeviceChain hasRevocationOf:subject by:event.author]) return SZFriendsSyncApplyWait;
    NSString *key = SZFriendsSyncRevocationKey(subject);
    SZFriendsSyncRegister *held = [self.store syncRegisterForKey:key];
    uint64_t accepted = held.value.length == 8 ? SZFriendsSyncGetU64(held.value.bytes) : 0;
    if (held.value.length != 8 || accepted < covered.unsignedLongLongValue) {
        SZFriendsSyncRegister *entry = [[SZFriendsSyncRegister alloc] init];
        entry.lamport = event.lamport;
        entry.author = event.author;
        entry.value = SZFriendsSyncSeqValue(covered.unsignedLongLongValue);
        if (![self.store setSyncRegister:entry forKey:key error:NULL]) return SZFriendsSyncApplyFailed;
        accepted = covered.unsignedLongLongValue;
    }
    // What it wrote past there and reached us before this record did goes, on this device as on every other (while
    // the chain holds it removed: a revocation another one voided removes nothing).
    BOOL removed = NO;
    for (SZFriendsDeviceRecord *device in [self ownDevices]) {
        removed = removed || ([device.deviceKey isEqualToData:subject] && device.state == SZFriendsChainDeviceRevoked);
    }
    if (!removed) return SZFriendsSyncApplyDone;
    return [self dropEventsOfDevice:subject after:accepted] ? SZFriendsSyncApplyDone : SZFriendsSyncApplyFailed;
}

- (BOOL)replaceOwnDevicesSecret:(NSData *)secret {
    NSData *current = [self ownDevicesSecret];
    if (current != nil && ![current isEqualToData:secret]) {
        NSMutableData *previous = [current mutableCopy];
        for (NSData *older in [self previousOwnDevicesSecrets]) {
            if (previous.length >= SZFriendsSyncPreviousSecretsMax * 32) break;
            if (![older isEqualToData:secret]) [previous appendData:older];
        }
        if (![self.store setSyncState:previous forKey:@"own_devices_secrets_previous" error:NULL]) return NO;
    }
    return [self.store setSyncState:secret forKey:SZFriendsSyncStateDevicesSecret error:NULL];
}

@end

@implementation SZFriendsSyncEngine (Devices)

- (BOOL)recordRevocationOfDeviceKey:(NSData *)deviceKey error:(NSError **)error {
    if (deviceKey.length != 32) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"not a device key");
    // The chain holding the revocation becomes an event first, so every device can check the record against it.
    [self captureLocalChanges];
    uint64_t covered = [[self.store syncVector][deviceKey] unsignedLongLongValue];
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setUInt64:covered forTag:2];
    [self resetCounters];
    BOOL ok = [self.store performSyncTransaction:^BOOL(NSError **inner) {
        SZFriendsSyncEvent *event = [self recordKind:SZFriendsSyncKindRevocation scope:@""
                                             subject:SZFriendsSyncHex(deviceKey) body:fields.encodedData error:inner];
        if (event == nil) return NO;
        SZFriendsSyncRegister *entry = [[SZFriendsSyncRegister alloc] init];
        entry.lamport = event.lamport;
        entry.author = event.author;
        entry.value = SZFriendsSyncSeqValue(covered);
        return [self.store setSyncRegister:entry forKey:SZFriendsSyncRevocationKey(deviceKey) error:inner];
    } error:error];
    [self resetCounters];
    if (ok && self.onNewEvents) self.onNewEvents();
    return ok;
}

// The removals so far, as every device names them, and this device's place among the authorized ones (NSNotFound
// when it is not one).
- (NSString *)removalsSeenWithRank:(NSUInteger *)rank {
    NSMutableArray<NSString *> *revoked = [NSMutableArray array];
    NSUInteger place = 0;
    *rank = NSNotFound;
    for (SZFriendsDeviceRecord *device in [self ownDevices]) {
        if (device.state == SZFriendsChainDeviceRevoked) [revoked addObject:SZFriendsSyncHex(device.deviceKey)];
        if (device.state != SZFriendsChainDeviceAuthorized) continue;
        if ([device.deviceKey isEqualToData:self.identity.publicKey]) *rank = place;
        place++;
    }
    [revoked sortUsingSelector:@selector(compare:)];
    return [revoked componentsJoinedByString:@","];
}

// Secrets drawn after exactly these removals reached us by sync (or were drawn here).
- (BOOL)secretsFollowRemovals:(NSString *)seen {
    id renewed = [self.store syncStateForKey:SZFriendsSyncStateRenewed];
    NSData *digest = SZFriendsSyncDigest([seen dataUsingEncoding:NSUTF8StringEncoding]);
    return [renewed isKindOfClass:[NSData class]] && [renewed isEqualToData:digest];
}

- (nullable NSDate *)secretRenewalDueDate {
    NSUInteger rank = NSNotFound;
    NSString *seen = [self removalsSeenWithRank:&rank];
    id handled = [self.store syncStateForKey:@"revocations_renewed"];
    if (seen.length == 0 || rank == NSNotFound || [seen isEqualToString:handled] ||
        [self secretsFollowRemovals:seen]) {
        return nil;
    }
    if (rank == 0) return self.clock();
    id noticed = [self.store syncStateForKey:@"revocations_noticed"];
    NSNumber *since = [self.store syncStateForKey:@"revocations_noticed_at"];
    if (![seen isEqualToString:noticed] || ![since isKindOfClass:[NSNumber class]]) return nil;
    return [NSDate dateWithTimeIntervalSince1970:since.doubleValue + (double)rank * SZFriendsSyncSecretRenewalWait];
}

- (nullable NSData *)renewSecretsAfterRevocation {
    NSUInteger rank = NSNotFound;
    NSString *seen = [self removalsSeenWithRank:&rank];
    id handled = [self.store syncStateForKey:@"revocations_renewed"];
    if ([seen isEqualToString:[handled isKindOfClass:[NSString class]] ? handled : @""]) return nil;
    // Another of our devices drew after these very removals: its secrets are ours by sync, nothing to draw.
    if (seen.length == 0 || rank == NSNotFound || [self secretsFollowRemovals:seen]) {
        [self.store setSyncState:seen forKey:@"revocations_renewed" error:NULL];
        return nil;
    }
    // One device draws, so our devices do not each send friends a secret of their own: the first authorized one at
    // once; the next ones, in order, only when the ones before have not after their wait (the first may be away).
    if (rank > 0) {
        if (![seen isEqualToString:[self.store syncStateForKey:@"revocations_noticed"]]) {
            [self.store setSyncState:seen forKey:@"revocations_noticed" error:NULL];
            [self.store setSyncState:@(self.clock().timeIntervalSince1970) forKey:@"revocations_noticed_at"
                               error:NULL];
        }
        NSDate *due = [self secretRenewalDueDate];
        if (due == nil || [due compare:self.clock()] == NSOrderedDescending) return nil;
    }
    NSMutableData *fresh = [NSMutableData dataWithLength:64];
    randombytes_buf(fresh.mutableBytes, fresh.length);
    NSData *presence = [fresh subdataWithRange:NSMakeRange(0, 32)];
    NSData *devicesSecret = [fresh subdataWithRange:NSMakeRange(32, 32)];
    NSData *digest = SZFriendsSyncDigest([seen dataUsingEncoding:NSUTF8StringEncoding]);
    if (![self replaceOwnDevicesSecret:devicesSecret] ||
        ![self.store setSyncState:digest forKey:SZFriendsSyncStateRenewed error:NULL]) {
        return nil;
    }
    self.store.ownPresenceSecret = presence;
    [self.store setSyncState:presence forKey:SZFriendsSyncStatePresenceDrawn error:NULL];
    [self.store setSyncState:seen forKey:@"revocations_renewed" error:NULL];
    [self noteChangedConversation:nil];
    [self flushChanges];
    return presence;
}

- (BOOL)takePresenceSecretRetell {
    if (![[self.store syncStateForKey:SZFriendsSyncStatePresenceRetell] boolValue]) return NO;
    [self.store setSyncState:nil forKey:SZFriendsSyncStatePresenceRetell error:NULL];
    return YES;
}

- (nullable SZFriendsSyncVector *)vectorHeldByDevice:(NSData *)deviceKey {
    id held = [self.store syncStateForKey:[@"held/" stringByAppendingString:SZFriendsSyncHex(deviceKey)]];
    return [held isKindOfClass:[NSData class]] ? SZFriendsSyncDecodeVector(held, NULL) : nil;
}

- (void)noteDevice:(NSData *)deviceKey holds:(SZFriendsSyncVector *)vector {
    if (deviceKey.length != 32) return;
    [self.store setSyncState:SZFriendsSyncEncodeVector(vector)
                      forKey:[@"held/" stringByAppendingString:SZFriendsSyncHex(deviceKey)]
                       error:NULL];
}

- (BOOL)itemReachedEveryDevice:(NSString *)itemID inConversation:(NSString *)conversationID {
    NSArray<NSArray *> *origins = [self.store syncOriginsOfItem:itemID inConversation:conversationID];
    if (origins.count == 0) return NO; // not even an event yet
    for (NSData *device in self.otherDeviceKeys) {
        SZFriendsSyncVector *held = [self vectorHeldByDevice:device];
        BOOL has = NO;
        for (NSArray *origin in origins) {
            has = has || (held != nil && SZFriendsSyncVectorCovers(held, origin[0], [origin[1] unsignedLongLongValue]));
        }
        if (!has) return NO;
    }
    return YES;
}

- (BOOL)fileReachedEveryDevice:(NSString *)transferID {
    SZFriendsSyncFileRecord *file = [self.store syncFileWithID:transferID];
    if (file == nil) return NO;
    for (NSData *device in self.otherDeviceKeys) {
        if (![file.holders containsObject:device]) return NO;
    }
    return YES;
}

- (NSSet<NSString *> *)itemsOnEveryDeviceInConversation:(NSString *)conversationID {
    NSMutableSet<NSString *> *everywhere = [NSMutableSet set];
    NSArray<NSData *> *others = self.otherDeviceKeys;
    NSMutableArray<SZFriendsSyncVector *> *held = [NSMutableArray array];
    for (NSData *device in others) {
        SZFriendsSyncVector *vector = [self vectorHeldByDevice:device];
        if (vector == nil) return everywhere; // a device that never said what it holds holds nothing we know of
        [held addObject:vector];
    }
    NSDictionary<NSString *, NSArray<NSArray *> *> *origins = [self.store syncOriginsInConversation:conversationID];
    for (NSString *itemID in origins) {
        BOOL all = YES;
        for (SZFriendsSyncVector *vector in held) {
            BOOL has = NO;
            for (NSArray *origin in origins[itemID]) {
                has = has || SZFriendsSyncVectorCovers(vector, origin[0], [origin[1] unsignedLongLongValue]);
            }
            all = all && has;
        }
        if (all) [everywhere addObject:itemID];
    }
    for (SZFriendsSyncFileRecord *file in [self.store syncFiles]) {
        if (![file.conversationID isEqualToString:conversationID] || file.itemID == nil) continue;
        BOOL all = YES;
        for (NSData *device in others) all = all && [file.holders containsObject:device];
        // A file is there once its bytes are, not when its record is.
        if (all) [everywhere addObject:file.itemID];
        else [everywhere removeObject:file.itemID];
    }
    return everywhere;
}

- (NSArray<NSData *> *)previousOwnDevicesSecrets {
    id held = [self.store syncStateForKey:@"own_devices_secrets_previous"];
    NSMutableArray<NSData *> *secrets = [NSMutableArray array];
    if (![held isKindOfClass:[NSData class]]) return secrets;
    NSData *data = held;
    for (NSUInteger at = 0; at + 32 <= data.length; at += 32) {
        [secrets addObject:[data subdataWithRange:NSMakeRange(at, 32)]];
    }
    return secrets;
}

+ (nullable NSData *)ownDevicesSecretInStore:(SZFriendsStore *)store creating:(BOOL)create {
    id held = [store syncStateForKey:SZFriendsSyncStateDevicesSecret];
    if ([held isKindOfClass:[NSData class]] && [(NSData *)held length] == 32) return held;
    if (!create) return nil;
    NSMutableData *secret = [NSMutableData dataWithLength:32];
    randombytes_buf(secret.mutableBytes, secret.length);
    return [store setSyncState:secret forKey:SZFriendsSyncStateDevicesSecret error:NULL] ? secret : nil;
}

+ (BOOL)adoptOwnDevicesSecret:(NSData *)secret inStore:(SZFriendsStore *)store {
    return secret.length == 32 && [store setSyncState:secret forKey:SZFriendsSyncStateDevicesSecret error:NULL];
}

+ (BOOL)adoptJoinCopyWithClock:(uint64_t)clock inStore:(SZFriendsStore *)store {
    SZFriendsSyncRegister *copy = [[SZFriendsSyncRegister alloc] init];
    copy.lamport = 0;
    copy.author = [NSData data];
    copy.value = SZFriendsSyncProfileBody(store, NO);
    return [store setSyncRegister:copy forKey:@"profile" error:NULL] &&
           [store setSyncState:@(MIN(clock, (uint64_t)INT64_MAX)) forKey:SZFriendsSyncStateJoinClock error:NULL];
}

@end

NS_ASSUME_NONNULL_END
