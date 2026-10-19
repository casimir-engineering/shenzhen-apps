// Device chains in the store (SZFriendsStoreDevices.h, schema v8). Every chain is verified by the identity area before
// it is written, and a stored chain is only replaced by a superset of its links, inside one write transaction with
// its device index, so the index never disagrees with the chain beside it.

#import "service/store/SZFriendsStoreDevices.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/store/SZFriendsStoreInternal.h"

@implementation SZFriendsDeviceRecord
@end

static NSString *const SZFDeviceColumns =
    @"root_pk, device_pk, static_pk, name, system, state, added_at, revoked_at, last_seen_at";

static SZFriendsDeviceRecord *SZFDeviceFromRow(sqlite3_stmt *row) {
    SZFriendsDeviceRecord *device = [[SZFriendsDeviceRecord alloc] init];
    device.rootKey = SZFriendsColumnBlob(row, 0);
    device.deviceKey = SZFriendsColumnBlob(row, 1);
    device.staticKey = SZFriendsColumnBlob(row, 2);
    device.name = SZFriendsColumnText(row, 3) ?: @"";
    device.system = SZFriendsColumnText(row, 4) ?: @"";
    device.state = (NSInteger)SZFriendsColumnInt(row, 5);
    device.addedAt = SZFriendsColumnDate(row, 6) ?: [NSDate dateWithTimeIntervalSince1970:0];
    device.revokedAt = SZFriendsColumnDate(row, 7);
    device.lastSeenAt = SZFriendsColumnDate(row, 8);
    device.isRoot = [device.rootKey isEqualToData:device.deviceKey];
    return device;
}

static NSData *SZFStoredChainData(SZFriendsStoreDB *db, NSString *where, NSArray *binds, BOOL *own) {
    __block NSData *data = nil;
    __block BOOL isOwn = NO;
    NSString *sql = [@"SELECT chain, own FROM device_chains " stringByAppendingString:where];
    [db run:sql binds:binds row:^(sqlite3_stmt *row) {
        data = SZFriendsColumnBlob(row, 0);
        isOwn = SZFriendsColumnInt(row, 1) == 1;
    } error:NULL];
    if (own) *own = isOwn;
    return data;
}

// Writes `chain` as the row for its root and rewrites that root's device index, keeping each device's last
// connection. Refused when a device key already belongs to another root's chain: a key speaks for one person only.
static BOOL SZFWriteChain(SZFriendsStoreDB *db, SZFriendsDeviceChain *chain, BOOL own, NSError **error) {
    for (SZFriendsChainDevice *device in chain.devices) {
        id other = [db scalar:@"SELECT root_pk FROM chain_devices WHERE device_pk = ? AND root_pk <> ?"
                        binds:@[ device.deviceKey, chain.rootKey ] error:error];
        if (other != nil) {
            return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorConstraint,
                                                                @"a device key already speaks for someone else"));
        }
    }
    NSString *upsertChain = @"INSERT INTO device_chains(root_pk, genesis_hash, chain, own, updated_at) "
                            @"VALUES (?, ?, ?, ?, ?) ON CONFLICT(root_pk) DO UPDATE SET chain = excluded.chain, "
                            @"own = excluded.own, updated_at = excluded.updated_at";
    NSArray *binds = @[ chain.rootKey, chain.genesisHash, chain.encodedData, @(own ? 1 : 0), [NSDate date] ];
    if (![db run:upsertChain binds:binds row:nil error:error]) {
        return NO;
    }
    NSString *upsertDevice =
        @"INSERT INTO chain_devices(device_pk, root_pk, static_pk, name, system, state, added_at, revoked_at) "
        @"VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(device_pk) DO UPDATE SET static_pk = excluded.static_pk, "
        @"name = excluded.name, system = excluded.system, state = excluded.state, added_at = excluded.added_at, "
        @"revoked_at = excluded.revoked_at";
    for (SZFriendsChainDevice *device in chain.devices) {
        NSArray *binds = @[ device.deviceKey, chain.rootKey, device.staticKey, device.name, device.system,
                            @(device.state), device.addedAt, SZFriendsSQL(device.revokedAt) ];
        if (![db run:upsertDevice binds:binds row:nil error:error]) return NO;
    }
    return YES;
}

@implementation SZFriendsStore (Devices)

#pragma mark Own chain

- (nullable SZFriendsDeviceChain *)ownDeviceChain {
    __block NSData *data = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) data = SZFStoredChainData(db, @"WHERE own = 1", @[], NULL);
    }];
    return data ? [SZFriendsDeviceChain chainWithData:data expectedRootKey:nil error:NULL] : nil;
}

- (nullable SZFriendsDeviceChain *)ownDeviceChainCreatingGenesisWithIdentity:(SZFriendsIdentity *)identity
                                                                       error:(NSError **)error {
    __block SZFriendsDeviceChain *chain = nil;
    BOOL ok = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSData *stored = SZFStoredChainData(db, @"WHERE own = 1", @[], NULL);
        if (stored != nil) {
            chain = [SZFriendsDeviceChain chainWithData:stored expectedRootKey:nil error:inner];
            return chain != nil;
        }
        chain = [SZFriendsDeviceChain genesisChainWithIdentity:identity
                                                          name:SZFriendsLocalDeviceName()
                                                        system:SZFriendsLocalDeviceSystem()
                                                          date:[NSDate date]
                                                         error:inner];
        return chain != nil && SZFWriteChain(db, chain, YES, inner);
    } error:error];
    return ok ? chain : nil;
}

- (BOOL)adoptOwnDeviceChain:(SZFriendsDeviceChain *)chain
             localDeviceKey:(NSData *)localDeviceKey
                      error:(NSError **)error {
    if (![chain authorizesDeviceKey:localDeviceKey]) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid,
                                                            @"a profile's chain that does not include this device"));
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (![db run:@"DELETE FROM device_chains WHERE own = 1 OR root_pk = ?" binds:@[ chain.rootKey ] row:nil
               error:inner]) {
            return NO;
        }
        return SZFWriteChain(db, chain, YES, inner);
    } error:error];
}

// Merges `chain` into the stored row selected by `where`, which must hold the same genesis.
- (SZFriendsChainMergeResult)mergeChain:(SZFriendsDeviceChain *)chain
                                  where:(NSString *)where
                                  binds:(NSArray *)binds
                                    own:(BOOL)own
                                  error:(NSError **)error {
    __block SZFriendsChainMergeResult result = SZFriendsChainMergeRefused;
    [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        BOOL storedOwn = NO;
        NSData *data = SZFStoredChainData(db, where, binds, &storedOwn);
        SZFriendsDeviceChain *stored = data ? [SZFriendsDeviceChain chainWithData:data expectedRootKey:chain.rootKey
                                                                            error:inner]
                                            : nil;
        if (data != nil && stored == nil) return NO;
        if (stored != nil && storedOwn != own) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid,
                                                                @"our own chain never arrives as a friend's"));
        }
        if (stored != nil && [stored containsChain:chain]) {
            result = SZFriendsChainMergeUnchanged;
            return YES;
        }
        SZFriendsDeviceChain *merged = stored ? [stored chainByMergingChain:chain error:inner] : chain;
        if (merged == nil || !SZFWriteChain(db, merged, own, inner)) return NO;
        result = SZFriendsChainMergeChanged;
        return YES;
    } error:error];
    return result;
}

- (SZFriendsChainMergeResult)mergeOwnDeviceChain:(SZFriendsDeviceChain *)chain error:(NSError **)error {
    __block NSData *ownRoot = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        ownRoot = [db scalar:@"SELECT root_pk FROM device_chains WHERE own = 1" binds:nil error:NULL];
    }];
    if (![ownRoot isEqual:chain.rootKey]) {
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"not this person's chain"));
        return SZFriendsChainMergeRefused;
    }
    return [self mergeChain:chain where:@"WHERE own = 1" binds:@[] own:YES error:error];
}

#pragma mark Friends' chains

- (SZFriendsChainMergeResult)mergeDeviceChainData:(NSData *)data
                                       forRootKey:(NSData *)rootKey
                                            error:(NSError **)error {
    __block BOOL known = NO, same = NO;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        known = [[db scalar:@"SELECT count(*) FROM friends WHERE identity_pk = ?" binds:@[ rootKey ] error:NULL]
                    integerValue] > 0;
        // The common case, a chain we already hold byte for byte, costs one comparison and no signature checks.
        same = [SZFStoredChainData(db, @"WHERE root_pk = ? AND own = 0", @[ rootKey ], NULL) isEqualToData:data];
    }];
    if (!known) {
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"nobody in the list has that root"));
        return SZFriendsChainMergeRefused;
    }
    if (same) return SZFriendsChainMergeUnchanged;
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:data expectedRootKey:rootKey error:error];
    if (chain == nil) return SZFriendsChainMergeRefused;
    return [self mergeChain:chain where:@"WHERE root_pk = ?" binds:@[ rootKey ] own:NO error:error];
}

- (BOOL)rekeyConversation:(NSString *)conversationID
            fromDeviceKey:(NSData *)deviceKey
                  toChain:(SZFriendsDeviceChain *)chain
                    error:(NSError **)error {
    NSData *root = chain.rootKey;
    SZFriendsChainDevice *first = [chain deviceWithKey:root];
    if (![chain authorizesDeviceKey:deviceKey] || [deviceKey isEqualToData:root] || first.staticKey.length != 32) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid,
                                                            @"a chain that does not name this device"));
    }
    BOOL moved = [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSNumber *mine = [db scalar:@"SELECT count(*) FROM friends WHERE conversation_id = ? AND identity_pk = ?"
                              binds:@[ conversationID, deviceKey ] error:inner];
        NSNumber *taken = [db scalar:@"SELECT count(*) FROM friends WHERE identity_pk = ?" binds:@[ root ]
                               error:inner];
        if (mine.integerValue != 1 || taken.integerValue != 0) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorConstraint,
                                                                @"not this device's row, or the root is taken"));
        }
        return [db run:@"UPDATE friends SET identity_pk = ?, static_pk = ? WHERE conversation_id = ?"
                 binds:@[ root, first.staticKey, conversationID ]
                   row:nil
                 error:inner];
    } error:error];
    if (!moved) return NO;
    return [self mergeChain:chain where:@"WHERE root_pk = ?" binds:@[ root ] own:NO error:error] !=
           SZFriendsChainMergeRefused;
}

- (nullable SZFriendsDeviceChain *)deviceChainForRootKey:(NSData *)rootKey {
    __block NSData *data = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) data = SZFStoredChainData(db, @"WHERE root_pk = ?", @[ rootKey ], NULL);
    }];
    return data ? [SZFriendsDeviceChain chainWithData:data expectedRootKey:rootKey error:NULL] : nil;
}

#pragma mark Devices

- (nullable id)deviceScalar:(NSString *)sql binds:(NSArray *)binds {
    __block id value = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        value = [db scalar:sql binds:binds error:NULL];
    }];
    return value;
}

- (nullable NSData *)rootKeyForDeviceKey:(NSData *)deviceKey {
    return [self deviceScalar:@"SELECT root_pk FROM chain_devices WHERE device_pk = ? AND state = 1"
                        binds:@[ deviceKey ]];
}

- (BOOL)isRevokedDeviceKey:(NSData *)deviceKey {
    return [[self deviceScalar:@"SELECT count(*) FROM chain_devices WHERE device_pk = ? AND state = 2"
                         binds:@[ deviceKey ]] integerValue] > 0;
}

- (nullable NSData *)staticKeyForDeviceKey:(NSData *)deviceKey ofRootKey:(NSData *)rootKey {
    return [self deviceScalar:@"SELECT static_pk FROM chain_devices WHERE device_pk = ? AND root_pk = ? AND state = 1"
                        binds:@[ deviceKey, rootKey ]];
}

- (NSArray<SZFriendsDeviceRecord *> *)devicesOfRootKey:(NSData *)rootKey {
    NSMutableArray<SZFriendsDeviceRecord *> *devices = [NSMutableArray array];
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM chain_devices WHERE root_pk = ? ORDER BY "
                                               @"state <> 1, device_pk <> root_pk, added_at, device_pk",
                                               SZFDeviceColumns];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        [db run:sql binds:@[ rootKey ] row:^(sqlite3_stmt *row) { [devices addObject:SZFDeviceFromRow(row)]; }
            error:NULL];
    }];
    return devices;
}

- (BOOL)noteDeviceKey:(NSData *)deviceKey seenAtDate:(NSDate *)date error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"UPDATE chain_devices SET last_seen_at = ? WHERE device_pk = ?" binds:@[ date, deviceKey ]
                   row:nil error:inner];
    } error:error];
}

@end
