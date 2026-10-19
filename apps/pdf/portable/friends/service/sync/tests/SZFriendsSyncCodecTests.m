// friends-sync-check: events, fields and vectors on the wire. A signed event verifies under its root and author and
// under nothing else, every single-byte change to a header is refused, a body that does not match its digest is
// refused (a missing one is not), and fields and vectors have one encoding each.

#import "SZFriendsSyncTestSupport.h"

static NSData *SZFSRoot32(uint8_t byte) {
    NSMutableData *data = [NSMutableData dataWithLength:32];
    memset(data.mutableBytes, byte, 32);
    return data;
}

static void TestFieldsRoundTrip(void) {
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:@"Mei 梅" forTag:2];
    [fields setUInt64:UINT64_MAX forTag:9];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1760400000.123456789];
    [fields setDate:date forTag:4];
    [fields setData:[NSData data] forTag:7];
    SZFriendsSyncFields *back = [SZFriendsSyncFields fieldsWithData:fields.encodedData];
    SZFSExpect([[back stringForTag:2] isEqualToString:@"Mei 梅"], @"string");
    SZFSExpect([back uint64ForTag:9] == UINT64_MAX, @"u64");
    SZFSExpect([[back dateForTag:4] isEqualToDate:date], @"a date comes back to the same double");
    SZFSExpect([back hasTag:7] && [back dataForTag:7].length == 0 && ![back hasTag:3], @"empty value vs absent");
    // Tags out of order, repeated, or a length past the end: refused.
    uint8_t descending[] = {3, 0, 1, 'a', 2, 0, 1, 'b'};
    uint8_t repeated[] = {2, 0, 1, 'a', 2, 0, 1, 'b'};
    uint8_t overrun[] = {2, 0, 9, 'a'};
    uint8_t truncated[] = {2, 0};
    for (NSData *bad in @[ [NSData dataWithBytes:descending length:8], [NSData dataWithBytes:repeated length:8],
                           [NSData dataWithBytes:overrun length:4], [NSData dataWithBytes:truncated length:2] ]) {
        SZFSExpect([SZFriendsSyncFields fieldsWithData:bad] == nil, @"malformed fields refused: %@", bad);
    }
}

static void TestEventSignatures(void) {
    SZFriendsIdentity *author = SZFSIdentity(7), *other = SZFSIdentity(8);
    NSData *root = SZFSRoot32(0x11);
    NSData *body = [@"hello" dataUsingEncoding:NSUTF8StringEncoding];
    SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventSignedBy:author rootKey:root kind:SZFriendsSyncKindItem seq:3
                                                          lamport:9 date:[NSDate dateWithTimeIntervalSince1970:5]
                                                            scope:@"k:abcd" subject:@"item-1" body:body];
    SZFSExpect(event.seq == 3 && event.lamport == 9 && [event.author isEqualToData:author.publicKey], @"fields");
    SZFSExpect([event.scope isEqualToString:@"k:abcd"] && [event.subject isEqualToString:@"item-1"], @"labels");
    NSError *error = nil;
    SZFriendsSyncEvent *again = [SZFriendsSyncEvent eventWithHeader:event.header body:body rootKey:root error:&error];
    SZFSExpect(again != nil && [again.body isEqualToData:body], @"verifies: %@", error);
    // Another person's root: the same bytes are not an event of theirs.
    SZFSExpect([SZFriendsSyncEvent eventWithHeader:event.header body:body rootKey:SZFSRoot32(0x12)
                                             error:&error] == nil &&
                   error.code == SZFriendsSyncErrorForged,
               @"bound to the root");
    // A body that is not the one signed.
    NSData *otherBody = [@"hellp" dataUsingEncoding:NSUTF8StringEncoding];
    SZFSExpect([SZFriendsSyncEvent eventWithHeader:event.header body:otherBody rootKey:root error:&error] == nil &&
                   error.code == SZFriendsSyncErrorForged,
               @"body bound to the header");
    // No body (a deletion dropped it): the header still verifies.
    SZFriendsSyncEvent *bodiless = [SZFriendsSyncEvent eventWithHeader:event.header body:nil rootKey:root error:NULL];
    SZFSExpect(bodiless != nil && bodiless.body == nil, @"a dropped body keeps a verifiable header");
    // Every single-byte change to the header is refused, as malformed or forged.
    NSUInteger refused = 0;
    for (NSUInteger i = 0; i < event.header.length; i++) {
        NSMutableData *changed = [event.header mutableCopy];
        ((uint8_t *)changed.mutableBytes)[i] ^= 0x01;
        if ([SZFriendsSyncEvent eventWithHeader:changed body:body rootKey:root error:NULL] == nil) refused++;
    }
    SZFSExpect(refused == event.header.length, @"%lu of %lu changed headers refused", (unsigned long)refused,
               (unsigned long)event.header.length);
    // Signed by someone else under the author's name: swap the author bytes for another key.
    NSMutableData *claimed = [event.header mutableCopy];
    [claimed replaceBytesInRange:NSMakeRange(2, 32) withBytes:other.publicKey.bytes];
    SZFSExpect([SZFriendsSyncEvent eventWithHeader:claimed body:body rootKey:root error:NULL] == nil,
               @"claimed author");
    SZFSExpect([SZFriendsSyncEvent eventWithHeader:[NSData data] body:nil rootKey:root error:&error] == nil &&
                   error.code == SZFriendsSyncErrorMalformed,
               @"empty header");
}

static void TestVectors(void) {
    NSData *a = SZFSRoot32(1), *b = SZFSRoot32(2);
    SZFriendsSyncVector *vector = @{b : @7, a : @3};
    NSData *encoded = SZFriendsSyncEncodeVector(vector);
    NSUInteger consumed = 0;
    SZFriendsSyncVector *back = SZFriendsSyncDecodeVector(encoded, &consumed);
    SZFSExpect([back isEqualToDictionary:vector] && consumed == encoded.length, @"round trip");
    SZFSExpect(SZFriendsSyncVectorCovers(vector, a, 3) && !SZFriendsSyncVectorCovers(vector, a, 4) &&
                   !SZFriendsSyncVectorCovers(vector, SZFSRoot32(3), 1),
               @"covers");
    // Authors out of order, or an empty entry: not the one encoding of any vector.
    NSMutableData *swapped = [NSMutableData dataWithBytes:(uint8_t[]){0, 2} length:2];
    [swapped appendData:b];
    SZFriendsSyncPutU64(swapped, 7);
    [swapped appendData:a];
    SZFriendsSyncPutU64(swapped, 3);
    SZFSExpect(SZFriendsSyncDecodeVector(swapped, NULL) == nil, @"descending authors refused");
    NSMutableData *zero = [NSMutableData dataWithBytes:(uint8_t[]){0, 1} length:2];
    [zero appendData:a];
    SZFriendsSyncPutU64(zero, 0);
    SZFSExpect(SZFriendsSyncDecodeVector(zero, NULL) == nil, @"zero entries refused");
    SZFSExpect(SZFriendsSyncDecodeVector([encoded subdataWithRange:NSMakeRange(0, encoded.length - 1)], NULL) == nil,
               @"truncated refused");
}

static void TestCopyPolicy(void) {
    SZFSExpect(SZFriendsSyncCopiesAutomatically(25000000, @"abc"), @"25 MB copies by itself");
    SZFSExpect(!SZFriendsSyncCopiesAutomatically(25000001, @"abc"), @"larger waits for Get");
    SZFSExpect(SZFriendsSyncCopiesAutomatically(4000000000ull, SZFriendsYouConversationID), @"You copies any size");
}

static void TestDeviceTagSecrets(void) {
    NSData *secret = SZFSRoot32(0x21), *laptop = SZFSRoot32(0x31), *desktop = SZFSRoot32(0x32);
    NSData *forLaptop = SZFriendsSyncDeviceTagSecret(secret, laptop);
    SZFSExpect(forLaptop.length == 32 && [forLaptop isEqualToData:SZFriendsSyncDeviceTagSecret(secret, laptop)],
               @"each device has one");
    SZFSExpect(![forLaptop isEqualToData:SZFriendsSyncDeviceTagSecret(secret, desktop)] &&
                   ![forLaptop isEqualToData:SZFriendsSyncDeviceTagSecret(SZFSRoot32(0x22), laptop)] &&
                   ![forLaptop isEqualToData:secret],
               @"per device, per profile, never the secret itself");
    SZFSExpect(SZFriendsSyncDeviceTagSecret([NSData data], laptop) == nil, @"no secret, no tags");
    NSData *forFriends = SZFriendsSyncFriendDeviceTagSecret(secret, laptop);
    SZFSExpect(forFriends.length == 32 && ![forFriends isEqualToData:forLaptop],
               @"what friends match is not what our own devices match, from the same secret");
}

void SZFSRunCodecTests(void) {
    TestDeviceTagSecrets();
    TestFieldsRoundTrip();
    TestEventSignatures();
    TestVectors();
    TestCopyPolicy();
}
