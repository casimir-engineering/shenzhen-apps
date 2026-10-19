// What the check-in client believes from a host: the shared vectors for signed replies, answers that are unsigned,
// signed by another key or for another challenge or request, Friends IDs the word list refuses, the backoff that
// only a reservation resets, the 40-draw cap per launch, and a client with no word list. Each of these was
// believed, or not enforced, before host replies were signed. No network.

#import "SZFriendsHostHarness.h"
#import "SZFriendsHostTestSupport.h"

static NSUInteger SZFHReadOnQueue(SZFHHarness *h, NSUInteger (^read)(SZFriendsCheckInClient *client)) {
    __block NSUInteger value = 0;
    dispatch_sync(h.queue, ^{
        value = read(h.client);
    });
    return value;
}

static void SZFHTestReplyVectors(void) {
    NSDictionary *vectors = SZFHVectors()[@"host_replies"];
    NSArray *replies = vectors[@"replies"];
    SZFHExpect(replies.count >= 4, @"too few host-reply vectors");
    NSData *challenge = SZFriendsHostBase64URLDecode(vectors[@"challenge"], 32);
    NSData *hostKey = SZFriendsHostBase64URLDecode(vectors[@"host_key"], 32);
    for (NSDictionary *vector in replies) {
        NSDictionary *message = vector[@"message"];
        NSString *requested = [vector[@"requested"] isKindOfClass:[NSString class]] ? vector[@"requested"] : nil;
        NSString *type = message[@"type"];
        NSArray *body = [type isEqual:@"welcome"]          ? SZFriendsHostWelcomeBody(requested, message)
                        : [type isEqual:@"reserve_result"] ? SZFriendsHostReserveResultBody(requested, message)
                                                           : SZFriendsHostReleasedBody(message);
        SZFHExpect([SZFHHexString(SZFriendsHostLengthPrefixed(body)) isEqualToString:vector[@"body_hex"]],
                   @"%@: body differs from the host's", vector[@"name"]);
        NSMutableData *bytes = [[SZFriendsHostReplyDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [bytes appendData:SZFriendsHostReplyMessage(challenge, body)];
        SZFHExpect([SZFHHexString(bytes) isEqualToString:vector[@"signed_bytes_hex"]], @"%@: signed bytes differ",
                   vector[@"name"]);
        SZFHExpect(SZFriendsHostReplyVerifies(message, body, challenge, hostKey), @"%@: does not verify",
                   vector[@"name"]);
        SZFHExpect(!SZFriendsHostReplyVerifies(message, body, challenge, [SZFHSigner randomSigner].publicKey),
                   @"%@: verified with another key", vector[@"name"]);
    }
    NSDictionary *result = replies[2][@"message"];
    SZFHExpect(!SZFriendsHostReplyVerifies(result, SZFriendsHostReserveResultBody(@"cedar-lake", result), challenge,
                                           hostKey),
               @"an answer verified for another request");
}

static void SZFHTestUnsignedAnswersCountForNothing(void) {
    NSDictionary *welcome = @{@"type" : @"welcome", @"reservation" : @"reserved", @"friends_id" : @"otter-tulip",
                              @"update_required" : @YES};
    // A TLS-intercepting proxy: unsigned, signed by alt-sg's key on main-hk's connection, or for another challenge.
    for (int forgery = 0; forgery < 3; forgery++) {
        SZFHHarness *h = SZFHMakeHarness();
        SZFHStart(h);
        SZFHFakeSocket *socket = SZFHSocket(h, 0);
        SZFHChallenge(h, socket, @"main-hk");
        NSString *otherNonce = @"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA";
        NSDictionary *forged = forgery == 0   ? welcome
                               : forgery == 1 ? SZFHSigned(welcome, h.altHost, SZFHNonce, @"maple-river")
                                              : SZFHSigned(welcome, h.mainHost, otherNonce, @"maple-river");
        [socket deliver:forged];
        SZFHDrain(h.queue);
        SZFHExpect(![h.recorder saw:@"reserved otter-tulip"] && ![h.recorder saw:@"update"],
                   @"forgery %d was believed: %@", forgery, h.recorder.events);
        SZFHExpect(!h.client.friendsIDReserved, @"forgery %d marked the ID reserved", forgery);
        [h.client stop];
    }
    // An unsigned "released" leaves the reset unconfirmed.
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    __block int calls = 0;
    __block BOOL released = YES;
    [h.client releaseIdentityWithCompletion:^(BOOL ok) {
        calls += 1;
        released = ok;
    }];
    SZFHDrain(h.queue);
    [socket deliver:@{@"type" : @"released", @"released" : @YES}];
    SZFHDrain(h.queue);
    SZFHExpect(calls == 1 && !released, @"an unsigned released was believed");
}

static void SZFHTestHostileIDs(void) {
    NSString *padding = [@"" stringByPaddingToLength:2000 withString:@"x" startingAtIndex:0];
    // U+202E (right-to-left override) and a newline, as the review's probe sent.
    NSString *hostile = [NSString stringWithFormat:@"Apple Support\u202Egnp.exe\n%@", padding];
    NSArray *refused = @[ hostile, @"Maple-River", @"zzzz-yyyy", @"maple", @"maple-river-lake-moon", @"maple river" ];
    for (NSString *bad in refused) {
        SZFHHarness *h = SZFHMakeHarness();
        SZFHStart(h);
        SZFHFakeSocket *socket = SZFHSocket(h, 0);
        SZFHChallenge(h, socket, @"main-hk");
        SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : bad});
        SZFHExpect(h.recorder.events.count == 2 && !h.client.friendsIDReserved, @"accepted %@ as an ID: %@",
                   [bad substringToIndex:MIN(bad.length, 20u)], h.recorder.events);
        [h.client stop];
    }
    // After a collision the answer must name the ID just drawn, not another valid one.
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"taken", @"friends_id" : [NSNull null]});
    SZFHReply(h, socket, @{@"type" : @"reserve_result", @"reservation" : @"reserved", @"friends_id" : @"quiet-stone"});
    SZFHExpect(![h.recorder saw:@"renamed maple-river quiet-stone"] && !h.client.friendsIDReserved,
               @"a rename to an ID nobody asked for: %@", h.recorder.events);
    [h.client stop];
    // With no word list nothing is believed, and the ID stays unreserved.
    SZFHBundledWordListAvailable = NO;
    h = SZFHMakeHarness();
    SZFHStart(h);
    socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    SZFHExpect(![h.recorder saw:@"reserved maple-river"], @"reserved without a word list to check against");
    [h.client stop];
    SZFHBundledWordListAvailable = YES;
}

static void SZFHTestBackoffUntilReserved(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    for (NSUInteger round = 0; round < 2; round++) {
        SZFHFakeSocket *socket = SZFHSocket(h, round);
        SZFHChallenge(h, socket, @"main-hk");
        SZFHWelcome(h, socket, @{@"reservation" : @"unavailable", @"friends_id" : [NSNull null]});
        NSUInteger attempt = SZFHReadOnQueue(h, ^NSUInteger(SZFriendsCheckInClient *client) {
            return [client reconnectAttempt];
        });
        SZFHExpect(attempt == round, @"a welcome without a reservation reset the backoff (attempt %lu, round %lu)",
                   (unsigned long)attempt, (unsigned long)round);
        [socket hangUp];
        SZFHDrain(h.queue);
    }
    SZFHFakeSocket *third = SZFHSocket(h, 2);
    SZFHChallenge(h, third, @"main-hk");
    SZFHWelcome(h, third, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    SZFHExpect(SZFHReadOnQueue(h,
                               ^NSUInteger(SZFriendsCheckInClient *client) {
                                   return [client reconnectAttempt];
                               }) == 0,
               @"a reservation should reset the backoff");
    [h.client stop];
}

static void SZFHTestDrawCap(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    NSPredicate *isReserve = [NSPredicate predicateWithFormat:@"type == 'reserve'"];
    NSUInteger expected[] = {20, 20, 0};
    for (NSUInteger round = 0; round < 3; round++) {
        SZFHFakeSocket *socket = SZFHSocket(h, round);
        SZFHExpect(socket != nil, @"no connection %lu", (unsigned long)round);
        if (!socket) break;
        SZFHChallenge(h, socket, @"main-hk");
        SZFHWelcome(h, socket, @{@"reservation" : @"taken", @"friends_id" : [NSNull null]});
        for (int i = 0; i < 21; i++) {
            SZFHReply(h, socket, @{@"type" : @"reserve_result", @"reservation" : @"taken",
                                   @"friends_id" : [NSNull null]});
        }
        NSUInteger reserves = [socket.sent filteredArrayUsingPredicate:isReserve].count;
        SZFHExpect(reserves == expected[round], @"connection %lu sent %lu reserves, expected %lu", (unsigned long)round,
                   (unsigned long)reserves, (unsigned long)expected[round]);
        [socket hangUp];
        SZFHDrain(h.queue);
    }
    SZFHExpect(SZFHReadOnQueue(h,
                               ^NSUInteger(SZFriendsCheckInClient *client) {
                                   return [client drawsThisLaunch];
                               }) == 40,
               @"draws per launch");
    [h.client stop];
}

void SZFHRunReplyTests(void) {
    SZFHTestReplyVectors();
    SZFHTestUnsignedAnswersCountForNothing();
    SZFHTestHostileIDs();
    SZFHTestBackoffUntilReserved();
    SZFHTestDrawCap();
}
