// friends-identity-check: the device chain's format, builders and the cases ADR 0012 names one by one: forged,
// out-of-order, revoked-signer and forked chains, re-adding a revoked device, and revocation winning a merge.
// The randomized merge properties are SZFriendsDeviceChainPropertyTests.m.

#import "SZFriendsIdentityTestSupport.h"

#import "service/identity/SZFriendsDeviceChainInternal.h"
#import "service/identity/SZFriendsIdentityInternal.h"

#include <sodium.h>

static NSDate *At(double seconds) { return [NSDate dateWithTimeIntervalSince1970:1791800000 + seconds]; }

static SZFriendsIdentity *Device(uint8_t seed) {
    uint8_t signing[32], key[32];
    memset(signing, seed, 32);
    memset(key, (uint8_t)(seed + 0x40), 32);
    return [SZFriendsIdentity identityWithSigningSeed:[NSData dataWithBytes:signing length:32]
                                     staticPrivateKey:[NSData dataWithBytes:key length:32]];
}

static SZFriendsDeviceChain *Add(SZFriendsDeviceChain *chain, SZFriendsIdentity *device, SZFriendsIdentity *signer,
                                 double when) {
    NSError *error = nil;
    SZFriendsDeviceChain *next = [chain chainByAddingDeviceKey:device.publicKey
                                                     staticKey:device.staticPublicKey
                                                       consent:SZFriendsDeviceConsent(device, chain.rootKey)
                                                          name:@"MacBook Air"
                                                        system:@"macOS 26.1"
                                                      signedBy:signer
                                                          date:At(when)
                                                         error:&error];
    SZFExpect(next != nil, @"add: %@", error);
    return next;
}

static SZFriendsDeviceChain *Revoke(SZFriendsDeviceChain *chain, SZFriendsIdentity *device, SZFriendsIdentity *signer,
                                    double when) {
    NSError *error = nil;
    SZFriendsDeviceChain *next = [chain chainByRevokingDeviceKey:device.publicKey signedBy:signer date:At(when)
                                                           error:&error];
    SZFExpect(next != nil, @"revoke: %@", error);
    return next;
}

static SZFriendsDeviceChain *Merge(SZFriendsDeviceChain *a, SZFriendsDeviceChain *b) {
    NSError *error = nil;
    SZFriendsDeviceChain *merged = [a chainByMergingChain:b error:&error];
    SZFExpect(merged != nil, @"merge: %@", error);
    return merged;
}

static SZFriendsDeviceChain *Genesis(SZFriendsIdentity *root) {
    return [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"Mei's iMac" system:@"macOS 26.0" date:At(0)
                                                    error:NULL];
}

// The encoding of a chain whose links come in `order` (indexes into chain.links), for out-of-order and forged cases.
static NSData *Encode(NSArray<SZFriendsChainLink *> *links) {
    NSMutableData *data = [NSMutableData data];
    uint8_t header[3] = {1, 0, (uint8_t)links.count};
    [data appendBytes:header length:3];
    for (SZFriendsChainLink *link in links) {
        uint8_t length[2] = {(uint8_t)(link.encodedData.length >> 8), (uint8_t)link.encodedData.length};
        [data appendBytes:length length:2];
        [data appendData:link.encodedData];
    }
    return data;
}

static NSInteger DecodeError(NSData *data, NSData *root) {
    NSError *error = nil;
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:data expectedRootKey:root error:&error];
    return chain ? 0 : error.code;
}

static void TestGenesisMigratesTheExistingIdentity(void) {
    SZFriendsIdentity *root = Device(1);
    SZFriendsDeviceChain *chain = Genesis(root);
    SZFExpect([chain.rootKey isEqualToData:root.publicKey] && chain.links.count == 1, @"genesis names the root");
    SZFriendsChainDevice *first = chain.devices.firstObject;
    SZFExpect(first.isRoot && [first.deviceKey isEqualToData:root.publicKey] &&
                  [first.staticKey isEqualToData:root.staticPublicKey] && first.state == SZFriendsChainDeviceAuthorized,
              @"the first device keeps the identity's keys, so friends see no key change");
    SZFExpect([first.name isEqualToString:@"Mei's iMac"] && [first.system isEqualToString:@"macOS 26.0"], @"labels");
    SZFriendsDeviceChain *decoded = [SZFriendsDeviceChain chainWithData:chain.encodedData expectedRootKey:nil
                                                                  error:NULL];
    SZFExpect([decoded.encodedData isEqualToData:chain.encodedData] &&
                  [decoded.genesisHash isEqualToData:chain.genesisHash], @"round trip");
    SZFExpect([SZFriendsDeviceChain genesisChainWithIdentity:root name:@" \n" system:@"macOS" date:At(0)
                                                       error:NULL] == nil, @"an empty name is refused");
    NSString *long_ = [@"" stringByPaddingToLength:70 withString:@"é" startingAtIndex:0];
    SZFriendsDeviceChain *cut = [SZFriendsDeviceChain genesisChainWithIdentity:root name:long_ system:@"macOS"
                                                                          date:At(0) error:NULL];
    SZFExpect([cut.devices.firstObject.name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 64,
              @"names are cut on a character at 64 bytes");
}

static void TestAddRevokeRename(void) {
    SZFriendsIdentity *root = Device(1), *laptop = Device(2), *desk = Device(3);
    SZFriendsDeviceChain *chain = Add(Genesis(root), laptop, root, 10);
    SZFExpect([chain authorizesDeviceKey:laptop.publicKey] && chain.authorizedDevices.count == 2, @"added");
    chain = Add(chain, desk, laptop, 20);
    SZFExpect([chain authorizesDeviceKey:desk.publicKey], @"a device added by a non-root device counts");
    NSError *error = nil;
    SZFExpect([chain chainByAddingDeviceKey:desk.publicKey staticKey:desk.staticPublicKey
                                    consent:SZFriendsDeviceConsent(desk, chain.rootKey) name:@"x" system:@"y"
                                   signedBy:root date:At(21) error:&error] == nil &&
                  error.code == SZFriendsDeviceChainErrorRefused, @"an authorized device is not added twice");
    SZFriendsIdentity *other = Device(9);
    SZFExpect([chain chainByAddingDeviceKey:desk.publicKey staticKey:desk.staticPublicKey
                                    consent:SZFriendsDeviceConsent(desk, other.publicKey) name:@"x" system:@"y"
                                   signedBy:root date:At(21) error:&error] == nil, @"consent for another root");
    SZFriendsIdentity *stranger = Device(8);
    SZFExpect([chain chainByAddingDeviceKey:stranger.publicKey staticKey:stranger.staticPublicKey
                                    consent:SZFriendsDeviceConsent(stranger, chain.rootKey) name:@"x" system:@"y"
                                   signedBy:other date:At(21) error:&error] == nil &&
                  error.code == SZFriendsDeviceChainErrorUnauthorized, @"only an authorized device signs");
    SZFriendsDeviceChain *renamed = [chain chainByRenamingTo:@"Studio" system:@"macOS 26.2" signedBy:desk date:At(30)
                                                       error:&error];
    SZFExpect([[renamed deviceWithKey:desk.publicKey].name isEqualToString:@"Studio"] &&
                  [[renamed deviceWithKey:desk.publicKey].system isEqualToString:@"macOS 26.2"], @"rename: %@", error);
    SZFExpect([renamed chainByRenamingTo:@"Studio" system:@"macOS 26.2" signedBy:desk date:At(31) error:NULL] ==
                  renamed, @"renaming to the same labels adds nothing");
    // A rename that saw the name it replaces shows, whatever the clocks: in the same millisecond as the add (a genesis
    // written just to rename), or with the signer's clock behind.
    for (NSNumber *seconds in @[ @20, @5 ]) {
        SZFriendsDeviceChain *again = [chain chainByRenamingTo:@"Back room" system:@"macOS 26.2" signedBy:desk
                                                          date:At(seconds.doubleValue) error:NULL];
        SZFExpect([[again deviceWithKey:desk.publicKey].name isEqualToString:@"Back room"],
                  @"the later rename shows at %@ s", seconds);
    }
    chain = Revoke(renamed, laptop, desk, 40);
    SZFriendsChainDevice *gone = [chain deviceWithKey:laptop.publicKey];
    SZFExpect(gone.state == SZFriendsChainDeviceRevoked && [gone.revokedAt isEqualToDate:At(40)] &&
                  [chain authorizesDeviceKey:desk.publicKey], @"what the revoked laptop added before stays");
    SZFExpect([chain chainByAddingDeviceKey:laptop.publicKey staticKey:laptop.staticPublicKey
                                    consent:SZFriendsDeviceConsent(laptop, chain.rootKey) name:@"x" system:@"y"
                                   signedBy:root date:At(50) error:&error] == nil &&
                  error.code == SZFriendsDeviceChainErrorRevokedDevice, @"a revoked device is never added again");
    SZFExpect([chain chainByRevokingDeviceKey:laptop.publicKey signedBy:root date:At(51) error:NULL] == chain,
              @"revoking twice adds nothing");
    SZFExpect([chain chainByRenamingTo:@"Old" system:@"macOS" signedBy:laptop date:At(52) error:&error] == nil &&
                  error.code == SZFriendsDeviceChainErrorUnauthorized, @"a revoked device signs nothing more");
}

static void TestForgedChainsAreRefused(void) {
    SZFriendsIdentity *root = Device(1), *laptop = Device(2);
    SZFriendsDeviceChain *chain = Add(Genesis(root), laptop, root, 10);
    NSData *good = chain.encodedData;
    SZFExpect(DecodeError(good, root.publicKey) == 0, @"the honest chain decodes");
    // Every single-byte change in every link is refused, whichever check catches it.
    NSUInteger refused = 0;
    for (NSUInteger i = 3; i < good.length; i++) {
        NSMutableData *bad = [good mutableCopy];
        ((uint8_t *)bad.mutableBytes)[i] ^= 0x01;
        refused += DecodeError(bad, root.publicKey) != 0;
    }
    SZFExpect(refused == good.length - 3, @"every flipped byte is refused (%lu of %lu)", (unsigned long)refused,
              (unsigned long)(good.length - 3));
    SZFExpect(DecodeError(good, Device(7).publicKey) == SZFriendsDeviceChainErrorWrongRoot, @"another root's chain");
    // A link signed by a key the chain never added, even with a valid signature, is refused.
    SZFriendsIdentity *outsider = Device(6), *victim = Device(5);
    SZFriendsChainLink *intruder = [SZFriendsChainLink
        signedLinkWithKind:SZFriendsChainLinkAdd parents:chain.headHashes signer:outsider rootKey:root.publicKey
                subjectKey:victim.publicKey staticKey:victim.staticPublicKey
                   consent:SZFriendsDeviceConsent(victim, root.publicKey) name:@"x" system:@"y" date:At(11)
                     error:NULL];
    SZFExpect(DecodeError(Encode([chain.links arrayByAddingObject:intruder]), nil) ==
                  SZFriendsDeviceChainErrorUnauthorized, @"an outsider's link");
    // Claiming someone else's device: the add's consent must be that device's own signature for this root.
    SZFriendsChainLink *claim = [SZFriendsChainLink
        signedLinkWithKind:SZFriendsChainLinkAdd parents:chain.headHashes signer:root rootKey:root.publicKey
                subjectKey:victim.publicKey staticKey:victim.staticPublicKey
                   consent:SZFriendsDeviceConsent(victim, Device(4).publicKey) name:@"x" system:@"y" date:At(11)
                     error:NULL];
    SZFExpect(DecodeError(Encode([chain.links arrayByAddingObject:claim]), nil) == SZFriendsDeviceChainErrorForged,
              @"another person's device cannot be claimed");
    SZFExpect(DecodeError([good subdataWithRange:NSMakeRange(0, good.length - 1)], nil) ==
                  SZFriendsDeviceChainErrorMalformed, @"a cut chain");
}

static void TestOutOfOrderAndForkedChains(void) {
    SZFriendsIdentity *root = Device(1), *laptop = Device(2), *desk = Device(3);
    SZFriendsDeviceChain *chain = Add(Add(Genesis(root), laptop, root, 10), desk, laptop, 20);
    NSArray<SZFriendsChainLink *> *links = chain.links;
    SZFExpect(DecodeError(Encode(@[ links[0], links[2], links[1] ]), nil) == SZFriendsDeviceChainErrorMalformed,
              @"a link before its parent is refused");
    SZFExpect(DecodeError(Encode(@[ links[0], links[2] ]), nil) == SZFriendsDeviceChainErrorMalformed,
              @"a link whose parent is missing is refused");
    SZFExpect(DecodeError(Encode(@[ links[1], links[0], links[2] ]), nil) == SZFriendsDeviceChainErrorMalformed,
              @"a chain must start with its genesis");
    SZFExpect(DecodeError(Encode(@[ links[0], links[1], links[1] ]), nil) == SZFriendsDeviceChainErrorMalformed,
              @"a repeated link is refused");
    // A second genesis by the same root (someone holding the root key forking the person) never merges.
    SZFriendsDeviceChain *fork = [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"Other" system:@"macOS"
                                                                           date:At(5) error:NULL];
    NSError *error = nil;
    SZFExpect([chain chainByMergingChain:fork error:&error] == nil && error.code == SZFriendsDeviceChainErrorWrongRoot,
              @"a forked genesis is refused");
    SZFExpect(DecodeError(Encode(@[ links[0], fork.links[0] ]), nil) == SZFriendsDeviceChainErrorWrongRoot,
              @"one chain never holds two geneses");
}

static void TestRevokedSigner(void) {
    SZFriendsIdentity *root = Device(1), *thief = Device(2), *later = Device(3), *fresh = Device(4);
    SZFriendsIdentity *bystander = Device(5);
    SZFriendsDeviceChain *base = Add(Add(Genesis(root), thief, root, 10), bystander, root, 11);
    SZFriendsDeviceChain *owner = Revoke(base, thief, root, 20);
    // The stolen laptop, cut off from the revocation, keeps signing on the old branch: it adds a device, which adds
    // another and revokes a device of the owner's.
    SZFriendsDeviceChain *stolen = Add(base, later, thief, 30);
    stolen = Revoke(Add(stolen, fresh, later, 31), bystander, later, 32);
    SZFriendsDeviceChain *merged = Merge(owner, stolen);
    SZFExpect([merged authorizesDeviceKey:bystander.publicKey], @"a device that rests on a void add revokes nothing");
    SZFExpect([merged revokesDeviceKey:thief.publicKey], @"the revocation stands");
    SZFExpect(![merged authorizesDeviceKey:later.publicKey] &&
                  [merged deviceWithKey:later.publicKey].state == SZFriendsChainDeviceVoid,
              @"what the revoked device signed without the revocation seeing it is void");
    SZFExpect(![merged authorizesDeviceKey:fresh.publicKey], @"and so is what rested on it");
    SZFExpect([merged.encodedData isEqualToData:Merge(stolen, owner).encodedData], @"merge order changes nothing");
    // Signing after its own revocation was seen: the chain refuses nothing (the link is structurally fine) but it
    // counts for nothing.
    SZFriendsChainLink *afterwards = [SZFriendsChainLink
        signedLinkWithKind:SZFriendsChainLinkRename parents:owner.headHashes signer:thief rootKey:root.publicKey
                subjectKey:thief.publicKey staticKey:nil consent:nil name:@"Mine now" system:@"macOS" date:At(40)
                     error:NULL];
    SZFriendsDeviceChain *withRename = [SZFriendsDeviceChain chainWithData:Encode([owner.links
                                                                               arrayByAddingObject:afterwards])
                                                           expectedRootKey:root.publicKey error:NULL];
    SZFExpect(withRename != nil && [[withRename deviceWithKey:thief.publicKey].name isEqualToString:@"MacBook Air"] &&
                  [withRename revokesDeviceKey:thief.publicKey], @"a revoked device's later rename counts for nothing");
}

static void TestRevocationWins(void) {
    SZFriendsIdentity *root = Device(1), *laptop = Device(2), *desk = Device(3), *phone = Device(4);
    SZFriendsDeviceChain *base = Add(Add(Genesis(root), laptop, root, 10), desk, root, 11);
    // One branch revokes the laptop; a concurrent one keeps using it and renames the desk's neighbour.
    SZFriendsDeviceChain *revoking = Revoke(base, laptop, desk, 20);
    SZFriendsDeviceChain *keeping = [base chainByRenamingTo:@"Still here" system:@"macOS 26.1" signedBy:laptop
                                                       date:At(21) error:NULL];
    keeping = Add(keeping, phone, root, 22);
    SZFriendsDeviceChain *merged = Merge(revoking, keeping);
    SZFExpect([merged revokesDeviceKey:laptop.publicKey] && [merged authorizesDeviceKey:phone.publicKey],
              @"a branch that keeps a device cannot undo its revocation; the other branch's adds stay");
    // Two devices revoking each other at once: both are revoked.
    SZFriendsDeviceChain *a = Revoke(base, desk, laptop, 30), *b = Revoke(base, laptop, desk, 30);
    SZFriendsDeviceChain *both = Merge(a, b);
    SZFExpect([both revokesDeviceKey:laptop.publicKey] && [both revokesDeviceKey:desk.publicKey] &&
                  [both authorizesDeviceKey:root.publicKey], @"mutual revocations both stand");
    // A revoked device revoking a third device behind the revocation's back: void.
    SZFriendsDeviceChain *revenge = Revoke(base, root, laptop, 31);
    SZFriendsDeviceChain *settled = Merge(revoking, revenge);
    SZFExpect([settled authorizesDeviceKey:root.publicKey] && [settled revokesDeviceKey:laptop.publicKey],
              @"a revoked device cannot revoke others it was not revoked by");
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) return 1;
        TestGenesisMigratesTheExistingIdentity();
        TestAddRevokeRename();
        TestForgedChainsAreRefused();
        TestOutOfOrderAndForkedChains();
        TestRevokedSigner();
        TestRevocationWins();
        return SZFFinish("SZFriendsDeviceChainTests");
    }
}
