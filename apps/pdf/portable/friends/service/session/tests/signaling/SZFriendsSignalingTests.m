// Signalling suite (service/session/SZFriendsSignaling.h): the item codec, rendezvous record blobs, Noise IK and NN
// signalling, and download-link payloads. Prints "SZFriendsSignalingTests passed" and exits 0 only when every check
// passed. It links the session sources with the session suite's fakes (tests/SZFriendsFakeIdentity.m and the
// support file), never the identity area.

#import <Foundation/Foundation.h>

#import <sodium.h>

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSignalingTests.h"
#import "service/online/SZFriendsOnlineTransport.h"
#import "service/session/SZFriendsSignaling.h"

static NSData *SZFSTItems(NSArray *items) {
    return SZFriendsEncodeSignalItems(items, SZFriendsSignalPayloadMax, NULL);
}

static NSData *SZFSTRaw(uint8_t type, NSArray<NSArray *> *fields) {
    NSMutableData *value = [NSMutableData data];
    for (NSArray *field in fields) {
        NSData *bytes = field[1];
        uint8_t header[3] = {[field[0] unsignedCharValue], (uint8_t)(bytes.length >> 8), (uint8_t)bytes.length};
        [value appendBytes:header length:3];
        [value appendData:bytes];
    }
    NSMutableData *item = [NSMutableData dataWithBytes:(uint8_t[]){type, (uint8_t)(value.length >> 8),
                                                                    (uint8_t)value.length}
                                                length:3];
    [item appendData:value];
    return item;
}

static void SZFSTItemCodec(void) {
    SZF_CHECK(SZFriendsSignalPayloadMax == SZFriendsOnlineSignalPayloadMax, @"the host's payload limit moved");
    NSData *fingerprint = SZFBytes(0xf1, 32);
    NSArray *items = @[
        [SZFriendsSignalItem descriptionWithConnection:0 kind:1 sdp:@"v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"
                                           fingerprint:fingerprint],
        [SZFriendsSignalItem candidateWithConnection:0 technique:3 line:@"candidate:1 1 UDP 1 192.0.2.1 5 typ srflx"],
        [SZFriendsSignalItem candidatesEndWithConnection:0], [SZFriendsSignalItem natWithClass:2 step:-3],
        [SZFriendsSignalItem startWithConnection:1 kind:3], [SZFriendsSignalItem frameItemWithData:SZFBytes(7, 40)],
        [SZFriendsSignalItem endWithReason:SZFriendsSignalEndDeclined]
    ];
    NSData *encoded = SZFSTItems(items);
    NSArray<SZFriendsSignalItem *> *decoded = SZFriendsDecodeSignalItems(encoded ?: [NSData data], NULL);
    SZF_CHECK(decoded.count == items.count, @"round trip lost items");
    SZF_CHECK([[decoded[0] dataForTag:SZFriendsSignalTagFingerprint] isEqualToData:fingerprint], @"fingerprint");
    SZF_CHECK([[decoded[0] stringForTag:SZFriendsSignalTagSDP] hasPrefix:@"v=0\r\n"], @"sdp");
    uint64_t value = 0;
    SZF_CHECK([decoded[1] getUnsigned:&value forTag:SZFriendsSignalTagTechnique] && value == 3, @"technique");
    SZF_CHECK(decoded[3].natStep == -3, @"a negative step survives");
    SZF_CHECK([[SZFriendsSignalItem natWithClass:1 step:5] dataForTag:SZFriendsSignalTagNATStep] == nil,
              @"an independent NAT sends no step");

    // Later versions' item types and tags are skipped; anything malformed fails the whole payload.
    NSMutableData *future = [SZFSTRaw(200, @[ @[ @1, SZFBytes(1, 4) ] ]) mutableCopy];
    [future appendData:SZFSTRaw(SZFriendsSignalItemEnd, @[ @[ @16, SZFBytes(0, 1) ], @[ @99, SZFBytes(9, 3) ] ])];
    decoded = SZFriendsDecodeSignalItems(future, NULL);
    SZF_CHECK(decoded.count == 1 && decoded[0].type == SZFriendsSignalItemEnd && decoded[0].fields.count == 1,
              @"unknown item or tag not skipped");
    NSDictionary *bad = @{
        @"duplicate tag" : SZFSTRaw(SZFriendsSignalItemEnd, @[ @[ @16, SZFBytes(0, 1) ], @[ @16, SZFBytes(0, 1) ] ]),
        @"short fingerprint" : SZFSTRaw(SZFriendsSignalItemDescription,
                                        @[ @[ @1, SZFBytes(0, 1) ], @[ @2, SZFBytes(1, 1) ], @[ @3, SZFBytes('v', 3) ],
                                           @[ @4, SZFBytes(0, 31) ] ]),
        @"missing field" : SZFSTRaw(SZFriendsSignalItemCandidate, @[ @[ @1, SZFBytes(0, 1) ] ]),
        @"CR LF in a candidate" : SZFSTRaw(SZFriendsSignalItemCandidate,
                                           @[ @[ @1, SZFBytes(0, 1) ], @[ @5, SZFBytes(1, 1) ],
                                              @[ @6, [@"c:1\r\na=x" dataUsingEncoding:NSUTF8StringEncoding] ] ]),
        @"NUL in SDP" : SZFSTRaw(SZFriendsSignalItemDescription,
                                 @[ @[ @1, SZFBytes(0, 1) ], @[ @2, SZFBytes(1, 1) ], @[ @3, SZFBytes(0, 3) ],
                                    @[ @4, SZFBytes(0, 32) ] ]),
        @"truncated" : [SZFSTRaw(SZFriendsSignalItemEnd, @[ @[ @16, SZFBytes(0, 1) ] ])
            subdataWithRange:NSMakeRange(0, 5)],
        @"empty" : [NSData data],
    };
    for (NSString *name in bad) {
        SZF_CHECK(SZFriendsDecodeSignalItems(bad[name], NULL) == nil, @"accepted: %@", name);
    }
    SZF_CHECK(SZFriendsEncodeSignalItems(@[], 100, NULL) == nil, @"no items encoded");
    NSArray *big = @[ [SZFriendsSignalItem frameItemWithData:SZFBytes(1, 200)] ];
    SZF_CHECK(SZFriendsEncodeSignalItems(big, 100, NULL) == nil && SZFriendsEncodeSignalItems(big, 206, NULL),
              @"capacity is not the exact limit");
    SZF_CHECK(SZFriendsEncodeSignalItems(@[ [SZFriendsSignalItem candidateWithConnection:0 technique:1
                                                                                     line:@"a\nb"] ],
                                         100, NULL) == nil,
              @"a control character in a candidate encoded");
    NSDictionary *unknownTag = @{@(SZFriendsSignalTagReason) : SZFBytes(0, 1), @(99) : SZFBytes(0, 1)};
    SZF_CHECK(SZFriendsEncodeSignalItems(@[ [SZFriendsSignalItem itemWithType:SZFriendsSignalItemEnd
                                                                       fields:unknownTag] ],
                                         100, NULL) == nil,
              @"an unknown tag encoded");
}

static void SZFSTRecords(void) {
    // The rendezvous key is the host's (HOST-PROTOCOL-ONLINE.md), here as WebCrypto computes it for 32 bytes of 7.
    SZF_CHECK([SZFHexString(SZFriendsRendezvousKey(SZFBytes(7, 32)))
                  isEqualToString:@"4c7ea6ba418311e32fe91b75699fdb64e806ad72590fb1f9c09627950293788e"],
              @"rendezvous key differs from the host's");
    SZF_CHECK(SZFriendsRendezvousKey(SZFBytes(7, 31)) == nil, @"short key accepted");

    SZFriendsIdentity *alice = [SZFriendsIdentity szf_newIdentity];
    SZFriendsIdentity *mallory = [SZFriendsIdentity szf_newIdentity];
    NSData *secret = SZFRandomBytes(32);
    NSArray *items = @[ [SZFriendsSignalItem natWithClass:SZFriendsSignalNATPerDestination step:2],
                        [SZFriendsSignalItem candidateWithConnection:0 technique:5 line:@"candidate:9 1 UDP 1 x 1"] ];
    NSData *sealed = SZFriendsSealRendezvousRecord(alice, alice.publicKey, secret, 1000, items, NULL);
    SZF_CHECK(sealed.length == 512 && sealed.length == SZFriendsRendezvousSealedLength, @"a record is 512 bytes");
    NSArray *aliceOnly = @[ alice.publicKey ];
    SZFriendsRendezvousRecord *record = SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, secret, aliceOnly, 1000);
    SZF_CHECK([record.deviceKey isEqualToData:alice.publicKey] && record.window == 1000 && record.items.count == 2 &&
                  record.items[0].natStep == 2,
              @"record did not round trip");
    SZF_CHECK(SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, secret, aliceOnly, 999) != nil &&
                  SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, secret, aliceOnly, 1001) != nil,
              @"a neighbouring window must open (clock skew)");
    SZF_CHECK(SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, secret, aliceOnly, 1002) == nil &&
                  SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, secret, aliceOnly, 998) == nil,
              @"a replayed old record opened");
    SZF_CHECK(SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, SZFRandomBytes(32), aliceOnly, 1000) == nil,
              @"opened without the presence secret");
    SZF_CHECK(SZFriendsOpenRendezvousRecord(sealed, mallory.publicKey, secret, @[ mallory.publicKey ], 1000) == nil,
              @"opened under another person's rendezvous key");
    SZF_CHECK(SZFriendsOpenRendezvousRecord(sealed, alice.publicKey, secret, @[ mallory.publicKey ], 1000) == nil,
              @"a device outside the person's keys accepted");
    // A friend holds the secret too, but cannot sign as the person: a record it seals names its own key.
    NSData *forged = SZFriendsSealRendezvousRecord(mallory, alice.publicKey, secret, 1000, items, NULL);
    SZF_CHECK(forged && SZFriendsOpenRendezvousRecord(forged, alice.publicKey, secret, aliceOnly, 1000) == nil,
              @"a record by another key accepted");
    NSMutableData *tampered = [sealed mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[300] ^= 1;
    SZF_CHECK(SZFriendsOpenRendezvousRecord(tampered, alice.publicKey, secret, aliceOnly, 1000) == nil, @"tampered");
    SZF_CHECK(SZFriendsOpenRendezvousRecord(SZFRandomBytes(512), alice.publicKey, secret, aliceOnly, 1000) == nil,
              @"filler opened");
    NSData *empty = SZFriendsSealRendezvousRecord(alice, alice.publicKey, secret, 7, @[], NULL);
    SZF_CHECK(SZFriendsOpenRendezvousRecord(empty, alice.publicKey, secret, aliceOnly, 7).items.count == 0,
              @"an empty body is a valid record (online, no standing candidates)");
    NSArray *tooMuch = @[ [SZFriendsSignalItem frameItemWithData:SZFBytes(1, SZFriendsRendezvousBodyMax)] ];
    SZF_CHECK(SZFriendsSealRendezvousRecord(alice, alice.publicKey, secret, 7, tooMuch, NULL) == nil,
              @"a body over the limit was sealed");
    SZF_CHECK(![SZFriendsSealRendezvousRecord(alice, alice.publicKey, secret, 7, @[], NULL) isEqualToData:empty],
              @"two seals of one record must differ (fresh nonce)");
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) {
            fprintf(stderr, "libsodium failed to initialise\n");
            return 1;
        }
        NSArray *groups = @[
            @[ @"items", ^{ SZFSTItemCodec(); } ], @[ @"records", ^{ SZFSTRecords(); } ],
            @[ @"noise IK", ^{ SZFRunSignalingIKTests(); } ], @[ @"noise NN", ^{ SZFRunSignalingNNTests(); } ],
            @[ @"links", ^{ SZFRunSignalingLinkTests(); } ],
        ];
        for (NSArray *group in groups) {
            int before = SZFTestFailures;
            ((void (^)(void))group[1])();
            printf("  %-10s%s\n", [group[0] UTF8String], SZFTestFailures == before ? "" : "  FAILED");
        }
        if (SZFTestFailures != 0) {
            fprintf(stderr, "SZFriendsSignalingTests: %d check(s) failed\n", SZFTestFailures);
            return 1;
        }
        printf("SZFriendsSignalingTests passed\n");
        return 0;
    }
}
