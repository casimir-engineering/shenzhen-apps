// The check-in state machine against scripted sockets: what it signs, reservations and renames, failover between
// hosts, backoff, list updates, release, and stop. Every host reply here is signed with the host key the list
// gives that host (SZFHReply); SZFriendsHostReplyTests.m covers replies that are not. No network.

#import "SZFriendsHostHarness.h"
#import "SZFriendsHostTestSupport.h"

#import <sodium.h>

static void SZFHTestCheckinAndRename(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHExpect([socket.url.absoluteString isEqualToString:@"wss://a.example.test/v1"], @"first URL of the main host");
    NSDictionary *checkin = SZFHChallenge(h, socket, @"main-hk");
    SZFHExpect([checkin[@"type"] isEqual:@"checkin"] && [checkin[@"friends_id"] isEqual:@"maple-river"], @"check-in");
    SZFHExpect([checkin[@"reserved"] isEqual:@NO] && [checkin[@"list_version"] isEqual:@1] &&
                   [checkin[@"protocol"] isEqual:@3] && [checkin[@"app_version"] isEqual:@"26.10.12-1"],
               @"check-in fields: %@", checkin);
    // The first device is its own root and brings no chain.
    SZFHExpect([checkin[@"root_key"] isEqual:SZFriendsHostBase64URLEncode(h.identity.publicKey)] &&
                   checkin[@"chain"] == nil,
               @"the first device names itself: %@", checkin);
    NSData *message = SZFriendsHostCheckinMessage(@"main-hk", SZFriendsHostBase64URLDecode(SZFHNonce, 32),
                                                  h.identity.publicKey, @"maple-river", NO, @"26.10.12-1", 3, 1,
                                                  h.identity.publicKey, nil);
    SZFHExpect(SZFHVerify(SZFriendsHostBase64URLDecode(checkin[@"sig"], 64), message, @"SZFriends checkin v1",
                          h.identity.publicKey),
               @"the check-in signature does not cover host id, challenge and fields");
    SZFHWelcome(h, socket, @{@"reservation" : @"taken", @"friends_id" : [NSNull null]});
    SZFHExpect([socket.sent.lastObject isEqual:(@{@"type" : @"reserve", @"v" : @1, @"friends_id" : SZFHDrawID(1)})],
               @"after a collision the client reserves a fresh draw: %@", socket.sent.lastObject);
    SZFHReply(h, socket, @{@"type" : @"reserve_result", @"reservation" : @"taken", @"friends_id" : [NSNull null]});
    SZFHExpect([socket.sent.lastObject[@"friends_id"] isEqual:SZFHDrawID(2)], @"second draw");
    SZFHReply(h, socket, @{@"type" : @"reserve_result", @"reservation" : @"reserved", @"friends_id" : SZFHDrawID(2)});
    NSArray *expected =
        @[ @"state 1", @"state 2", [NSString stringWithFormat:@"renamed maple-river %@", SZFHDrawID(2)] ];
    SZFHExpect([h.recorder.events isEqualToArray:expected], @"events: %@", h.recorder.events);
    SZFHExpect(h.client.friendsIDReserved && h.client.state == SZFriendsHostStateConnected, @"reserved and connected");
    [h.client stop];
    SZFHDrain(h.queue);
    SZFHExpect(socket.closed && h.client.state == SZFriendsHostStateStopped, @"stop closes the connection");
}

static void SZFHTestReservationAnswers(void) {
    // A reinstall that kept its key adopts the ID on record; update_required is passed on.
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"cedar-lake", @"update_required" : @YES});
    SZFHExpect([h.recorder saw:@"reserved cedar-lake"] && [h.recorder saw:@"update"], @"%@", h.recorder.events);
    [h.client stop];

    // Unavailable (the main host is down behind a replica): no callback, the ID stays unreserved.
    h = SZFHMakeHarness();
    SZFHStart(h);
    socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"unavailable", @"friends_id" : [NSNull null]});
    SZFHExpect(![h.recorder.events containsObject:@"reserved maple-river"] && !h.client.friendsIDReserved, @"no ID");
    SZFHExpect(h.client.state == SZFriendsHostStateConnected, @"still connected to the replica");
    [h.client stop];

    // At most 20 fresh IDs per connection.
    h = SZFHMakeHarness();
    SZFHStart(h);
    socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"taken", @"friends_id" : [NSNull null]});
    for (int i = 0; i < 25; i++) {
        SZFHReply(h, socket, @{@"type" : @"reserve_result", @"reservation" : @"taken", @"friends_id" : [NSNull null]});
    }
    NSPredicate *isReserve = [NSPredicate predicateWithFormat:@"type == 'reserve'"];
    NSUInteger reserves = [socket.sent filteredArrayUsingPredicate:isReserve].count;
    SZFHExpect(reserves == 20, @"%lu reserve messages, expected 20", (unsigned long)reserves);
    [h.client stop];
}

static void SZFHTestFailover(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    // First URL hangs up, second answers under another name, third (the replica) times out: then Unreachable,
    // and the retry starts over at the main host about a second later.
    [SZFHSocket(h, 0) hangUp];
    SZFHDrain(h.queue);
    SZFHFakeSocket *second = SZFHSocket(h, 1);
    SZFHExpect([second.url.absoluteString isEqualToString:@"wss://b.example.test/v1"], @"second URL");
    NSUInteger sentBefore = second.sent.count;
    SZFHChallenge(h, second, @"impostor");
    SZFHExpect(second.closed && second.sent.count == sentBefore, @"a host under another name gets nothing signed");
    SZFHFakeSocket *third = SZFHSocket(h, 2);
    SZFHExpect([third.url.absoluteString isEqualToString:@"wss://c.example.test/v1"], @"replica after the main host");
    SZFHExpect(SZFHWaitUntil(2, ^BOOL {
                   return h.client.state == SZFriendsHostStateUnreachable;
               }),
               @"not unreachable after every host failed");
    SZFHExpect(SZFHSocket(h, 3) != nil, @"no retry after the backoff");
    SZFHExpect([SZFHSocket(h, 3).url.absoluteString isEqualToString:@"wss://a.example.test/v1"], @"retry order");

    // A network change while waiting retries at once instead of after the backoff.
    [SZFHSocket(h, 3) hangUp];
    [SZFHSocket(h, 4) hangUp];
    [SZFHSocket(h, 5) hangUp];
    SZFHDrain(h.queue);
    NSDate *before = [NSDate date];
    [h.client networkDidChange];
    SZFHExpect(SZFHSocket(h, 6) != nil && [[NSDate date] timeIntervalSinceDate:before] < 0.5,
               @"a network change did not retry at once");

    // After a successful check-in, a dropped connection comes back after about a second.
    SZFHFakeSocket *live = SZFHSocket(h, 6);
    SZFHChallenge(h, live, @"main-hk");
    SZFHWelcome(h, live, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    [live hangUp];
    SZFHDrain(h.queue);
    SZFHExpect(h.client.state == SZFriendsHostStateConnecting, @"a drop says connecting");
    SZFHExpect(SZFHSocket(h, 7) != nil, @"no reconnect after a drop");
    // Late messages from the dropped socket change nothing.
    [live deliver:@{@"type" : @"reserve_result", @"reservation" : @"reserved", @"friends_id" : @"ghost-id"}];
    SZFHDrain(h.queue);
    SZFHExpect(![h.recorder saw:@"reserved ghost-id"], @"a dead socket's message was handled");
    [h.client stop];
}

static void SZFHTestListUpdates(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    // Same main host first: the list is cached and the connection stays.
    NSData *v2 = [h.signer envelopeForPayload:SZFHPayload(2, @[ @{@"id" : @"main-hk",
                                                                   @"url" : @"wss://a.example.test/v1",
                                                                   @"priority" : @1} ])];
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river",
                             @"host_list" : [NSJSONSerialization JSONObjectWithData:v2 options:0 error:NULL]});
    SZFHExpect(h.cache.currentList.version == 2 && !socket.closed, @"v2 in the welcome");
    SZFHExpect([h.recorder saw:@"reserved maple-river"], @"reservation lost with a list in the welcome");
    // A pushed list naming another main host moves the connection there within the same turn.
    NSData *v3 = [h.signer envelopeForPayload:SZFHPayload(3, @[ @{@"id" : @"new-main",
                                                                   @"url" : @"wss://n.example.test/v1",
                                                                   @"priority" : @1} ])];
    [socket deliver:@{@"type" : @"host_list",
                      @"host_list" : [NSJSONSerialization JSONObjectWithData:v3 options:0 error:NULL]}];
    SZFHDrain(h.queue);
    SZFHExpect(h.cache.currentList.version == 3 && socket.closed, @"v3 push did not move the connection");
    SZFHExpect([SZFHSocket(h, 1).url.absoluteString isEqualToString:@"wss://n.example.test/v1"], @"new main host");
    // Rollback and substitution are refused.
    [SZFHSocket(h, 1) deliver:@{@"type" : @"host_list",
                                @"host_list" : [NSJSONSerialization JSONObjectWithData:v2 options:0 error:NULL]}];
    NSData *other3 = [h.signer envelopeForPayload:SZFHPayload(3, @[ @{@"id" : @"evil",
                                                                       @"url" : @"wss://e.example.test/v1",
                                                                       @"priority" : @1} ])];
    [SZFHSocket(h, 1) deliver:@{@"type" : @"host_list",
                                @"host_list" : [NSJSONSerialization JSONObjectWithData:other3 options:0 error:NULL]}];
    SZFHDrain(h.queue);
    SZFHExpect([h.cache.currentList.entries.firstObject.hostID isEqualToString:@"new-main"], @"rollback accepted");
    [h.client stop];
}

static void SZFHTestRelease(void) {
    // Checked in: the release goes over the open connection, signed for its challenge.
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    __block int calls = 0;
    __block BOOL released = NO;
    [h.client releaseIdentityWithCompletion:^(BOOL ok) {
        calls += 1;
        released = ok;
    }];
    SZFHDrain(h.queue);
    NSDictionary *release = socket.sent.lastObject;
    NSData *message = SZFriendsHostReleaseMessage(@"main-hk", SZFriendsHostBase64URLDecode(SZFHNonce, 32),
                                                  h.identity.publicKey, @"maple-river");
    SZFHExpect([release[@"type"] isEqual:@"release"] &&
                   SZFHVerify(SZFriendsHostBase64URLDecode(release[@"sig"], 64), message, @"SZFriends release v1",
                              h.identity.publicKey),
               @"release not signed for this host and challenge: %@", release);
    SZFHReply(h, socket, @{@"type" : @"released", @"released" : @YES});
    [socket hangUp];
    SZFHDrain(h.queue);
    SZFHExpect(calls == 1 && released && h.client.state == SZFriendsHostStateStopped, @"release completion");
    usleep(1300000);
    SZFHExpect(SZFHSocket(h, 1) == nil || h.sockets.count == 1, @"the client reconnected after a release");

    // Not connected: the release opens a connection of its own.
    h = SZFHMakeHarness();
    calls = 0;
    [h.client releaseIdentityWithCompletion:^(BOOL ok) {
        calls += 1;
        released = ok;
    }];
    SZFHDrain(h.queue);
    socket = SZFHSocket(h, 0);
    NSDictionary *sent = SZFHChallenge(h, socket, @"main-hk");
    SZFHExpect([sent[@"type"] isEqual:@"release"] && [sent[@"friends_id"] isEqual:@""], @"release first: %@", sent);
    SZFHReply(h, socket, @{@"type" : @"released", @"released" : @YES});
    SZFHExpect(calls == 1 && released, @"release on a fresh connection");

    // Nobody answers: NO once, within the release timeout.
    h = SZFHMakeHarness();
    calls = 0;
    released = YES;
    [h.client releaseIdentityWithCompletion:^(BOOL ok) {
        calls += 1;
        released = ok;
    }];
    SZFHExpect(SZFHWaitUntil(2, ^BOOL {
                   return calls == 1;
               }),
               @"release never completed");
    usleep(300000);
    SZFHExpect(calls == 1 && !released, @"release completion ran %d times, released %d", calls, released);
}

static void SZFHTestBackoffAndProvider(void) {
    SZFHExpect([SZFriendsCheckInClient backoffForAttempt:0 jitter:0.99] == 1.0, @"first retry after 1 s");
    SZFHExpect([SZFriendsCheckInClient backoffForAttempt:1 jitter:0.5] == 1.5, @"second retry in [1, 2]");
    SZFHExpect([SZFriendsCheckInClient backoffForAttempt:5 jitter:0] == 1.0, @"jitter 0 is the 1 s floor");
    SZFHExpect([SZFriendsCheckInClient backoffForAttempt:8 jitter:1] <= 256, @"attempt 8");
    for (NSUInteger attempt = 9; attempt < 70; attempt++) {
        SZFHExpect([SZFriendsCheckInClient backoffForAttempt:attempt jitter:0.999999] <= 300, @"cap at 5 min");
    }
    SZFHHarness *h = SZFHMakeHarness();
    SZFriendsIDProvider provider = SZFriendsHostIDProvider(@"maple-river", [[SZFHTestCodec alloc] init].asCodec,
                                                           h.cache);
    SZFHExpect([provider(0) isEqualToString:@"maple-river"], @"provider(0) is the current ID");
    NSString *drawn = provider(2);
    SZFHExpect(SZFHLastListWords == 2 && SZFHLastCollisions == 2, @"word rule asked with the list's new_id_words");
    SZFHExpect([drawn componentsSeparatedByString:@"-"].count == 2, @"two words: %@", drawn);
    SZFHExpect([provider(3) componentsSeparatedByString:@"-"].count == 3, @"three words after three collisions");
}

void SZFHRunClientTests(void) {
    SZFHTestBackoffAndProvider();
    SZFHTestCheckinAndRename();
    SZFHTestReservationAnswers();
    SZFHTestFailover();
    SZFHTestListUpdates();
    SZFHTestRelease();
}
