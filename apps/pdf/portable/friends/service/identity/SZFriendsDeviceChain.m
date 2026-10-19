// The device chain as a value: decoding with every check, the canonical order, merging and the builders
// (SZFriendsDeviceChain.h; which links count is SZFriendsDeviceChainRules.m).
//
// Encoding: version u8 (1) | link count u16be | for each link, its length u16be and its bytes
// (SZFriendsDeviceChainLink.m), parents before children. The canonical order breaks ties by link hash, so equal
// chains are equal bytes.

#import "service/identity/SZFriendsDeviceChainInternal.h"
#import "service/identity/SZFriendsIdentity.h"

static const uint8_t SZFChainVersion = 1;

static BOOL SZFFail(NSError **error, SZFriendsDeviceChainError code, NSString *description) {
    if (error) *error = SZFriendsChainError(code, description);
    return NO;
}

static NSComparisonResult SZFCompareHashes(NSData *a, NSData *b) {
    int order = memcmp(a.bytes, b.bytes, 32);
    return order < 0 ? NSOrderedAscending : (order > 0 ? NSOrderedDescending : NSOrderedSame);
}

// Kahn's order, smallest hash first among the links whose parents are placed. Nil when a parent is missing.
static NSArray<SZFriendsChainLink *> *SZFCanonicalOrder(NSArray<SZFriendsChainLink *> *links) {
    NSMutableDictionary<NSData *, SZFriendsChainLink *> *byHash = [NSMutableDictionary dictionary];
    for (SZFriendsChainLink *link in links) byHash[link.linkHash] = link;
    for (SZFriendsChainLink *link in links) {
        for (NSData *parent in link.parentHashes) {
            if (byHash[parent] == nil) return nil;
        }
    }
    NSMutableSet<NSData *> *placed = [NSMutableSet set];
    NSMutableArray<SZFriendsChainLink *> *waiting = [[byHash.allValues sortedArrayUsingComparator:^(id a, id b) {
        return SZFCompareHashes([a linkHash], [b linkHash]);
    }] mutableCopy];
    NSMutableArray<SZFriendsChainLink *> *ordered = [NSMutableArray arrayWithCapacity:waiting.count];
    while (waiting.count > 0) {
        NSUInteger next = [waiting indexOfObjectPassingTest:^BOOL(SZFriendsChainLink *link, NSUInteger i, BOOL *stop) {
            (void)i, (void)stop;
            for (NSData *parent in link.parentHashes) {
                if (![placed containsObject:parent]) return NO;
            }
            return YES;
        }];
        if (next == NSNotFound) return nil; // a cycle, which only a hash collision could make
        [placed addObject:waiting[next].linkHash];
        [ordered addObject:waiting[next]];
        [waiting removeObjectAtIndex:next];
    }
    return ordered;
}

static BOOL SZFAddsSubject(SZFriendsChainLink *link, NSData *key) {
    return (link.kind == SZFriendsChainLinkGenesis || link.kind == SZFriendsChainLinkAdd) &&
           [link.subjectKey isEqualToData:key];
}

@interface SZFriendsDeviceChain ()
@property(nonatomic, readwrite) NSData *rootKey;
@property(nonatomic, readwrite) NSData *genesisHash;
@property(nonatomic, readwrite) NSArray<SZFriendsChainLink *> *links;
@property(nonatomic, readwrite) NSArray<NSData *> *headHashes;
@property(nonatomic, readwrite) NSData *encodedData;
@property(nonatomic, readwrite) NSArray<SZFriendsChainDevice *> *devices;
@property(nonatomic, readwrite) NSArray<SZFriendsChainDevice *> *authorizedDevices;
@property(nonatomic) NSDictionary<NSData *, SZFriendsChainDevice *> *devicesByKey;
@property(nonatomic) NSSet<NSData *> *linkHashes;
@end

@implementation SZFriendsDeviceChain

// Every rule that needs other links, on links whose own signatures were checked. `links` must list parents first.
+ (nullable instancetype)chainWithCheckedLinks:(NSArray<SZFriendsChainLink *> *)input error:(NSError **)error {
    if (input.count == 0 || input.count > SZFriendsDeviceChainMaxLinks) {
        SZFFail(error, SZFriendsDeviceChainErrorFull, @"a chain of no links or more than the limit");
        return nil;
    }
    SZFriendsChainLink *genesis = input.firstObject;
    if (genesis.kind != SZFriendsChainLinkGenesis) {
        SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"a chain that does not start with its genesis");
        return nil;
    }
    NSMutableDictionary<NSData *, NSNumber *> *indexOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSData *, NSData *> *staticOf = [NSMutableDictionary dictionary];
    NSMutableArray<NSIndexSet *> *ancestors = [NSMutableArray array];
    for (NSUInteger i = 0; i < input.count; i++) {
        SZFriendsChainLink *link = input[i];
        if (indexOf[link.linkHash] != nil || (i > 0 && link.kind == SZFriendsChainLinkGenesis)) {
            SZFFail(error, i > 0 && link.kind == SZFriendsChainLinkGenesis ? SZFriendsDeviceChainErrorWrongRoot
                                                                             : SZFriendsDeviceChainErrorMalformed,
                    @"a second genesis or a repeated link");
            return nil;
        }
        NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
        for (NSData *parent in link.parentHashes) {
            NSNumber *p = indexOf[parent];
            if (p == nil) {
                SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"a link before its parent, or a missing parent");
                return nil;
            }
            [seen addIndex:p.unsignedIntegerValue];
            [seen addIndexes:ancestors[p.unsignedIntegerValue]];
        }
        if (link.subjectStaticKey != nil) {
            NSData *known = staticOf[link.subjectKey];
            if (known != nil && ![known isEqualToData:link.subjectStaticKey]) {
                SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"one device with two static keys");
                return nil;
            }
            staticOf[link.subjectKey] = link.subjectStaticKey;
        }
        if (i > 0) {
            NSIndexSet *signerAdded = [seen indexesPassingTest:^BOOL(NSUInteger a, BOOL *stop) {
                (void)stop;
                return SZFAddsSubject(input[a], link.signerKey);
            }];
            NSIndexSet *subjectAdded = [seen indexesPassingTest:^BOOL(NSUInteger a, BOOL *stop) {
                (void)stop;
                return SZFAddsSubject(input[a], link.subjectKey);
            }];
            NSIndexSet *subjectRevoked = [seen indexesPassingTest:^BOOL(NSUInteger a, BOOL *stop) {
                (void)stop;
                return input[a].kind == SZFriendsChainLinkRevoke && [input[a].subjectKey isEqualToData:link.subjectKey];
            }];
            if (signerAdded.count == 0) {
                SZFFail(error, SZFriendsDeviceChainErrorUnauthorized, @"signed by a device not added before it");
                return nil;
            }
            if (link.kind == SZFriendsChainLinkRevoke && subjectAdded.count == 0) {
                SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"revokes a device the chain never added");
                return nil;
            }
            if (link.kind == SZFriendsChainLinkAdd && subjectRevoked.count > 0) {
                SZFFail(error, SZFriendsDeviceChainErrorRevokedDevice, @"adds a device revoked before");
                return nil;
            }
        }
        indexOf[link.linkHash] = @(i);
        [ancestors addObject:seen];
    }
    NSArray<SZFriendsChainLink *> *links = SZFCanonicalOrder(input);
    if (links == nil) {
        SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"links that cannot be put in order");
        return nil;
    }
    return [[self alloc] initWithOrderedLinks:links error:error];
}

- (nullable instancetype)initWithOrderedLinks:(NSArray<SZFriendsChainLink *> *)links error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _links = [links copy];
    _rootKey = links.firstObject.signerKey;
    _genesisHash = links.firstObject.linkHash;
    NSMutableDictionary<NSData *, NSNumber *> *indexOf = [NSMutableDictionary dictionary];
    NSMutableArray<NSIndexSet *> *ancestors = [NSMutableArray array];
    NSMutableSet<NSData *> *named = [NSMutableSet set];
    NSMutableData *encoded = [NSMutableData data];
    uint8_t header[3] = {SZFChainVersion, (uint8_t)(links.count >> 8), (uint8_t)links.count};
    [encoded appendBytes:header length:3];
    for (NSUInteger i = 0; i < links.count; i++) {
        NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
        for (NSData *parent in links[i].parentHashes) {
            NSUInteger p = indexOf[parent].unsignedIntegerValue;
            [seen addIndex:p];
            [seen addIndexes:ancestors[p]];
            [named addObject:parent];
        }
        [ancestors addObject:seen];
        indexOf[links[i].linkHash] = @(i);
        NSData *bytes = links[i].encodedData;
        uint8_t length[2] = {(uint8_t)(bytes.length >> 8), (uint8_t)bytes.length};
        [encoded appendBytes:length length:2];
        [encoded appendData:bytes];
    }
    if (encoded.length > SZFriendsDeviceChainEncodedMax) {
        SZFFail(error, SZFriendsDeviceChainErrorFull, @"a chain longer than one CHAIN frame holds");
        return nil;
    }
    _encodedData = encoded;
    NSMutableArray<NSData *> *heads = [NSMutableArray array];
    for (SZFriendsChainLink *link in links) {
        if (![named containsObject:link.linkHash]) [heads addObject:link.linkHash];
    }
    _headHashes = [heads sortedArrayUsingComparator:^(NSData *a, NSData *b) { return SZFCompareHashes(a, b); }];
    _linkHashes = [NSSet setWithArray:[links valueForKey:@"linkHash"]];
    SZFriendsChainOutcome *outcome = SZFriendsChainApplyRules(links, ancestors, _rootKey);
    _devices = outcome.devices;
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    for (SZFriendsChainDevice *device in _devices) byKey[device.deviceKey] = device;
    _devicesByKey = byKey;
    _authorizedDevices = [_devices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id d, id b) {
        (void)b;
        return [(SZFriendsChainDevice *)d state] == SZFriendsChainDeviceAuthorized;
    }]];
    return self;
}

+ (nullable instancetype)chainWithData:(NSData *)data
                       expectedRootKey:(nullable NSData *)expectedRootKey
                                 error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    if (data.length < 3 || data.length > SZFriendsDeviceChainEncodedMax || bytes[0] != SZFChainVersion) {
        SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"not a chain of a version this build reads");
        return nil;
    }
    NSUInteger count = ((NSUInteger)bytes[1] << 8) | bytes[2], position = 3;
    if (count == 0 || count > SZFriendsDeviceChainMaxLinks) {
        SZFFail(error, SZFriendsDeviceChainErrorFull, @"a chain of no links or more than the limit");
        return nil;
    }
    NSData *root = expectedRootKey;
    NSMutableArray<SZFriendsChainLink *> *links = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        if (data.length - position < 2) break;
        NSUInteger length = ((NSUInteger)bytes[position] << 8) | bytes[position + 1];
        position += 2;
        if (data.length - position < length) break;
        NSData *encoded = [data subdataWithRange:NSMakeRange(position, length)];
        position += length;
        // The first link names the root; a genesis anywhere else is refused by the structure check.
        SZFriendsChainLink *link = [SZFriendsChainLink linkWithData:encoded rootKey:root error:error];
        if (link == nil) return nil;
        if (i == 0 && link.kind != SZFriendsChainLinkGenesis) {
            SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"a chain that does not start with its genesis");
            return nil;
        }
        root = root ?: link.signerKey;
        [links addObject:link];
    }
    if (links.count != count || position != data.length) {
        SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"a chain cut short or with bytes after it");
        return nil;
    }
    return [self chainWithCheckedLinks:links error:error];
}

+ (nullable instancetype)genesisChainWithIdentity:(SZFriendsIdentity *)root
                                             name:(NSString *)name
                                           system:(NSString *)system
                                             date:(NSDate *)date
                                            error:(NSError **)error {
    SZFriendsChainLink *genesis = [SZFriendsChainLink signedLinkWithKind:SZFriendsChainLinkGenesis
                                                                 parents:@[]
                                                                  signer:root
                                                                 rootKey:root.publicKey
                                                              subjectKey:root.publicKey
                                                               staticKey:root.staticPublicKey
                                                                 consent:SZFriendsDeviceConsent(root, root.publicKey)
                                                                    name:name
                                                                  system:system
                                                                    date:date
                                                                   error:error];
    return genesis ? [self chainWithCheckedLinks:@[ genesis ] error:error] : nil;
}

#pragma mark - Queries

- (nullable SZFriendsChainDevice *)deviceWithKey:(NSData *)deviceKey {
    return self.devicesByKey[deviceKey];
}

- (BOOL)authorizesDeviceKey:(NSData *)deviceKey {
    SZFriendsChainDevice *device = self.devicesByKey[deviceKey];
    return device != nil && device.state == SZFriendsChainDeviceAuthorized;
}

- (BOOL)revokesDeviceKey:(NSData *)deviceKey {
    return self.devicesByKey[deviceKey].state == SZFriendsChainDeviceRevoked;
}

- (BOOL)containsLinkHash:(NSData *)linkHash {
    return [self.linkHashes containsObject:linkHash];
}

- (BOOL)containsChain:(SZFriendsDeviceChain *)other {
    return [other.linkHashes isSubsetOfSet:self.linkHashes];
}

- (nullable SZFriendsDeviceChain *)chainByMergingChain:(SZFriendsDeviceChain *)other error:(NSError **)error {
    if (![other.genesisHash isEqualToData:self.genesisHash]) {
        SZFFail(error, SZFriendsDeviceChainErrorWrongRoot, @"chains of different roots or geneses never merge");
        return nil;
    }
    if ([self containsChain:other]) return self;
    if ([other containsChain:self]) return other;
    NSMutableArray<SZFriendsChainLink *> *union_ = [self.links mutableCopy];
    for (SZFriendsChainLink *link in other.links) {
        if (![self.linkHashes containsObject:link.linkHash]) [union_ addObject:link];
    }
    NSArray<SZFriendsChainLink *> *ordered = SZFCanonicalOrder(union_);
    if (ordered == nil) {
        SZFFail(error, SZFriendsDeviceChainErrorMalformed, @"merged links that cannot be put in order");
        return nil;
    }
    return [SZFriendsDeviceChain chainWithCheckedLinks:ordered error:error];
}

#pragma mark - Builders

- (nullable SZFriendsDeviceChain *)chainByAppendingKind:(SZFriendsChainLinkKind)kind
                                                subject:(NSData *)subject
                                              staticKey:(nullable NSData *)staticKey
                                                consent:(nullable NSData *)consent
                                                   name:(nullable NSString *)name
                                                 system:(nullable NSString *)system
                                                 signer:(SZFriendsIdentity *)signer
                                                   date:(NSDate *)date
                                                  error:(NSError **)error {
    if (![self authorizesDeviceKey:signer.publicKey]) {
        SZFFail(error, SZFriendsDeviceChainErrorUnauthorized, @"only an authorized device signs new links");
        return nil;
    }
    if (self.links.count >= SZFriendsDeviceChainMaxLinks) {
        SZFFail(error, SZFriendsDeviceChainErrorFull, @"the chain holds no more links");
        return nil;
    }
    // Every head, so the new link has seen everything this device knows (ADR 0012: a revocation that misses a link
    // voids it). More heads than a link may name only after that many concurrent branches; the rest stay heads.
    NSArray<NSData *> *parents = self.headHashes;
    if (parents.count > SZFriendsDeviceChainParentsMax) {
        parents = [parents subarrayWithRange:NSMakeRange(0, SZFriendsDeviceChainParentsMax)];
    }
    SZFriendsChainLink *link = [SZFriendsChainLink signedLinkWithKind:kind parents:parents signer:signer
                                                              rootKey:self.rootKey subjectKey:subject
                                                            staticKey:staticKey consent:consent name:name
                                                               system:system date:date error:error];
    if (link == nil) return nil;
    return [SZFriendsDeviceChain chainWithCheckedLinks:[self.links arrayByAddingObject:link] error:error];
}

- (nullable SZFriendsDeviceChain *)chainByAddingDeviceKey:(NSData *)deviceKey
                                                staticKey:(NSData *)staticKey
                                                  consent:(NSData *)consent
                                                     name:(NSString *)name
                                                   system:(NSString *)system
                                                 signedBy:(SZFriendsIdentity *)signer
                                                     date:(NSDate *)date
                                                    error:(NSError **)error {
    for (SZFriendsChainLink *link in self.links) {
        if (link.kind == SZFriendsChainLinkRevoke && [link.subjectKey isEqualToData:deviceKey]) {
            SZFFail(error, SZFriendsDeviceChainErrorRevokedDevice, @"a revoked device is never added again");
            return nil;
        }
    }
    SZFriendsChainDevice *known = [self deviceWithKey:deviceKey];
    if (known != nil && (known.state == SZFriendsChainDeviceAuthorized || ![known.staticKey isEqualToData:staticKey])) {
        SZFFail(error, SZFriendsDeviceChainErrorRefused, @"the device is already in the chain");
        return nil;
    }
    if (!SZFriendsVerifyDeviceConsent(consent, deviceKey, staticKey, self.rootKey)) {
        SZFFail(error, SZFriendsDeviceChainErrorForged, @"the new device's consent does not verify");
        return nil;
    }
    return [self chainByAppendingKind:SZFriendsChainLinkAdd subject:deviceKey staticKey:staticKey consent:consent
                                 name:name system:system signer:signer date:date error:error];
}

- (nullable SZFriendsDeviceChain *)chainByRevokingDeviceKey:(NSData *)deviceKey
                                                   signedBy:(SZFriendsIdentity *)signer
                                                       date:(NSDate *)date
                                                      error:(NSError **)error {
    SZFriendsChainDevice *device = [self deviceWithKey:deviceKey];
    if (device == nil) {
        SZFFail(error, SZFriendsDeviceChainErrorRefused, @"the chain never added that device");
        return nil;
    }
    if (device.state == SZFriendsChainDeviceRevoked) return self;
    return [self chainByAppendingKind:SZFriendsChainLinkRevoke subject:deviceKey staticKey:nil consent:nil name:nil
                               system:nil signer:signer date:date error:error];
}

- (nullable SZFriendsDeviceChain *)chainByRenamingTo:(NSString *)name
                                              system:(NSString *)system
                                            signedBy:(SZFriendsIdentity *)signer
                                                date:(NSDate *)date
                                               error:(NSError **)error {
    SZFriendsChainDevice *device = [self deviceWithKey:signer.publicKey];
    NSString *cleanName = SZFriendsChainLabel(name, SZFriendsDeviceNameMax);
    NSString *cleanSystem = SZFriendsChainLabel(system, SZFriendsDeviceSystemMax);
    if (device != nil && [device.name isEqualToString:cleanName] && [device.system isEqualToString:cleanSystem]) {
        return self;
    }
    if (self.links.count >= SZFriendsDeviceChainRenameLimit) {
        SZFFail(error, SZFriendsDeviceChainErrorFull, @"renames stop so adds and revocations keep their room");
        return nil;
    }
    return [self chainByAppendingKind:SZFriendsChainLinkRename subject:signer.publicKey staticKey:nil consent:nil
                                 name:cleanName system:cleanSystem signer:signer date:date error:error];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SZFriendsDeviceChain %lu links, %lu authorized>",
                                      (unsigned long)self.links.count, (unsigned long)self.authorizedDevices.count];
}

@end
