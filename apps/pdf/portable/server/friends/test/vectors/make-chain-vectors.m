// Writes test/vectors/device-chain-v1.json: device chains the helper's own SZFriendsDeviceChain builds from public
// TEST seeds, with the verdict and device states it gives each, so the host's reader (src/device-chain.js) is checked
// against the reference byte for byte (test/device-chain.test.js). Run only for a deliberate change, from portable/,
// after `make BUILD=<dir> friends-identity-check` has built the identity objects:
//
//   B=<dir>/build/friends; clang -fobjc-arc -Ifriends -Ifriends/deps/libsodium/src/libsodium/include \
//     -DSODIUM_STATIC=1 server/friends/test/vectors/make-chain-vectors.m $B/identity/*.o $B/libsodium.a \
//     -framework Foundation -framework Security -framework LocalAuthentication -o <dir>/make-chain-vectors && \
//     <dir>/make-chain-vectors > server/friends/test/vectors/device-chain-v1.json
//
// (The libsodium include directory is FRIENDS_SODIUM_CFLAGS in friends/deps/deps.mk.)

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"

static SZFriendsIdentity *Device(uint8_t seed) {
    uint8_t signing[32], staticKey[32];
    memset(signing, seed, sizeof signing);
    memset(staticKey, (uint8_t)(seed + 0x40), sizeof staticKey);
    return [SZFriendsIdentity identityWithSigningSeed:[NSData dataWithBytes:signing length:32]
                                     staticPrivateKey:[NSData dataWithBytes:staticKey length:32]];
}

static NSDate *At(int minutes) {
    return [NSDate dateWithTimeIntervalSince1970:1791800000 + minutes * 60];
}

static NSString *Hex(NSData *data) {
    NSMutableString *out = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [out appendFormat:@"%02x", bytes[i]];
    return out;
}

static NSString *B64(NSData *data) {
    NSString *text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static SZFriendsDeviceChain *Must(SZFriendsDeviceChain *chain, NSError *error) {
    if (chain == nil) {
        fprintf(stderr, "build failed: %s\n", error.description.UTF8String);
        exit(1);
    }
    return chain;
}

static SZFriendsDeviceChain *Add(SZFriendsDeviceChain *chain, SZFriendsIdentity *device, NSString *name,
                                 SZFriendsIdentity *signer, int minute) {
    NSError *error = nil;
    return Must([chain chainByAddingDeviceKey:device.publicKey staticKey:device.staticPublicKey
                                      consent:SZFriendsDeviceConsent(device, chain.rootKey) name:name
                                       system:@"macOS 26.1" signedBy:signer date:At(minute) error:&error], error);
}

static SZFriendsDeviceChain *Revoke(SZFriendsDeviceChain *chain, SZFriendsIdentity *device, SZFriendsIdentity *signer,
                                    int minute) {
    NSError *error = nil;
    return Must([chain chainByRevokingDeviceKey:device.publicKey signedBy:signer date:At(minute) error:&error], error);
}

static SZFriendsDeviceChain *Merge(SZFriendsDeviceChain *a, SZFriendsDeviceChain *b) {
    NSError *error = nil;
    return Must([a chainByMergingChain:b error:&error], error);
}

static NSString *ErrorName(NSInteger code) {
    switch (code) {
    case SZFriendsDeviceChainErrorMalformed: return @"malformed";
    case SZFriendsDeviceChainErrorForged: return @"forged";
    case SZFriendsDeviceChainErrorUnauthorized: return @"unauthorized";
    case SZFriendsDeviceChainErrorRevokedDevice: return @"revoked_device";
    case SZFriendsDeviceChainErrorWrongRoot: return @"wrong_root";
    case SZFriendsDeviceChainErrorFull: return @"full";
    default: return @"refused";
    }
}

static NSString *StateName(SZFriendsChainDeviceState state) {
    return state == SZFriendsChainDeviceAuthorized ? @"authorized"
           : state == SZFriendsChainDeviceRevoked  ? @"revoked"
                                                   : @"void";
}

// One case: the bytes, the root a reader is told to expect (or none), and what the helper concludes.
static NSDictionary *Case(NSString *name, NSData *bytes, NSData *expectedRoot) {
    NSError *error = nil;
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:bytes expectedRootKey:expectedRoot error:&error];
    NSMutableDictionary *out = [@{@"name" : name, @"chain" : B64(bytes)} mutableCopy];
    if (expectedRoot) out[@"expected_root"] = B64(expectedRoot);
    if (chain == nil) {
        out[@"error"] = ErrorName(error.code);
        return out;
    }
    NSMutableDictionary *devices = [NSMutableDictionary dictionary];
    for (SZFriendsChainDevice *device in chain.devices) devices[Hex(device.deviceKey)] = StateName(device.state);
    out[@"root"] = Hex(chain.rootKey);
    out[@"genesis_hash"] = Hex(chain.genesisHash);
    out[@"link_hashes"] = [chain.links valueForKeyPath:@"linkHash"];
    NSMutableArray *hashes = [NSMutableArray array];
    for (NSData *hash in out[@"link_hashes"]) [hashes addObject:Hex(hash)];
    out[@"link_hashes"] = hashes;
    out[@"devices"] = devices;
    return out;
}

int main(void) {
    @autoreleasepool {
        SZFriendsIdentity *a = Device(0x11), *b = Device(0x22), *c = Device(0x33), *d = Device(0x44);
        NSError *error = nil;
        SZFriendsDeviceChain *genesis = Must([SZFriendsDeviceChain genesisChainWithIdentity:a name:@"Mei's iMac"
                                                                                    system:@"macOS 26.1" date:At(0)
                                                                                     error:&error], error);
        SZFriendsDeviceChain *withB = Add(genesis, b, @"MacBook Air", a, 1);
        SZFriendsDeviceChain *withC = Add(withB, c, @"Mac mini", b, 2);
        SZFriendsDeviceChain *renamed = Must([withC chainByRenamingTo:@"Studio Mac mini" system:@"macOS 26.2"
                                                            signedBy:c date:At(3) error:&error], error);
        // A revokes B after seeing B add C: C stays. A revokes B without having seen it: C is void.
        SZFriendsDeviceChain *revokedSeen = Revoke(withC, b, a, 4);
        SZFriendsDeviceChain *revokedUnseen = Merge(Revoke(withB, b, a, 4), withC);
        // A and B revoke each other on two branches: both end revoked.
        SZFriendsDeviceChain *mutual = Merge(Revoke(withB, b, a, 5), Revoke(withB, a, b, 5));
        // B revokes D, which A added on a branch B saw; A then revokes B on a branch that never saw B's revocation.
        SZFriendsDeviceChain *withD = Add(withB, d, @"Office iMac", a, 6);
        SZFriendsDeviceChain *revenge = Merge(Revoke(withD, b, a, 7), Revoke(withD, d, b, 7));

        NSMutableData *forged = [withB.encodedData mutableCopy];
        ((uint8_t *)forged.mutableBytes)[forged.length - 1] ^= 0x01;
        NSMutableData *cut = [[withB.encodedData subdataWithRange:NSMakeRange(0, withB.encodedData.length - 1)]
            mutableCopy];
        NSMutableData *trailing = [withB.encodedData mutableCopy];
        [trailing appendBytes:"\0" length:1];
        SZFriendsDeviceChain *otherRoot = Must([SZFriendsDeviceChain genesisChainWithIdentity:d name:@"Other"
                                                                                      system:@"macOS 26.1"
                                                                                        date:At(0)
                                                                                       error:&error],
                                               error);

        NSArray *cases = @[
            Case(@"genesis", genesis.encodedData, nil),
            Case(@"add", withB.encodedData, a.publicKey),
            Case(@"add_through_added", withC.encodedData, a.publicKey),
            Case(@"rename", renamed.encodedData, a.publicKey),
            Case(@"revoke_after_seeing", revokedSeen.encodedData, a.publicKey),
            Case(@"revoke_unseen_add_void", revokedUnseen.encodedData, a.publicKey),
            Case(@"mutual_revocation", mutual.encodedData, a.publicKey),
            Case(@"revoked_cannot_take_another", revenge.encodedData, a.publicKey),
            Case(@"forged_signature", forged, a.publicKey),
            Case(@"cut_short", cut, a.publicKey),
            Case(@"bytes_after", trailing, a.publicKey),
            Case(@"wrong_root", otherRoot.encodedData, a.publicKey),
        ];
        NSDictionary *root = @{
            @"comment" : @"Device chains built by the helper's SZFriendsDeviceChain from TEST seeds "
                         @"(seed byte n repeated; static key byte n+0x40). make-chain-vectors.m writes this file.",
            @"seeds" : @{@"a" : @"11", @"b" : @"22", @"c" : @"33", @"d" : @"44"},
            @"keys" : @{@"a" : Hex(a.publicKey), @"b" : Hex(b.publicKey), @"c" : Hex(c.publicKey),
                        @"d" : Hex(d.publicKey)},
            @"cases" : cases,
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:root
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:&error];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
