// friends-discovery-check, pure and scripted part: presence and callback tags, route racing, the visibility
// deadline, the merger, the coordinator, the Bluetooth adapter over a fake radio, streams and TXT records.

#import "SZFriendsDiscoveryTestSupport.h"

#include <sodium.h>

// Known answers computed independently with Python's hashlib (CPython's own BLAKE2 code, not libsodium):
//   hashlib.blake2b(b"SZFriends presence v1" + struct.pack(">Q", w & (2**64 - 1)), digest_size=32,
//                   key=secret).digest()[:8]
// s1 = bytes(range(32)), s2 = bytes([0xa5] * 32); window 1990875 holds the fixture clock 2026-10-12T06:47:48Z.
static void TestPresenceVectors(void) {
    NSMutableData *s1 = [NSMutableData dataWithLength:32];
    for (uint8_t i = 0; i < 32; i++) ((uint8_t *)s1.mutableBytes)[i] = i;
    NSData *s2 = SZFTestSecret(0xa5);
    struct {
        NSData *secret;
        int64_t window;
        NSString *tag;
    } vectors[] = {
        {s1, 0, @"8c40db5fd3de4fdd"},       {s1, 1, @"02af8b7613c44e03"},  {s1, 1990875, @"8b5e551074edcea8"},
        {s1, -1, @"ecd70b0b6cdd7638"},      {s2, 0, @"8229adfa78a3b3eb"},  {s2, 1, @"0a60a40fe6137a61"},
        {s2, 1990875, @"3a20b2e6ac251f60"}, {s2, -1, @"9dec8202e3377ecf"},
    };
    for (size_t i = 0; i < sizeof vectors / sizeof vectors[0]; i++) {
        NSData *tag = SZFriendsPresenceTag(vectors[i].secret, vectors[i].window);
        CHECK([tag isEqual:SZFTestData(vectors[i].tag)], "vector %zu: %@", i, SZFriendsHexFromData(tag));
    }
    // An 8-byte-output BLAKE2b is a different function (output length is a parameter): 3011a9994a4d82ca.
    CHECK(![SZFriendsPresenceTag(s1, 0) isEqual:SZFTestData(@"3011a9994a4d82ca")]);
}

static void TestPresenceWindows(void) {
    CHECK(SZFriendsPresenceWindowIndex(SZFTestDate(0)) == 0);
    CHECK(SZFriendsPresenceWindowIndex(SZFTestDate(899.999)) == 0);
    CHECK(SZFriendsPresenceWindowIndex(SZFTestDate(900)) == 1);
    CHECK(SZFriendsPresenceWindowIndex(SZFTestDate(-0.5)) == -1, "floor, not truncation, before 1970");
    CHECK(SZFriendsPresenceWindowIndex(SZFTestDate(1791787668)) == 1990875, "fixture clock");
    CHECK([SZFriendsPresenceWindowEnd(SZFTestDate(1791787668)) isEqual:SZFTestDate(1990876.0 * 900)]);
    CHECK([SZFriendsPresenceWindowEnd(SZFTestDate(900)) isEqual:SZFTestDate(1800)], "a boundary starts a window");

    NSData *secret = SZFTestSecret(7);
    NSDate *now = SZFTestDate(1990875.0 * 900 + 10);
    NSArray<NSData *> *tags = SZFriendsPresenceTagsToMatch(secret, now);
    CHECK(tags.count == 3);
    CHECK([tags[0] isEqual:SZFriendsPresenceTag(secret, 1990874)] &&
          [tags[1] isEqual:SZFriendsPresenceTag(secret, 1990875)] &&
          [tags[2] isEqual:SZFriendsPresenceTag(secret, 1990876)]);
    // A friend whose clock runs up to 15 minutes either way is still recognised; two windows away is not.
    NSData *advertised = SZFriendsPresenceTag(secret, 1990875);
    CHECK([SZFriendsPresenceTagsToMatch(secret, SZFTestDate(1990876.0 * 900 + 899)) containsObject:advertised]);
    CHECK(![SZFriendsPresenceTagsToMatch(secret, SZFTestDate(1990877.0 * 900)) containsObject:advertised]);
    CHECK([SZFriendsPresenceTagsToMatch(secret, SZFTestDate(1990874.0 * 900)) containsObject:advertised]);
    CHECK(![SZFriendsPresenceTagsToMatch(secret, SZFTestDate(1990873.0 * 900 + 899)) containsObject:advertised]);
    CHECK(![SZFriendsPresenceTag(secret, 1990875) isEqual:SZFriendsPresenceTag(secret, 1990876)], "tags rotate");
}

static void TestTagMatcher(void) {
    NSDate *now = SZFTestDate(1791787668);
    int64_t w = SZFriendsPresenceWindowIndex(now);
    NSData *mei = SZFTestSecret(1), *kenji = SZFTestSecret(2), *callback = SZFTestSecret(3);
    SZFriendsTagMatcher matcher = SZFriendsMakeTagMatcher(@{@"mei" : @[ mei ], @"kenji" : @[ kenji, callback ]}, now);
    CHECK([matcher(SZFriendsPresenceTag(mei, w)) isEqual:@"mei"]);
    CHECK([matcher(SZFriendsPresenceTag(mei, w + 1)) isEqual:@"mei"]);
    CHECK([matcher(SZFriendsPresenceTag(kenji, w - 1)) isEqual:@"kenji"]);
    CHECK([matcher(SZFriendsPresenceTag(callback, w)) isEqual:@"kenji"], "callback secrets map to their request");
    CHECK(matcher(SZFriendsPresenceTag(mei, w + 2)) == nil);
    CHECK(matcher(SZFriendsPresenceTag(SZFTestSecret(9), w)) == nil, "no match across identities");
    // Rotation after a remove or block: tags of the dead secret match nobody once the matcher is rebuilt.
    NSData *rotated = SZFriendsNewPresenceSecret();
    SZFriendsTagMatcher after = SZFriendsMakeTagMatcher(@{@"mei" : @[ rotated ]}, now);
    CHECK(after(SZFriendsPresenceTag(mei, w)) == nil);
    CHECK([after(SZFriendsPresenceTag(rotated, w)) isEqual:@"mei"]);
    CHECK(after(SZFriendsPresenceTag(kenji, w)) == nil, "a removed person is simply left out");
    CHECK(SZFriendsMakeTagMatcher(
              @{@"bad" : @[ [NSData dataWithBytes:"x" length:1] ]}, now)(SZFriendsPresenceTag(mei, w)) == nil);

    NSData *a = SZFriendsNewPresenceSecret(), *b = SZFriendsNewPresenceSecret();
    CHECK(a.length == 32 && b.length == 32 && ![a isEqual:b]);
    // A malformed secret never yields a fixed, guessable tag.
    NSData *short1 = SZFriendsPresenceTag([NSData data], w), *short2 = SZFriendsPresenceTag([NSData data], w);
    CHECK(short1.length == 8 && ![short1 isEqual:short2]);
}

static void TestCallbackTags(void) {
    NSDate *now = SZFTestDate(1791787668);
    int64_t w = SZFriendsPresenceWindowIndex(now);
    NSTimeInterval day = 86400;
    NSMutableArray<SZFriendsPendingCallback *> *pending = [NSMutableArray array];
    // Six requests, created 1..6 hours ago, all valid for 7 days.
    for (int i = 1; i <= 6; i++) {
        NSDate *created = [now dateByAddingTimeInterval:-3600.0 * i];
        [pending addObject:[[SZFriendsPendingCallback alloc]
                               initWithCallbackSecret:SZFTestSecret((uint8_t)(0x10 + i))
                                            createdAt:created
                                            expiresAt:[created dateByAddingTimeInterval:7 * day]]];
    }
    NSArray<NSData *> *tags = SZFriendsCallbackTagsToAdvertise(pending, now);
    CHECK(tags.count == 4, "at most 4 on the air: %lu", (unsigned long)tags.count);
    CHECK([tags[0] isEqual:SZFriendsPresenceTag(SZFTestSecret(0x11), w)], "newest first");
    CHECK([tags[3] isEqual:SZFriendsPresenceTag(SZFTestSecret(0x14), w)]);

    NSDate *old = [now dateByAddingTimeInterval:-7 * day];
    NSDate *recent = [now dateByAddingTimeInterval:-60]; // a fresh secret, broadcast a minute ago
    NSArray<SZFriendsPendingCallback *> *edge = @[
        // Exactly 7 days old: expired, even though the row claims a later expiry.
        [[SZFriendsPendingCallback alloc] initWithCallbackSecret:SZFTestSecret(0x21)
                                                       createdAt:old
                                                       expiresAt:[now dateByAddingTimeInterval:day]
                                                  secretIssuedAt:recent
                                                 lastBroadcastAt:recent],
        // Past its own expiresAt.
        [[SZFriendsPendingCallback alloc] initWithCallbackSecret:SZFTestSecret(0x22)
                                                       createdAt:[now dateByAddingTimeInterval:-day]
                                                       expiresAt:now
                                                  secretIssuedAt:recent
                                                 lastBroadcastAt:recent],
        // One second before 7 days: still live.
        [[SZFriendsPendingCallback alloc] initWithCallbackSecret:SZFTestSecret(0x23)
                                                       createdAt:[old dateByAddingTimeInterval:1]
                                                       expiresAt:[now dateByAddingTimeInterval:1]
                                                  secretIssuedAt:recent
                                                 lastBroadcastAt:recent],
        [[SZFriendsPendingCallback alloc] initWithCallbackSecret:[NSData data] createdAt:now expiresAt:now],
    ];
    NSArray<NSData *> *edgeTags = SZFriendsCallbackTagsToAdvertise(edge, now);
    CHECK(edgeTags.count == 1 && [edgeTags[0] isEqual:SZFriendsPresenceTag(SZFTestSecret(0x23), w)]);
    CHECK(SZFriendsCallbackTagsToAdvertise(@[], now).count == 0);
}

// Review finding "callback tags": a callback secret reaches every nearby device, which could follow the requester for
// the request's 7 days. Tags now go out only for 6 hours after each broadcast, and each secret lasts a day before a
// fresh one is broadcast.
static void TestCallbackExposure(void) {
    NSDate *now = SZFTestDate(1791787668);
    NSTimeInterval hour = 3600, day = 86400;
    NSDate *created = [now dateByAddingTimeInterval:-2 * day];
    SZFriendsPendingCallback * (^request)(NSTimeInterval, NSTimeInterval) = ^(NSTimeInterval issued,
                                                                             NSTimeInterval broadcast) {
        return [[SZFriendsPendingCallback alloc] initWithCallbackSecret:SZFTestSecret(0x31)
                                                              createdAt:created
                                                              expiresAt:[created dateByAddingTimeInterval:7 * day]
                                                         secretIssuedAt:[now dateByAddingTimeInterval:issued]
                                                        lastBroadcastAt:isnan(broadcast)
                                                                            ? nil
                                                                            : [now dateByAddingTimeInterval:broadcast]];
    };
    CHECK(SZFriendsCallbackAdvertiseWindow == 6 * hour && SZFriendsCallbackSecretLifetime == day);
    CHECK(SZFriendsCallbackTagsToAdvertise(@[ request(-hour, -hour) ], now).count == 1, "broadcast an hour ago");
    CHECK(SZFriendsCallbackTagsToAdvertise(@[ request(-7 * hour, -6 * hour) ], now).count == 0,
          "six hours after the last broadcast: off the air, although the request lasts days more");
    CHECK(SZFriendsCallbackTagsToAdvertise(@[ request(-7 * hour, -6 * hour + 1) ], now).count == 1);
    CHECK(SZFriendsCallbackTagsToAdvertise(@[ request(-hour, NAN) ], now).count == 0,
          "never broadcast: nobody could match it, so nothing goes out");
    CHECK(SZFriendsCallbackTagsToAdvertise(@[ request(-day, -60) ], now).count == 0,
          "a day-old secret is retired even while broadcasts continue");

    // Daily rebroadcast with a fresh secret.
    CHECK(!SZFriendsCallbackNeedsFreshSecret(request(-day + 1, -60), now));
    CHECK(SZFriendsCallbackNeedsFreshSecret(request(-day, -60), now));
    SZFriendsPendingCallback *over = [[SZFriendsPendingCallback alloc]
        initWithCallbackSecret:SZFTestSecret(0x32)
                     createdAt:[now dateByAddingTimeInterval:-8 * day]
                     expiresAt:[now dateByAddingTimeInterval:-day]
                secretIssuedAt:[now dateByAddingTimeInterval:-2 * day]
               lastBroadcastAt:nil];
    CHECK(!SZFriendsCallbackNeedsFreshSecret(over, now), "an expired request is not renewed");

    // The next change: the advertise window, the secret's day or the request's end, whichever comes first.
    CHECK([SZFriendsCallbackNextChange(@[ request(-hour, -hour) ], now)
        isEqual:[now dateByAddingTimeInterval:5 * hour]]);
    CHECK([SZFriendsCallbackNextChange(@[ request(-20 * hour, -60) ], now)
        isEqual:[now dateByAddingTimeInterval:4 * hour]]);
    CHECK([SZFriendsCallbackNextChange(@[ request(-hour, -hour), request(-23 * hour, -60) ], now)
        isEqual:[now dateByAddingTimeInterval:hour]]);
    CHECK(SZFriendsCallbackNextChange(@[ over ], now) == nil && SZFriendsCallbackNextChange(@[], now) == nil);

    // The convenience initializer counts the secret as drawn and broadcast when the request was made.
    SZFriendsPendingCallback *plain = [[SZFriendsPendingCallback alloc] initWithCallbackSecret:SZFTestSecret(0x33)
                                                                                     createdAt:now
                                                                                     expiresAt:now];
    CHECK([plain.secretIssuedAt isEqual:now] && [plain.lastBroadcastAt isEqual:now]);
}

static void TestCallbackSlots(void) {
    SZFriendsCallbackSlots *slots = [SZFriendsCallbackSlots new];
    NSData *a = SZFTestData(@"0a0a0a0a0a0a0a0a"), *b = SZFTestData(@"0b0b0b0b0b0b0b0b");
    NSArray<NSData *> *none = [slots slotsForTags:@[] rotationKey:@1];
    CHECK(none.count == SZFriendsCallbackTagsMax, "exactly 4 slots with no request pending");
    for (NSData *slot in none) CHECK(slot.length == SZFriendsPresenceTagLength);
    CHECK([[slots slotsForTags:@[] rotationKey:@1] isEqual:none], "padding is stable within a window");
    NSArray<NSData *> *one = [slots slotsForTags:@[ a ] rotationKey:@1];
    NSUInteger changed = 0;
    for (NSUInteger i = 0; i < one.count; i++) changed += ![one[i] isEqual:none[i]];
    CHECK([one containsObject:a] && changed == 1, "a new request takes one padding slot, the rest stay");
    NSArray<NSData *> *two = [slots slotsForTags:@[ b, a ] rotationKey:@1];
    CHECK([two indexOfObject:a] == [one indexOfObject:a] && [two containsObject:b], "a real tag keeps its slot");
    NSArray<NSData *> *back = [slots slotsForTags:@[ b ] rotationKey:@1];
    CHECK(![back containsObject:a] && [back indexOfObject:b] == [two indexOfObject:b] && back.count == 4,
          "an ended request's slot becomes fresh padding");
    NSArray<NSData *> *next = [slots slotsForTags:@[ b ] rotationKey:@2];
    NSUInteger kept = 0;
    for (NSData *slot in next) kept += [back containsObject:slot] && ![slot isEqual:b];
    CHECK(kept == 0 && [next containsObject:b], "a new window draws new padding");
    NSArray<NSData *> *five = @[
        a, b, SZFTestData(@"0c0c0c0c0c0c0c0c"), SZFTestData(@"0d0d0d0d0d0d0d0d"), SZFTestData(@"0e0e0e0e0e0e0e0e")
    ];
    NSArray<NSData *> *many = [slots slotsForTags:five rotationKey:@2];
    CHECK(many.count == 4 && ![many containsObject:SZFTestData(@"0e0e0e0e0e0e0e0e")], "never more than 4");
}

void SZFriendsRunPresenceTests(void) {
    TestPresenceVectors();
    TestPresenceWindows();
    TestTagMatcher();
    TestCallbackTags();
    TestCallbackExposure();
    TestCallbackSlots();
}

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) {
            fprintf(stderr, "sodium_init failed\n");
            return 1;
        }
        SZFriendsRunPresenceTests();
        SZFriendsRunRacerTests();
        SZFriendsRunVisibilityTests();
        SZFriendsRunMergerTests();
        SZFriendsRunCoordinatorTests();
        SZFriendsRunBluetoothAdapterTests();
        SZFriendsRunStreamAndTXTTests();
        SZFriendsRunAdmissionTests();
        if (SZFTestFailures) {
            fprintf(stderr, "SZFriendsDiscoveryTests: %d failure(s)\n", SZFTestFailures);
            return 1;
        }
        printf("SZFriendsDiscoveryTests passed\n");
        return 0;
    }
}
