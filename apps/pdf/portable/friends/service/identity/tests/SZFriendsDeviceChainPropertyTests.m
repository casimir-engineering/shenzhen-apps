// friends-identity-check: merge properties of the device chain over random histories (ADR 0012 § Verification).
//
// Each trial runs three partitioned replicas of one person's chain from a shared genesis. Every step a replica adds,
// revokes or renames a device, signed by a device its own view authorizes, or two replicas sync. At the end the
// replicas merge in every order and the results must agree byte for byte, contain every replica, keep every
// revocation by a device whose authority nobody touched, never authorize a device only through an add its revoked
// signer made unseen, and decode back from any parents-first order of their links. Seeds are fixed, so a
// failure names the seed that reproduces it.

#import "SZFriendsIdentityTestSupport.h"

#import "service/identity/SZFriendsDeviceChainInternal.h"
#import "service/identity/SZFriendsIdentityInternal.h"

#include <sodium.h>

enum { kTrials = 120, kSteps = 24, kReplicas = 3, kDevices = 7 };

static uint64_t gState;
static uint32_t Next(uint32_t bound) {
    gState = gState * 6364136223846793005ull + 1442695040888963407ull;
    return (uint32_t)((gState >> 33) % bound);
}

static NSArray<SZFriendsIdentity *> *Pool(void) {
    NSMutableArray *pool = [NSMutableArray array];
    for (uint8_t i = 0; i < kDevices; i++) {
        uint8_t seed[32], key[32];
        memset(seed, (uint8_t)(0x10 + i), 32);
        memset(key, (uint8_t)(0x60 + i), 32);
        [pool addObject:[SZFriendsIdentity identityWithSigningSeed:[NSData dataWithBytes:seed length:32]
                                                  staticPrivateKey:[NSData dataWithBytes:key length:32]]];
    }
    return pool;
}

static SZFriendsDeviceChain *Step(SZFriendsDeviceChain *chain, NSArray<SZFriendsIdentity *> *pool, double when) {
    NSArray<SZFriendsChainDevice *> *authorized = chain.authorizedDevices;
    if (authorized.count == 0) return chain;
    NSData *signerKey = authorized[Next((uint32_t)authorized.count)].deviceKey;
    SZFriendsIdentity *signer = nil;
    for (SZFriendsIdentity *identity in pool) {
        if ([identity.publicKey isEqualToData:signerKey]) signer = identity;
    }
    SZFriendsIdentity *target = pool[Next(kDevices)];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1791800000 + when];
    SZFriendsDeviceChain *next = nil;
    switch (Next(4)) {
    case 0:
    case 1:
        next = [chain chainByAddingDeviceKey:target.publicKey staticKey:target.staticPublicKey
                                     consent:SZFriendsDeviceConsent(target, chain.rootKey) name:@"Mac" system:@"macOS"
                                    signedBy:signer date:date error:NULL];
        break;
    case 2:
        next = [chain chainByRevokingDeviceKey:target.publicKey signedBy:signer date:date error:NULL];
        break;
    default:
        next = [chain chainByRenamingTo:[NSString stringWithFormat:@"Mac %u", Next(1000)] system:@"macOS 26.1"
                               signedBy:signer date:date error:NULL];
        break;
    }
    return next ?: chain; // refused steps (re-adding a revoked device, adding an authorized one) change nothing
}

static NSArray<NSIndexSet *> *Ancestors(NSArray<SZFriendsChainLink *> *links) {
    NSMutableDictionary<NSData *, NSNumber *> *index = [NSMutableDictionary dictionary];
    NSMutableArray<NSIndexSet *> *ancestors = [NSMutableArray array];
    for (NSUInteger i = 0; i < links.count; i++) {
        NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
        for (NSData *parent in links[i].parentHashes) {
            NSUInteger p = index[parent].unsignedIntegerValue;
            [seen addIndex:p];
            [seen addIndexes:ancestors[p]];
        }
        [ancestors addObject:seen];
        index[links[i].linkHash] = @(i);
    }
    return ancestors;
}

// A device whose authority nobody touched: never revoked, and every add of it signed by such a device (or the root).
static BOOL Clean(NSData *device, NSArray<SZFriendsChainLink *> *links, NSData *root, NSMutableDictionary *memo) {
    if (memo[device]) return [memo[device] boolValue];
    memo[device] = @NO; // signers come before what they sign, so a cycle cannot form; this only guards the walk
    BOOL clean = YES, added = [device isEqualToData:root];
    for (SZFriendsChainLink *link in links) {
        if (![link.subjectKey isEqualToData:device]) continue;
        if (link.kind == SZFriendsChainLinkRevoke) clean = NO;
        if (link.kind == SZFriendsChainLinkAdd) {
            added = YES;
            clean = clean && Clean(link.signerKey, links, root, memo);
        }
    }
    memo[device] = @(clean && added);
    return clean && added;
}

static void CheckMerged(SZFriendsDeviceChain *merged, NSArray<SZFriendsDeviceChain *> *replicas, uint64_t seed) {
    NSArray<SZFriendsChainLink *> *links = merged.links;
    NSArray<NSIndexSet *> *ancestors = Ancestors(links);
    NSMutableDictionary *memo = [NSMutableDictionary dictionary];
    for (SZFriendsDeviceChain *replica in replicas) {
        SZFExpect([merged containsChain:replica], @"seed %llu: the merge holds every replica", seed);
        for (SZFriendsChainLink *link in replica.links) {
            if (link.kind != SZFriendsChainLinkRevoke || !Clean(link.signerKey, links, merged.rootKey, memo)) continue;
            SZFExpect([merged revokesDeviceKey:link.subjectKey], @"seed %llu: a revocation by a device whose authority "
                                                                 @"nobody touched wins every merge", seed);
        }
    }
    for (SZFriendsChainDevice *device in merged.authorizedDevices) {
        if (device.isRoot) continue;
        BOOL addedInTime = NO;
        for (NSUInteger i = 0; i < links.count; i++) {
            SZFriendsChainLink *add = links[i];
            if (add.kind != SZFriendsChainLinkAdd || ![add.subjectKey isEqualToData:device.deviceKey]) continue;
            if (![merged revokesDeviceKey:add.signerKey]) addedInTime = YES;
            for (NSUInteger r = 0; r < links.count; r++) {
                SZFriendsChainLink *revocation = links[r];
                if (revocation.kind == SZFriendsChainLinkRevoke &&
                    [revocation.subjectKey isEqualToData:add.signerKey] && [ancestors[r] containsIndex:i]) {
                    addedInTime = YES; // a revocation of its signer saw it: made before, it stands
                }
            }
        }
        SZFExpect(addedInTime, @"seed %llu: no device rests on an add its revoked signer made unseen", seed);
    }
    // Any parents-first order of the same links decodes to the same chain.
    NSMutableArray<SZFriendsChainLink *> *shuffled = [NSMutableArray arrayWithObject:links.firstObject];
    NSRange tail = NSMakeRange(1, links.count - 1);
    NSMutableArray<SZFriendsChainLink *> *rest = [[links subarrayWithRange:tail] mutableCopy];
    NSMutableSet<NSData *> *placed = [NSMutableSet setWithObject:links.firstObject.linkHash];
    while (rest.count > 0) {
        NSIndexSet *ready = [rest indexesOfObjectsPassingTest:^BOOL(SZFriendsChainLink *link, NSUInteger i, BOOL *s) {
            (void)i, (void)s;
            return [[NSSet setWithArray:link.parentHashes] isSubsetOfSet:placed];
        }];
        __block NSUInteger pick = ready.firstIndex, skip = Next((uint32_t)ready.count);
        [ready enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            if (skip-- == 0) {
                pick = i;
                *stop = YES;
            }
        }];
        [placed addObject:rest[pick].linkHash];
        [shuffled addObject:rest[pick]];
        [rest removeObjectAtIndex:pick];
    }
    NSMutableData *data = [NSMutableData dataWithBytes:(uint8_t[]){1, 0, (uint8_t)shuffled.count} length:3];
    for (SZFriendsChainLink *link in shuffled) {
        uint8_t length[2] = {(uint8_t)(link.encodedData.length >> 8), (uint8_t)link.encodedData.length};
        [data appendBytes:length length:2];
        [data appendData:link.encodedData];
    }
    SZFriendsDeviceChain *decoded = [SZFriendsDeviceChain chainWithData:data expectedRootKey:merged.rootKey error:NULL];
    SZFExpect([decoded.encodedData isEqualToData:merged.encodedData], @"seed %llu: order-free decoding", seed);
    // A forged byte anywhere in a link is refused.
    NSMutableData *forged = [merged.encodedData mutableCopy];
    NSUInteger at = 3 + Next((uint32_t)(forged.length - 3));
    ((uint8_t *)forged.mutableBytes)[at] ^= (uint8_t)(1 + Next(255));
    SZFExpect([SZFriendsDeviceChain chainWithData:forged expectedRootKey:merged.rootKey error:NULL] == nil,
              @"seed %llu: a byte changed at %lu is refused", seed, (unsigned long)at);
}

static void RunTrial(uint64_t seed, NSArray<SZFriendsIdentity *> *pool, NSUInteger *revocationsSeen) {
    gState = seed;
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1791800000];
    SZFriendsDeviceChain *genesis = [SZFriendsDeviceChain genesisChainWithIdentity:pool[0] name:@"First"
                                                                            system:@"macOS 26.0" date:start error:NULL];
    NSMutableArray<SZFriendsDeviceChain *> *replicas = [NSMutableArray array];
    for (int i = 0; i < kReplicas; i++) [replicas addObject:genesis];
    for (int step = 0; step < kSteps; step++) {
        uint32_t r = Next(kReplicas);
        if (Next(5) == 0) {
            uint32_t other = Next(kReplicas);
            SZFriendsDeviceChain *merged = [replicas[r] chainByMergingChain:replicas[other] error:NULL];
            SZFExpect(merged != nil, @"seed %llu: replicas always merge", seed);
            if (merged) replicas[r] = replicas[other] = merged;
        } else {
            replicas[r] = Step(replicas[r], pool, step + 1);
        }
    }
    NSArray<NSArray<NSNumber *> *> *orders = @[ @[ @0, @1, @2 ], @[ @2, @1, @0 ], @[ @1, @0, @2 ], @[ @2, @0, @1 ] ];
    NSData *expected = nil;
    SZFriendsDeviceChain *first = nil;
    for (NSArray<NSNumber *> *order in orders) {
        SZFriendsDeviceChain *merged = replicas[order[0].unsignedIntValue];
        for (NSUInteger i = 1; i < order.count; i++) {
            merged = [merged chainByMergingChain:replicas[order[i].unsignedIntValue] error:NULL];
        }
        expected = expected ?: merged.encodedData;
        first = first ?: merged;
        SZFExpect([merged.encodedData isEqualToData:expected], @"seed %llu: merges commute and associate", seed);
        NSArray *states = [merged.devices valueForKey:@"state"], *firstStates = [first.devices valueForKey:@"state"];
        SZFExpect([states isEqualToArray:firstStates], @"seed %llu: every order gives the same devices", seed);
    }
    // Merging in a tree shape, and merging what is already held, changes nothing.
    SZFriendsDeviceChain *tree = [[replicas[1] chainByMergingChain:replicas[2] error:NULL]
        chainByMergingChain:replicas[0] error:NULL];
    SZFExpect([tree.encodedData isEqualToData:expected], @"seed %llu: tree-shaped merge", seed);
    SZFExpect([[first chainByMergingChain:first error:NULL].encodedData isEqualToData:expected] &&
                  [[first chainByMergingChain:replicas[0] error:NULL].encodedData isEqualToData:expected],
              @"seed %llu: idempotent", seed);
    CheckMerged(first, replicas, seed);
    for (SZFriendsChainLink *link in first.links) *revocationsSeen += link.kind == SZFriendsChainLinkRevoke;
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) return 1;
        NSArray<SZFriendsIdentity *> *pool = Pool();
        NSUInteger revocations = 0;
        for (uint64_t seed = 1; seed <= kTrials; seed++) RunTrial(seed, pool, &revocations);
        // The generator must exercise what it claims to: concurrent revocations happen in these histories.
        SZFExpect(revocations > kTrials, @"too few revocations generated (%lu)", (unsigned long)revocations);
        return SZFFinish("SZFriendsDeviceChainPropertyTests");
    }
}
