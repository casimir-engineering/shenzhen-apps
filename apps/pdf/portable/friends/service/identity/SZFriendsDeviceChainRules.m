// Which links of a device chain count, and so which devices speak for the person (ADR 0012 § Rules).
//
// The outcome is a pure function of the set of links, never of the order they arrived in, so every device and every
// friend holding the same links computes the same devices: merging is a set union and the chain converges. Runs on
// links whose structure the chain already checked: signatures, consents, parents present, every signer added before
// the link it signs, no revoked device added again.
//
//   1. A revocation r of device X is void when a concurrent revocation r' (one that did not see r) removed r's signer,
//      unless r' was signed by X, or by a device X added (directly or through others) by adds r did not see. So two
//      devices revoking each other both end revoked (revocation wins), a revoked device cannot undo its own revocation
//      by itself or through a device it added behind its back, and a device that was revoked cannot take a third
//      device with it by revoking it on a branch that never saw its own revocation.
//   2. Starting from every revocation not void by 1: a genesis always counts; an add or rename counts when its signer
//      had an add that counts among the links it saw (or is the first device), and no counted revocation of its signer
//      missed it. A revocation is dropped when its signer had no add that counts among the links it saw, or had been
//      revoked there. The revocations only ever shrink, so the loop stops; a dropped one never comes back, which
//      keeps the outcome one function of the links even where taking a revocation back would let it stand again.
//   3. Revoked: the subjects of the revocations left. Authorized: subjects of adds that count, unless revoked.

#import "service/identity/SZFriendsDeviceChainInternal.h"

@implementation SZFriendsChainDevice

- (instancetype)initWithDeviceKey:(NSData *)deviceKey
                        staticKey:(NSData *)staticKey
                             name:(NSString *)name
                           system:(NSString *)system
                          addedAt:(NSDate *)addedAt
                        revokedAt:(nullable NSDate *)revokedAt
                            state:(SZFriendsChainDeviceState)state
                           isRoot:(BOOL)isRoot {
    if ((self = [super init])) {
        _deviceKey = [deviceKey copy];
        _staticKey = [staticKey copy];
        _name = [name copy];
        _system = [system copy];
        _addedAt = addedAt;
        _revokedAt = revokedAt;
        _state = state;
        _isRoot = isRoot;
    }
    return self;
}

@end

@implementation SZFriendsChainOutcome
@end

// Whether `device`'s authority came from `origin` through adds that `revocation` did not see: `device` is `origin`, or
// was added by it, or by a device added by it, and so on, along adds outside the revocation's past. Adds it saw are
// left out on purpose: they were there when the revocation was made, so they are not the revoked device acting.
static BOOL SZFDerivesUnseen(NSData *device, NSData *origin, NSUInteger revocation,
                             NSArray<SZFriendsChainLink *> *links, NSArray<NSIndexSet *> *ancestors) {
    NSMutableSet<NSData *> *reached = [NSMutableSet setWithObject:device];
    NSMutableArray<NSData *> *frontier = [NSMutableArray arrayWithObject:device];
    while (frontier.count > 0) {
        NSData *current = frontier.lastObject;
        [frontier removeLastObject];
        if ([current isEqualToData:origin]) return YES;
        for (NSUInteger a = 0; a < links.count; a++) {
            SZFriendsChainLink *add = links[a];
            if (add.kind != SZFriendsChainLinkAdd || ![add.subjectKey isEqualToData:current]) continue;
            if (a == revocation || [ancestors[revocation] containsIndex:a]) continue;
            if (![reached containsObject:add.signerKey]) {
                [reached addObject:add.signerKey];
                [frontier addObject:add.signerKey];
            }
        }
    }
    return NO;
}

static NSMutableIndexSet *SZFStaticallyCountedRevocations(NSArray<SZFriendsChainLink *> *links,
                                                         NSArray<NSIndexSet *> *ancestors) {
    NSMutableIndexSet *counted = [NSMutableIndexSet indexSet];
    for (NSUInteger r = 0; r < links.count; r++) {
        SZFriendsChainLink *revocation = links[r];
        if (revocation.kind != SZFriendsChainLinkRevoke) continue;
        BOOL voided = NO;
        for (NSUInteger o = 0; o < links.count && !voided; o++) {
            SZFriendsChainLink *other = links[o];
            if (o == r || other.kind != SZFriendsChainLinkRevoke) continue;
            if (![other.subjectKey isEqualToData:revocation.signerKey] || [ancestors[o] containsIndex:r]) continue;
            voided = !SZFDerivesUnseen(other.signerKey, revocation.subjectKey, r, links, ancestors);
        }
        if (!voided) [counted addIndex:r];
    }
    return counted;
}

// Whether `signer` had an add that counts among the links in `seen` (the first device always has its genesis).
static BOOL SZFHadCountedAdd(NSData *signer, NSIndexSet *seen, NSArray<SZFriendsChainLink *> *links,
                             NSIndexSet *effective) {
    __block BOOL found = NO;
    [seen enumerateIndexesUsingBlock:^(NSUInteger a, BOOL *stop) {
        SZFriendsChainLink *add = links[a];
        if ([effective containsIndex:a] && add.kind != SZFriendsChainLinkRevoke &&
            add.kind != SZFriendsChainLinkRename && [add.subjectKey isEqualToData:signer]) {
            found = YES;
            *stop = YES;
        }
    }];
    return found;
}

static NSIndexSet *SZFEffectiveLinks(NSArray<SZFriendsChainLink *> *links, NSArray<NSIndexSet *> *ancestors,
                                     NSIndexSet *revocations) {
    NSMutableIndexSet *effective = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < links.count; i++) {
        SZFriendsChainLink *link = links[i];
        if (link.kind == SZFriendsChainLinkGenesis) {
            [effective addIndex:i];
            continue;
        }
        if (link.kind == SZFriendsChainLinkRevoke) continue;
        if (!SZFHadCountedAdd(link.signerKey, ancestors[i], links, effective)) continue;
        __block BOOL missed = NO;
        [revocations enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
            if ([links[r].subjectKey isEqualToData:link.signerKey] && ![ancestors[r] containsIndex:i]) {
                missed = YES;
                *stop = YES;
            }
        }];
        if (!missed) [effective addIndex:i];
    }
    return effective;
}

static BOOL SZFRevocationStands(NSUInteger r, NSArray<SZFriendsChainLink *> *links, NSArray<NSIndexSet *> *ancestors,
                                NSIndexSet *revocations, NSIndexSet *effective) {
    SZFriendsChainLink *revocation = links[r];
    if (!SZFHadCountedAdd(revocation.signerKey, ancestors[r], links, effective)) return NO;
    __block BOOL revokedBefore = NO;
    [ancestors[r] enumerateIndexesUsingBlock:^(NSUInteger earlier, BOOL *stop) {
        if ([revocations containsIndex:earlier] && [links[earlier].subjectKey isEqualToData:revocation.signerKey]) {
            revokedBefore = YES;
            *stop = YES;
        }
    }];
    return !revokedBefore;
}

// Later of two labels (links `a` and `b` by index): one that saw the other is later, whatever the clocks say (a rename
// made in the same millisecond as the add it renames, or on a computer whose clock is behind, still shows); only
// concurrent renames fall to the signer's clock, then the link hash, so they settle the same everywhere.
static BOOL SZFIsLater(NSArray<SZFriendsChainLink *> *links, NSArray<NSIndexSet *> *ancestors, NSUInteger a,
                       NSUInteger b) {
    if ([ancestors[a] containsIndex:b]) return YES;
    if ([ancestors[b] containsIndex:a]) return NO;
    if (links[a].milliseconds != links[b].milliseconds) return links[a].milliseconds > links[b].milliseconds;
    return memcmp(links[a].linkHash.bytes, links[b].linkHash.bytes, 32) > 0;
}

static NSArray<SZFriendsChainDevice *> *SZFDevices(NSArray<SZFriendsChainLink *> *links,
                                                   NSArray<NSIndexSet *> *ancestors, NSIndexSet *effective,
                                                   NSIndexSet *revocations, NSData *rootKey) {
    NSMutableArray<NSData *> *order = [NSMutableArray array];
    NSMutableDictionary<NSData *, SZFriendsChainLink *> *firstAdd = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSData *, SZFriendsChainLink *> *countedAdd = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSData *, NSNumber *> *label = [NSMutableDictionary dictionary]; // the link's index
    NSMutableDictionary<NSData *, NSDate *> *revokedAt = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < links.count; i++) {
        SZFriendsChainLink *link = links[i];
        NSData *subject = link.subjectKey;
        BOOL counts = [effective containsIndex:i];
        if (link.kind == SZFriendsChainLinkRevoke) {
            if (![revocations containsIndex:i]) continue;
            NSDate *previous = revokedAt[subject];
            revokedAt[subject] = previous ? [previous earlierDate:link.date] : link.date;
            continue;
        }
        if (link.kind != SZFriendsChainLinkRename && firstAdd[subject] == nil) {
            firstAdd[subject] = link;
            [order addObject:subject];
        }
        if (counts && link.kind != SZFriendsChainLinkRename && countedAdd[subject] == nil) countedAdd[subject] = link;
        if (counts && (label[subject] == nil || SZFIsLater(links, ancestors, i, label[subject].unsignedIntegerValue))) {
            label[subject] = @(i);
        }
    }
    NSMutableArray<SZFriendsChainDevice *> *devices = [NSMutableArray array];
    for (NSData *key in order) {
        SZFriendsChainLink *added = countedAdd[key] ?: firstAdd[key];
        SZFriendsChainLink *named = label[key] ? links[label[key].unsignedIntegerValue] : added;
        SZFriendsChainDeviceState state = revokedAt[key]   ? SZFriendsChainDeviceRevoked
                                          : countedAdd[key] ? SZFriendsChainDeviceAuthorized
                                                            : SZFriendsChainDeviceVoid;
        [devices addObject:[[SZFriendsChainDevice alloc] initWithDeviceKey:key
                                                                 staticKey:firstAdd[key].subjectStaticKey
                                                                      name:named.name
                                                                    system:named.system
                                                                   addedAt:added.date
                                                                 revokedAt:revokedAt[key]
                                                                     state:state
                                                                    isRoot:[key isEqualToData:rootKey]]];
    }
    return devices;
}

SZFriendsChainOutcome *SZFriendsChainApplyRules(NSArray<SZFriendsChainLink *> *links,
                                                NSArray<NSIndexSet *> *ancestors, NSData *rootKey) {
    NSMutableIndexSet *revocations = SZFStaticallyCountedRevocations(links, ancestors);
    NSIndexSet *effective = nil;
    for (;;) {
        effective = SZFEffectiveLinks(links, ancestors, revocations);
        NSMutableIndexSet *dropped = [NSMutableIndexSet indexSet];
        [revocations enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
            (void)stop;
            if (!SZFRevocationStands(r, links, ancestors, revocations, effective)) [dropped addIndex:r];
        }];
        if (dropped.count == 0) break;
        [revocations removeIndexes:dropped];
    }
    NSMutableIndexSet *counted = [effective mutableCopy];
    [counted addIndexes:revocations];
    SZFriendsChainOutcome *outcome = [[SZFriendsChainOutcome alloc] init];
    outcome.effectiveLinks = counted;
    outcome.devices = SZFDevices(links, ancestors, effective, revocations, rootKey);
    return outcome;
}
