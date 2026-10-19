// Payloads, keys, setup payloads, records and metadata (SZFriendsLinkWire.h).

#import "SZFLinksTestSupport.h"

#import "service/identity/SZFriendsIdentity.h"

static NSData *Hex(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int byte = 0;
        sscanf([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, "%2x", &byte);
        uint8_t value = (uint8_t)byte;
        [data appendBytes:&value length:1];
    }
    return data;
}

static NSString *DownloadPayload(NSData *bytes) {
    return [@"d." stringByAppendingString:SZFriendsLinkBase64URLEncode(bytes)];
}

// The payloads PROTOCOL.md's own examples carry (fixtures/intents.jsonl) are what the apps send.
static void TestTheProtocolExamplesParse(void) {
    SZFriendsFriendLinkPayload *friend = SZFriendsParseLinkPayload(
        @"f.AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0OqyMnKy8zNzs_Q0dLT1NXW1w1ib25maXJlLW90dGVyCExlbyBQYXJr");
    SZFL_CHECK([friend isKindOfClass:[SZFriendsFriendLinkPayload class]], @"%@", friend);
    SZFL_CHECK([friend.friendsID isEqualToString:@"bonfire-otter"] && [friend.name isEqualToString:@"Leo Park"],
               @"%@ %@", friend.friendsID, friend.name);
    SZFL_CHECK(friend.identityKey.length == 32 && friend.inviteToken.length == 16, @"lengths");
    SZFriendsDownloadLinkPayload *download =
        SZFriendsParseLinkPayload(@"d.ARAREhMUFRYXGBkaGxwdHh9kZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5_gIGCgw");
    SZFL_CHECK([download.linkID isEqualToData:Hex(@"101112131415161718191a1b1c1d1e1f")], @"%@", download.linkID);
    SZFL_CHECK(download.secret.length == 32, @"secret");
    SZFL_CHECK([[download payloadString] isEqualToString:@"d.ARAREhMUFRYXGBkaGxwdHh9kZWZnaGlqa2xtbm9wcXJzdHV2d3h5"
                                                          @"ent8fX5_gIGCgw"],
               @"%@", [download payloadString]);
    SZFL_CHECK([[friend payloadString] hasPrefix:@"f.AbTd"], @"round trip");
}

// The one rule for download payloads, shared with the link page and ShenzhenPDF's URL check (run from portable/).
static void TestDownloadPayloadsFollowTheSharedFixture(void) {
    NSData *json = [NSData dataWithContentsOfFile:@"friends/service/links/tests/download-payloads.json"];
    NSDictionary *fixture = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    SZFL_CHECK([fixture[@"accepted"] count] > 0 && [fixture[@"refused"] count] > 0, @"the fixture is there");
    for (NSString *payload in fixture[@"accepted"]) {
        SZFL_CHECK([SZFriendsParseLinkPayload(payload) isKindOfClass:[SZFriendsDownloadLinkPayload class]],
                   @"refused %@", payload);
    }
    for (NSDictionary *refused in fixture[@"refused"]) {
        SZFL_CHECK(SZFriendsParseLinkPayload(refused[@"payload"]) == nil, @"accepted: %@", refused[@"why"]);
    }
}

static void TestMalformedPayloadsAreRefused(void) {
    NSMutableData *good = [Hex(@"01") mutableCopy];
    [good appendData:SZFLRandom(48)];
    SZFL_CHECK(SZFriendsParseLinkPayload(DownloadPayload(good)) != nil, @"49 bytes");
    NSMutableData *longer = [good mutableCopy];
    [longer appendData:Hex(@"00")];
    NSMutableData *version = [good mutableCopy];
    ((uint8_t *)version.mutableBytes)[0] = 2;
    NSArray *refused = @[
        DownloadPayload(longer), DownloadPayload([good subdataWithRange:NSMakeRange(0, 48)]), DownloadPayload(version),
        [@"x." stringByAppendingString:SZFriendsLinkBase64URLEncode(good)],
        [@"d" stringByAppendingString:SZFriendsLinkBase64URLEncode(good)],
        [DownloadPayload(good) stringByAppendingString:@"="], [DownloadPayload(good) stringByAppendingString:@"A"],
        @"d.AB", @"", @42, [@"f." stringByPaddingToLength:600 withString:@"A" startingAtIndex:0]
    ];
    for (id payload in refused) SZFL_CHECK(SZFriendsParseLinkPayload(payload) == nil, @"accepted %@", payload);
    // Unused trailing bits must be zero: "AB" decodes to one byte only when its last four bits are.
    SZFL_CHECK(SZFriendsLinkBase64URLDecode(@"AB") == nil && SZFriendsLinkBase64URLDecode(@"AA").length == 1,
               @"canonical base64url");
    SZFriendsFriendLinkPayload *friend = [SZFriendsFriendLinkPayload new];
    friend.identityKey = SZFLRandom(32);
    friend.inviteToken = SZFLRandom(16);
    friend.friendsID = @"brave-otter";
    friend.name = @"Mei";
    SZFL_CHECK([friend payloadString] != nil, @"a valid friend link");
    for (NSString *badID in @[ @"Brave-otter", @"brave--otter", @"-brave", @"br", @"brave otter" ]) {
        friend.friendsID = badID;
        SZFL_CHECK([friend payloadString] == nil, @"ID %@", badID);
    }
    friend.friendsID = @"brave-otter";
    friend.name = @"Mei\nWong";
    SZFL_CHECK([friend payloadString] == nil, @"a control character in the name");
    friend.name = [@"" stringByPaddingToLength:161 withString:@"m" startingAtIndex:0];
    SZFL_CHECK([friend payloadString] == nil, @"a name over 160 bytes");
}

static void TestWebURLs(void) {
    NSString *payload = @"d.ARAREhMUFRYXGBkaGxwdHh9kZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5_gIGCgw";
    SZFL_CHECK([SZFriendsLinkWebURL(@"https://friends.example", payload)
                   isEqualToString:@"https://friends.example/d#ARAREhMUFRYXGBkaGxwdHh9kZWZnaGlqa2xtbm9wcXJzdHV2d3h5en"
                                   @"t8fX5_gIGCgw"],
               @"page link");
    for (NSString *origin in @[ @"https://friends.example/x", @"ftp://friends.example", @"https://", @"nonsense" ]) {
        SZFL_CHECK(SZFriendsLinkWebURL(origin, payload) == nil, @"origin %@", origin);
    }
}

static void TestSetupPayloadsBindKeyDirectionAndSession(void) {
    NSData *linkID = SZFLRandom(16), *secret = SZFLRandom(32);
    SZFriendsLinkKeys *opener = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:secret];
    SZFriendsLinkKeys *sender = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:secret];
    SZFriendsLinkKeys *stranger = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:SZFLRandom(32)];
    NSData *hello = [opener sealMessage:@{@"t" : @"hello", @"v" : @1} from:SZFriendsLinkSideOpener];
    SZFL_CHECK([[sender openPayload:hello from:SZFriendsLinkSideOpener][@"t"] isEqual:@"hello"], @"opens");
    SZFL_CHECK([sender openPayload:hello from:SZFriendsLinkSideSender] == nil, @"never in the other direction");
    SZFL_CHECK([stranger openPayload:hello from:SZFriendsLinkSideOpener] == nil, @"never without the secret");
    NSData *on = SZFLRandom(16), *sn = SZFLRandom(16);
    [opener setOpenerNonce:on senderNonce:sn];
    [sender setOpenerNonce:on senderNonce:sn];
    NSData *proof = [opener sealMessage:@{@"t" : @"proof"} from:SZFriendsLinkSideOpener];
    SZFL_CHECK([sender openPayload:proof from:SZFriendsLinkSideOpener] != nil, @"session payloads open");
    SZFL_CHECK([stranger openPayload:proof from:SZFriendsLinkSideOpener] == nil, @"not under the setup key");
    SZFL_CHECK([sender verifyProof:[opener proof]] && ![sender verifyProof:SZFLRandom(32)], @"proof");
    SZFriendsLinkKeys *replayed = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:secret];
    [replayed setOpenerNonce:on senderNonce:SZFLRandom(16)];
    SZFL_CHECK(![replayed verifyProof:[opener proof]], @"a proof for another challenge");
    SZFL_CHECK(![[sender contentKeyForAttempt:1] isEqualToData:[sender contentKeyForAttempt:2]] &&
                   [[sender contentKeyForAttempt:1] isEqualToData:[opener contentKeyForAttempt:1]],
               @"one content key per attempt");
}

static void TestRecordsOpenOnlyInPlace(void) {
    NSData *key = SZFLRandom(32), *plain = SZFLRandom(1000);
    NSData *chunk = SZFriendsLinkSealRecord(key, SZFriendsLinkRecordChunk, 3, plain);
    NSArray *chunks = @[ @(SZFriendsLinkRecordChunk), @(SZFriendsLinkRecordFinal) ];
    SZFriendsLinkRecordType type = 0;
    SZFL_CHECK([SZFriendsLinkOpenRecord(key, chunks, 3, chunk, &type) isEqualToData:plain] &&
                   type == SZFriendsLinkRecordChunk,
               @"opens at its index");
    SZFL_CHECK(SZFriendsLinkOpenRecord(key, chunks, 4, chunk, NULL) == nil, @"a repeated or dropped record");
    NSMutableData *relabelled = [chunk mutableCopy];
    ((uint8_t *)relabelled.mutableBytes)[0] = SZFriendsLinkRecordFinal;
    SZFL_CHECK(SZFriendsLinkOpenRecord(key, chunks, 3, relabelled, NULL) == nil, @"a chunk relabelled final");
    NSMutableData *tampered = [chunk mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[500] ^= 1;
    SZFL_CHECK(SZFriendsLinkOpenRecord(key, chunks, 3, tampered, NULL) == nil, @"a tampered chunk");
    SZFL_CHECK(SZFriendsLinkSealRecord(key, SZFriendsLinkRecordChunk, 0, SZFLRandom(SZFriendsLinkChunkBytes)).length <=
                   SZFriendsLinkRecordMax,
               @"a full chunk fits one data-channel message");
    SZFL_CHECK(SZFriendsLinkSealRecord(key, SZFriendsLinkRecordChunk, 0, SZFLRandom(65536)) == nil, @"too long");
}

static void TestMetadataRoundTripAndSender(void) {
    SZFriendsIdentity *identity = [SZFriendsIdentity identityWithSigningSeed:SZFLRandom(32)
                                                            staticPrivateKey:SZFLRandom(32)];
    NSData *linkID = SZFLRandom(16);
    SZFriendsLinkMetadata *metadata = [SZFriendsLinkMetadata new];
    metadata.name = @"Site photos.pdf";
    metadata.size = 5000000000ULL; // past 4 GB: no 32-bit sizes
    metadata.mediaType = @"application/pdf";
    metadata.sha256 = SZFLRandom(32);
    metadata.blake2b = SZFLRandom(32);
    metadata.senderName = @"Mei";
    metadata.senderFriendsID = @"brave-otter";
    metadata.senderIdentityKey = identity.publicKey;
    metadata.senderSignature = [identity signatureForMessage:[metadata signedBytesForLinkID:linkID]
                                                      domain:@"SZFriends link sender v1"];
    SZFriendsLinkMetadata *read = [SZFriendsLinkMetadata metadataFromRecordPlaintext:[metadata recordPlaintext]];
    SZFL_CHECK(read.size == 5000000000ULL && [read.name isEqualToString:metadata.name] &&
                   [read.sha256 isEqualToData:metadata.sha256] && [read.senderName isEqualToString:@"Mei"],
               @"round trip");
    SZFL_CHECK([SZFriendsIdentity verifySignature:read.senderSignature
                                       forMessage:[read signedBytesForLinkID:linkID]
                                           domain:@"SZFriends link sender v1"
                                        publicKey:read.senderIdentityKey],
               @"the sender's signature verifies after the round trip");
    read.name = @"Other.pdf";
    SZFL_CHECK(![SZFriendsIdentity verifySignature:read.senderSignature
                                        forMessage:[read signedBytesForLinkID:linkID]
                                            domain:@"SZFriends link sender v1"
                                         publicKey:read.senderIdentityKey],
               @"a renamed file does not");
    NSMutableData *png = [Hex(@"89504e470d0a1a0a") mutableCopy];
    [png appendData:SZFLRandom(70000)];
    metadata.thumbnailPNG = png;
    NSData *plain = [metadata recordPlaintext];
    SZFL_CHECK(plain.length < 70000 && [SZFriendsLinkMetadata metadataFromRecordPlaintext:plain].thumbnailPNG == nil,
               @"a thumbnail too large for the record is left out");
}

void SZFLRunWireTests(void) {
    TestDownloadPayloadsFollowTheSharedFixture();
    TestTheProtocolExamplesParse();
    TestMalformedPayloadsAreRefused();
    TestWebURLs();
    TestSetupPayloadsBindKeyDirectionAndSession();
    TestRecordsOpenOnlyInPlace();
    TestMetadataRoundTripAndSender();
}
