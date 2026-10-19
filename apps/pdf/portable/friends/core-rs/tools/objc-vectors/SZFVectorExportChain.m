// Vector export: device chains (ADR 0012) and joining (ADR 0013), from the helper's own SZFriendsDeviceChain and
// SZFriendsJoin code. Signatures are deterministic, so every chain below is the same bytes on every run.

#import "SZFVectorExport.h"

#import "service/identity/SZFriendsCPace.h"
#import "service/identity/SZFriendsDeviceChainInternal.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/identity/SZFriendsJoinInternal.h"

static const NSTimeInterval SZFT0 = 1760000000.125;

static NSDate *SZFAt(NSTimeInterval offset) { return [NSDate dateWithTimeIntervalSince1970:SZFT0 + offset]; }

static id SZFOrNull(id _Nullable value) { return value ?: [NSNull null]; }

// C0 and C1 controls cannot be written as universal character names in a literal.
static NSString *SZFChar(unichar c) { return [NSString stringWithCharacters:&c length:1]; }

static NSData *SZFScalar(NSString *label) {
    NSMutableData *scalar = [SZFDerive(label, 32) mutableCopy];
    ((uint8_t *)scalar.mutableBytes)[31] &= 0x0f; // below the group order, as a drawn scalar is once reduced
    return scalar;
}

static NSDictionary *SZFChainEntry(NSString *label, SZFriendsDeviceChain *chain) {
    NSMutableArray *links = [NSMutableArray array];
    for (SZFriendsChainLink *link in chain.links) {
        [links addObject:@{@"kind" : @(link.kind), @"hash" : SZFHexString(link.linkHash),
                           @"encoded" : SZFHexString(link.encodedData)}];
    }
    NSMutableArray *devices = [NSMutableArray array];
    for (SZFriendsChainDevice *device in chain.devices) {
        [devices addObject:@{
            @"device_key" : SZFHexString(device.deviceKey), @"static_key" : SZFHexString(device.staticKey),
            @"name" : device.name, @"system" : device.system, @"added_at" : @(device.addedAt.timeIntervalSince1970),
            @"revoked_at" : device.revokedAt ? @(device.revokedAt.timeIntervalSince1970) : [NSNull null],
            @"state" : @(device.state), @"is_root" : @(device.isRoot),
        }];
    }
    NSMutableArray *heads = [NSMutableArray array];
    for (NSData *head in chain.headHashes) [heads addObject:SZFHexString(head)];
    return @{@"label" : label, @"encoded" : SZFHexString(chain.encodedData), @"root" : SZFHexString(chain.rootKey),
             @"genesis_hash" : SZFHexString(chain.genesisHash), @"links" : links, @"heads" : heads,
             @"devices" : devices};
}

static SZFriendsDeviceChain *SZFAdd(SZFriendsDeviceChain *chain, NSString *who, NSString *name, NSString *by,
                                    NSTimeInterval at) {
    SZFriendsIdentity *device = SZFVectorIdentity(who);
    NSData *consent = SZFriendsDeviceConsent(device, chain.rootKey);
    SZFriendsDeviceChain *added = [chain chainByAddingDeviceKey:device.publicKey staticKey:device.staticPublicKey
                                                        consent:consent name:name system:@"Windows 11"
                                                       signedBy:SZFVectorIdentity(by) date:SZFAt(at) error:NULL];
    if (added == nil) [NSException raise:NSInternalInconsistencyException format:@"add %@ by %@", who, by];
    return added;
}

static SZFriendsDeviceChain *SZFRevoke(SZFriendsDeviceChain *chain, NSString *who, NSString *by, NSTimeInterval at) {
    SZFriendsDeviceChain *revoked = [chain chainByRevokingDeviceKey:SZFVectorIdentity(who).publicKey
                                                           signedBy:SZFVectorIdentity(by) date:SZFAt(at) error:NULL];
    if (revoked == nil) [NSException raise:NSInternalInconsistencyException format:@"revoke %@ by %@", who, by];
    return revoked;
}

static SZFriendsDeviceChain *SZFMerge(SZFriendsDeviceChain *a, SZFriendsDeviceChain *b) {
    SZFriendsDeviceChain *merged = [a chainByMergingChain:b error:NULL];
    if (merged == nil) [NSException raise:NSInternalInconsistencyException format:@"merge"];
    return merged;
}

// Every 5th byte of `data` flipped, and some cuts: what decoding says of each.
static NSArray *SZFMutations(NSData *data, NSData *root) {
    NSMutableArray *cases = [NSMutableArray array];
    void (^record)(NSData *, NSString *) = ^(NSData *bytes, NSString *what) {
        NSError *error = nil;
        SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:bytes expectedRootKey:root error:&error];
        [cases addObject:@{@"what" : what, @"data" : SZFHexString(bytes),
                           @"error" : chain ? @0 : @(error.code)}];
    };
    for (NSUInteger i = 0; i < data.length; i += 5) {
        NSMutableData *flipped = [data mutableCopy];
        ((uint8_t *)flipped.mutableBytes)[i] ^= 0x01;
        record(flipped, [NSString stringWithFormat:@"flip %lu", (unsigned long)i]);
    }
    record([data subdataWithRange:NSMakeRange(0, data.length - 1)], @"cut");
    NSMutableData *longer = [data mutableCopy];
    [longer appendBytes:"\0" length:1];
    record(longer, @"extra byte");
    return cases;
}

static NSDictionary *SZFExportChains(void) {
    SZFriendsIdentity *alice = SZFVectorIdentity(@"alice");
    NSMutableArray *chains = [NSMutableArray array];
    SZFriendsDeviceChain *genesis = [SZFriendsDeviceChain genesisChainWithIdentity:alice name:@"Alice's Mac"
                                                                            system:@"macOS 26.1" date:SZFAt(0)
                                                                             error:NULL];
    [chains addObject:SZFChainEntry(@"genesis", genesis)];
    SZFriendsDeviceChain *two = SZFAdd(genesis, @"bob", @"Bob's PC", @"alice", 10);
    [chains addObject:SZFChainEntry(@"add bob", two)];
    SZFriendsDeviceChain *three = SZFAdd(two, @"carol", @"Carol \U0001F98A laptop", @"bob", 20);
    [chains addObject:SZFChainEntry(@"add carol by bob", three)];
    NSString *bobsName = [NSString stringWithFormat:@"  Bob's\tnew PC%@ ", SZFChar(7)];
    SZFriendsDeviceChain *renamed = [three chainByRenamingTo:bobsName system:@"Ubuntu 24.04"
                                                    signedBy:SZFVectorIdentity(@"bob") date:SZFAt(30) error:NULL];
    [chains addObject:SZFChainEntry(@"rename bob", renamed)];
    [chains addObject:SZFChainEntry(@"revoke carol", SZFRevoke(renamed, @"carol", @"alice", 40))];
    // Concurrent: alice revokes bob while bob adds dave unseen; dave rests on bob, so it is void.
    SZFriendsDeviceChain *revokeBob = SZFRevoke(two, @"bob", @"alice", 50);
    SZFriendsDeviceChain *bobAddsDave = SZFAdd(two, @"dave", @"Dave", @"bob", 51);
    [chains addObject:SZFChainEntry(@"revoke bob and dave added unseen", SZFMerge(revokeBob, bobAddsDave))];
    // Mutual revocation: both end revoked, alice included.
    SZFriendsDeviceChain *bobRevokesAlice = SZFRevoke(two, @"alice", @"bob", 52);
    [chains addObject:SZFChainEntry(@"mutual revocation", SZFMerge(bobRevokesAlice, revokeBob))];
    // Concurrent renames settle on the later clock.
    SZFriendsDeviceChain *renameA = [two chainByRenamingTo:@"Alice A" system:@"macOS 26.1"
                                                  signedBy:alice date:SZFAt(60) error:NULL];
    SZFriendsDeviceChain *renameB = [two chainByRenamingTo:@"Alice B" system:@"macOS 26.2"
                                                  signedBy:alice date:SZFAt(61) error:NULL];
    [chains addObject:SZFChainEntry(@"concurrent renames", SZFMerge(renameA, renameB))];
    NSString *longName = [@"\U0001F468‍\U0001F469‍\U0001F467 " stringByPaddingToLength:80
                                                                                  withString:@"é"
                                                                             startingAtIndex:0];
    SZFriendsDeviceChain *longLabel = SZFAdd(genesis, @"erin", longName, @"alice", 70);
    [chains addObject:SZFChainEntry(@"long label", longLabel)];
    NSError *error = nil;
    SZFriendsDeviceChain *readd = [SZFRevoke(two, @"bob", @"alice", 80)
        chainByAddingDeviceKey:SZFVectorIdentity(@"bob").publicKey staticKey:SZFVectorIdentity(@"bob").staticPublicKey
                       consent:SZFriendsDeviceConsent(SZFVectorIdentity(@"bob"), alice.publicKey) name:@"again"
                        system:@"x" signedBy:alice date:SZFAt(81) error:&error];
    NSMutableArray *labels = [NSMutableArray array];
    NSString *controls = [NSString stringWithFormat:@"%@next%@", SZFChar(0x85), SZFChar(0x9F)];
    for (NSString *input in @[ @"  plain  ", @"tab\tinside", controls, longName, @" 　", @"" ]) {
        [labels addObject:@{@"input" : input, @"name" : SZFriendsChainLabel(input, SZFriendsDeviceNameMax)}];
    }
    return @{
        @"identities" : @[ @"alice", @"bob", @"carol", @"dave", @"erin" ],
        @"t0" : @(SZFT0),
        @"chains" : chains,
        @"wrong_root" : @{@"data" : SZFHexString(three.encodedData), @"root" : SZFHexString(SZFVectorIdentity(@"bob")
                                                                                              .publicKey)},
        @"mutations" : SZFMutations(three.encodedData, alice.publicKey),
        @"readd_revoked_error" : readd ? @0 : @(error.code),
        @"labels" : labels,
        @"consent" : SZFHexString(SZFriendsDeviceConsent(SZFVectorIdentity(@"bob"), alice.publicKey)),
    };
}

#pragma mark - Joining

static NSDictionary *SZFExportJoin(void) {
    SZFriendsIdentity *alice = SZFVectorIdentity(@"alice"), *dave = SZFVectorIdentity(@"dave");
    SZFriendsDeviceChain *chain = SZFAdd([SZFriendsDeviceChain genesisChainWithIdentity:alice name:@"Alice's Mac"
                                                                                 system:@"macOS 26.1" date:SZFAt(0)
                                                                                  error:NULL],
                                         @"bob", @"Bob's PC", @"alice", 10);
    NSData *requestID = SZFDerive(@"join request id", 16);
    NSData *request = SZFriendsJoinRequestMessage(dave, requestID, @"maple-otter", @"Dave's Laptop", @"Ubuntu 24.04",
                                                  SZFAt(100));
    NSString *code = @"04831220";
    NSData *hash = SZFDerive(@"join handshake hash", 64);
    NSData *scalarA = SZFScalar(@"join scalar a"), *scalarB = SZFScalar(@"join scalar b");
    NSData *ci = SZFriendsJoinChannelIdentifier(requestID, dave.publicKey, dave.staticPublicKey);
    NSData *prs = SZFUTF8(code);
    SZFriendsCPace *a = [[SZFriendsCPace alloc] initWithPassword:prs channelIdentifier:ci
                                                       sessionID:hash scalar:scalarA];
    SZFriendsCPace *b = [[SZFriendsCPace alloc] initWithPassword:prs channelIdentifier:ci
                                                       sessionID:hash scalar:scalarB];
    NSData *codeMessage = SZFriendsJoinEncode(SZFriendsJoinMessageCode, @{
        @(SZFriendsJoinTagRequestID) : requestID, @(SZFriendsJoinTagShare) : a.share});
    // The approving device is bob, a device of alice's profile.
    SZFriendsIdentity *bob = SZFVectorIdentity(@"bob");
    NSData *adB = SZFriendsJoinApproverAD(bob.publicKey, alice.publicKey);
    NSData *iskB = [b iskAsResponderWithAD:adB peerShare:a.share peerAD:dave.publicKey];
    NSData *reply = SZFriendsJoinEncode(SZFriendsJoinMessageReply, @{
        @(SZFriendsJoinTagShare) : b.share, @(SZFriendsJoinTagApproverKey) : bob.publicKey,
        @(SZFriendsJoinTagRootKey) : alice.publicKey,
        @(SZFriendsJoinTagTag) : SZFriendsJoinTag(iskB, SZFriendsJoinResponderTagDomain, nil)});
    NSData *iskA = [a iskAsInitiatorWithAD:dave.publicKey peerShare:b.share peerAD:adB];
    NSData *consent = SZFriendsDeviceConsent(dave, alice.publicKey);
    NSData *confirm = SZFriendsJoinEncode(SZFriendsJoinMessageConfirm, @{
        @(SZFriendsJoinTagConsent) : consent,
        @(SZFriendsJoinTagTag) : SZFriendsJoinTag(iskA, SZFriendsJoinInitiatorTagDomain, consent)});
    SZFriendsDeviceChain *added = [chain chainByAddingDeviceKey:dave.publicKey staticKey:dave.staticPublicKey
                                                        consent:consent name:@"Dave's Laptop" system:@"Ubuntu 24.04"
                                                       signedBy:bob date:SZFAt(200) error:NULL];
    NSData *profile = SZFDerive(@"join profile", 1500);
    NSMutableDictionary *fields = [@{
        @(SZFriendsJoinTagChain) : added.encodedData, @(SZFriendsJoinTagProfile) : profile,
        @(SZFriendsJoinTagIDState) : SZFriendsJoinUInt8(2), @(SZFriendsJoinTagTag) : [NSMutableData dataWithLength:32],
    } mutableCopy];
    fields[@(SZFriendsJoinTagTag)] = SZFriendsJoinTag(iskB, SZFriendsJoinWelcomeTagDomain,
                                                      SZFriendsJoinEncode(SZFriendsJoinMessageWelcome, fields));
    NSData *whole = SZFriendsJoinEncode(SZFriendsJoinMessageWelcome, fields);
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger count = (whole.length + SZFriendsJoinPartMax - 1) / SZFriendsJoinPartMax;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger start = i * SZFriendsJoinPartMax;
        NSRange range = NSMakeRange(start, MIN(SZFriendsJoinPartMax, whole.length - start));
        [parts addObject:SZFHexString(SZFriendsJoinEncode(SZFriendsJoinMessagePart, @{
                   @(SZFriendsJoinTagPartIndex) : SZFriendsJoinUInt8((uint8_t)i),
                   @(SZFriendsJoinTagPartCount) : SZFriendsJoinUInt8((uint8_t)count),
                   @(SZFriendsJoinTagPartData) : [whole subdataWithRange:range]}))];
    }
    NSMutableArray *codes = [NSMutableArray array];
    for (NSString *typed in @[ @"0483 1220", @"0483-1220", @"０４８３　１２２０",
                               @"0483122", @"04831220x", @"0483–1220", @"1́234567" ]) {
        [codes addObject:@{@"typed" : typed, @"code" : SZFOrNull(SZFriendsJoinNormalizedCode(typed))}];
    }
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *name in @[ @"Dave", @" ", @"tab\tname", @"zero​width", @" x", @"emoji \U0001F98A" ]) {
        NSData *message = SZFriendsJoinRequestMessage(dave, requestID, @"maple-otter", name, @"Ubuntu", SZFAt(100));
        [names addObject:@{@"name" : name, @"message" : SZFOrNull(message ? SZFHexString(message) : nil)}];
    }
    return @{
        @"request_id" : SZFHexString(requestID), @"friends_id" : @"maple-otter", @"name" : @"Dave's Laptop",
        @"system" : @"Ubuntu 24.04", @"time" : @(SZFT0 + 100), @"request" : SZFHexString(request),
        @"code" : code, @"handshake_hash" : SZFHexString(hash), @"scalar_a" : SZFHexString(scalarA),
        @"scalar_b" : SZFHexString(scalarB), @"code_message" : SZFHexString(codeMessage),
        @"reply" : SZFHexString(reply), @"confirm" : SZFHexString(confirm), @"chain" : SZFHexString(chain.encodedData),
        @"welcome_time" : @(SZFT0 + 200), @"profile" : SZFHexString(profile), @"id_state" : @2,
        @"added_chain" : SZFHexString(added.encodedData), @"parts" : parts,
        @"ended" : @[ SZFHexString(SZFriendsJoinEndedMessage(SZFriendsJoinEndDenied)),
                      SZFHexString(SZFriendsJoinEndedMessage(SZFriendsJoinEndExpired)),
                      SZFHexString(SZFriendsJoinEndedMessage(SZFriendsJoinEndTooManyAttempts)) ],
        @"codes" : codes, @"names" : names,
    };
}

NSDictionary *SZFExportChain(void) {
    return @{@"chain" : SZFExportChains(), @"join" : SZFExportJoin()};
}
