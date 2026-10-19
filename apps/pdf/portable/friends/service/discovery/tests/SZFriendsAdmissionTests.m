// Admission limits on incoming connections (review findings "work before authentication" and "admission lockout").
// Nothing used to cap the connections a listener held before HELLO; then the cap refused newcomers, so a few IPv6
// addresses on one LAN host kept the places full and locked every friend out. Now places are taken back from the
// oldest, a silent connection loses its place after 2 s, and IPv6 counts per /64. The controller is pure apart from
// its injected clock and the deadline timer; the adapters' accept paths are tested in their own files.

#import "SZFriendsDiscoveryTestSupport.h"

#include <arpa/inet.h>
#include <netinet/in.h>

static id<SZFriendsByteStream> Admit(SZFriendsAdmissionController *admission, SZFTestStream *inner, NSString *listener,
                                     NSString *address) {
    return [admission admitStream:inner listener:listener address:address];
}

static void TestEvictionInsteadOfRefusal(void) {
    SZFriendsAdmissionController *admission = [[SZFriendsAdmissionController alloc] initWithClock:nil];
    SZFriendsAdmissionLimits *noDeadline = [SZFriendsAdmissionLimits defaultLimits];
    noDeadline.firstMessageTimeout = 0;
    admission.limits = noDeadline;
    CHECK(SZFriendsPendingPerListenerMax == 32 && SZFriendsPendingPerAddressMax == 4);
    CHECK([SZFriendsAdmissionLimits defaultLimits].firstMessageTimeout == SZFriendsFirstMessageTimeout &&
          SZFriendsFirstMessageTimeout == 2);
    NSMutableArray<SZFTestStream *> *inner = [NSMutableArray array];
    NSMutableArray<id<SZFriendsByteStream>> *held = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        [inner addObject:[SZFTestStream new]];
        [held addObject:Admit(admission, inner[i], @"hidden", @"6:fd00:0001:0002:0003/64")];
    }
    // The attacker's fifth from its /64 takes back the oldest of its own, never someone else's.
    SZFTestStream *friendInner = [SZFTestStream new];
    [held addObject:Admit(admission, friendInner, @"hidden", @"4:192.168.1.20")];
    SZFTestStream *fifthInner = [SZFTestStream new];
    id<SZFriendsByteStream> fifth = Admit(admission, fifthInner, @"hidden", @"6:fd00:0001:0002:0003/64");
    CHECK(fifth != nil && !fifthInner.closed, "a newcomer is never refused");
    CHECK(inner[0].closed && !inner[1].closed && !friendInner.closed, "the oldest from that address made way");
    CHECK([admission pendingFromAddress:@"6:fd00:0001:0002:0003/64"] == 4 &&
          [admission pendingOnListener:@"hidden"] == 5);

    // The listener's 32, filled from many addresses: a friend arriving then still gets in, and the oldest goes.
    NSMutableArray<SZFTestStream *> *flood = [NSMutableArray array];
    for (int i = 0; i < 40; i++) {
        SZFTestStream *stream = [SZFTestStream new];
        [flood addObject:stream];
        [held addObject:Admit(admission, stream, @"hidden", [NSString stringWithFormat:@"4:10.1.0.%d", i])];
    }
    CHECK([admission pendingOnListener:@"hidden"] == 32, "32 on one listener: %lu",
          (unsigned long)[admission pendingOnListener:@"hidden"]);
    CHECK(friendInner.closed, "the friend who never authenticated was among the oldest");
    SZFTestStream *lateFriend = [SZFTestStream new];
    id<SZFriendsByteStream> late = Admit(admission, lateFriend, @"hidden", @"4:192.168.1.21");
    CHECK(late != nil && !lateFriend.closed && flood[39].closed == NO && flood[8].closed,
          "a friend arriving into a full listener gets in; the oldest flooder goes");
    // Authenticated as soon as the key policy accepted message 1: out of the count, so no later flood evicts it.
    [late handshakeDidReceiveFirstMessage];
    [late sessionDidAuthenticate];
    for (int i = 0; i < 40; i++) {
        NSString *address = [NSString stringWithFormat:@"4:10.2.0.%d", i];
        [held addObject:Admit(admission, [SZFTestStream new], @"hidden", address)];
    }
    CHECK(!lateFriend.closed && [admission pendingOnListener:@"hidden"] == 32, "an authenticated friend is safe");
    [held addObject:Admit(admission, [SZFTestStream new], @"public", @"4:10.2.0.1")];
    CHECK([admission pendingOnListener:@"public"] == 1, "the other entry has its own 32");

    // Each of the ways a place comes back, exactly once each.
    SZFriendsAdmissionController *quiet = [[SZFriendsAdmissionController alloc] initWithClock:nil];
    quiet.limits = noDeadline;
    id<SZFriendsByteStream> a = Admit(quiet, [SZFTestStream new], @"hidden", @"4:10.0.0.7");
    id<SZFriendsByteStream> b = Admit(quiet, [SZFTestStream new], @"hidden", @"4:10.0.0.7");
    SZFTestStream *cInner = [SZFTestStream new];
    id<SZFriendsByteStream> c = Admit(quiet, cInner, @"hidden", @"4:10.0.0.7");
    [a sessionDidAuthenticate];
    [a sessionDidAuthenticate];
    [a close];
    CHECK([quiet pendingFromAddress:@"4:10.0.0.7"] == 2, "authenticated, then closed: one place back");
    [b close];
    CHECK([quiet pendingFromAddress:@"4:10.0.0.7"] == 1, "closed by the session");
    __block NSError *seen = [NSError errorWithDomain:@"unset" code:0 userInfo:nil];
    c.onClose = ^(NSError *error) {
        seen = error;
    };
    cInner.onClose(nil); // the link ended on its own
    CHECK([quiet pendingFromAddress:@"4:10.0.0.7"] == 0 && seen == nil, "closed by the peer, and still reported");

    // Limits change for new admissions; 0 means none.
    SZFriendsAdmissionLimits *open = [SZFriendsAdmissionLimits defaultLimits];
    open.pendingPerListener = open.pendingPerAddress = 0;
    open.firstMessageTimeout = 0;
    quiet.limits = open;
    for (int i = 0; i < 50; i++) {
        @autoreleasepool {
            Admit(quiet, [SZFTestStream new], @"hidden", @"4:10.3.0.1");
        }
    }
    CHECK([quiet pendingOnListener:@"hidden"] == 0, "released as they go out of scope, none evicted");
    quiet.limits = nil;
    CHECK(quiet.limits.pendingPerListener == 32, "nil restores the defaults");
}

// An evicted session hears that its stream closed, on its own queue, whether it had started or not.
static void TestEvictedSessionIsTold(void) {
    SZFriendsAdmissionController *admission = [[SZFriendsAdmissionController alloc] initWithClock:nil];
    SZFriendsAdmissionLimits *one = [SZFriendsAdmissionLimits defaultLimits];
    one.pendingPerAddress = 1;
    one.firstMessageTimeout = 0;
    admission.limits = one;
    dispatch_queue_t queue = dispatch_queue_create("test.admission", DISPATCH_QUEUE_SERIAL);
    __block NSError *startedError = nil, *lateError = nil;
    __block NSUInteger closes = 0;
    id<SZFriendsByteStream> started = Admit(admission, [SZFTestStream new], @"hidden", @"4:10.9.0.1");
    started.onClose = ^(NSError *error) {
        startedError = error;
        closes++;
    };
    dispatch_sync(queue, ^{
        [started startWithQueue:queue];
    });
    id<SZFriendsByteStream> notYet = Admit(admission, [SZFTestStream new], @"hidden", @"4:10.9.0.1");
    Admit(admission, [SZFTestStream new], @"hidden", @"4:10.9.0.1"); // evicts notYet before it ever started
    notYet.onClose = ^(NSError *error) {
        lateError = error;
    };
    dispatch_sync(queue, ^{
        [notYet startWithQueue:queue];
    });
    CHECK(SZFTestWait(queue, 2, ^BOOL {
        return startedError != nil && lateError != nil;
    }));
    dispatch_sync(queue, ^{
        CHECK(startedError.code == SZFriendsDiscoveryErrorEvicted && lateError.code == SZFriendsDiscoveryErrorEvicted,
              "%@ %@", startedError, lateError);
        CHECK(closes == 1, "told once");
        [started close]; // the session's own close afterwards changes nothing
    });
}

// A connection that sends no complete message 1 within the deadline loses its place; one that did keeps it.
static void TestFirstMessageDeadline(void) {
    SZFriendsAdmissionController *admission = [[SZFriendsAdmissionController alloc] initWithClock:nil];
    SZFriendsAdmissionLimits *quick = [SZFriendsAdmissionLimits defaultLimits];
    quick.firstMessageTimeout = 0.1;
    admission.limits = quick;
    dispatch_queue_t queue = dispatch_queue_create("test.deadline", DISPATCH_QUEUE_SERIAL);
    SZFTestStream *silentInner = [SZFTestStream new], *talkerInner = [SZFTestStream new];
    id<SZFriendsByteStream> silent = Admit(admission, silentInner, @"hidden", @"4:10.8.0.1");
    id<SZFriendsByteStream> talker = Admit(admission, talkerInner, @"hidden", @"4:10.8.0.2");
    __block NSError *silentError = nil;
    silent.onClose = ^(NSError *error) {
        silentError = error;
    };
    dispatch_sync(queue, ^{
        [silent startWithQueue:queue];
        [talker startWithQueue:queue];
        [talker handshakeDidReceiveFirstMessage];
    });
    CHECK(SZFTestWait(queue, 3, ^BOOL {
        return silentError != nil;
    }), "the silent connection is closed");
    dispatch_sync(queue, ^{
        CHECK(silentInner.closed && silentError.code == SZFriendsDiscoveryErrorEvicted);
        CHECK(!talkerInner.closed && [admission pendingOnListener:@"hidden"] == 1,
              "message 1 arrived in time: it keeps its place until it authenticates or closes");
        [talker close];
    });
}

static void TestPatternRates(void) {
    __block NSTimeInterval now = 100;
    SZFriendsAdmissionController *admission = [[SZFriendsAdmissionController alloc] initWithClock:^NSTimeInterval {
        return now;
    }];
    SZFriendsAdmissionLimits *limits = [SZFriendsAdmissionLimits defaultLimits];
    limits.pendingPerListener = limits.pendingPerAddress = 0;
    limits.firstMessageTimeout = 0;
    limits.nnPerMinutePerListener = 3;
    limits.xxPerMinutePerAddress = 2;
    admission.limits = limits;
    NSUInteger admittedNN = 0;
    for (int i = 0; i < 5; i++) {
        id<SZFriendsByteStream> s = [admission admitStream:[SZFTestStream new] listener:@"hidden"
                                                   address:[NSString stringWithFormat:@"10.0.0.%d", i]];
        admittedNN += [s admitHandshakePattern:SZFriendsHandshakeNN];
    }
    CHECK(admittedNN == 3, "NN: 3 a minute on the listener, whatever the address, got %lu", (unsigned long)admittedNN);
    id<SZFriendsByteStream> ik = [admission admitStream:[SZFTestStream new] listener:@"hidden" address:@"10.0.0.9"];
    CHECK([ik admitHandshakePattern:SZFriendsHandshakeIK], "other patterns are counted apart");
    CHECK(![ik admitHandshakePattern:SZFriendsHandshakeIK], "one question per connection");
    now += 60;
    id<SZFriendsByteStream> later = [admission admitStream:[SZFTestStream new] listener:@"hidden" address:@"10.0.0.1"];
    CHECK([later admitHandshakePattern:SZFriendsHandshakeNN], "a minute later there is room again");

    NSUInteger admittedXX = 0;
    for (int i = 0; i < 4; i++) {
        id<SZFriendsByteStream> s = [admission admitStream:[SZFTestStream new] listener:@"public" address:@"10.9.9.9"];
        admittedXX += [s admitHandshakePattern:SZFriendsHandshakeXX];
    }
    id<SZFriendsByteStream> other = [admission admitStream:[SZFTestStream new] listener:@"public" address:@"10.9.9.8"];
    CHECK(admittedXX == 2 && [other admitHandshakePattern:SZFriendsHandshakeXX], "XX: 2 a minute per address");
    CHECK([[SZFriendsAdmissionLimits defaultLimits] copy] != nil);
}

static void TestWrapperForwards(void) {
    SZFriendsAdmissionController *admission = [[SZFriendsAdmissionController alloc] initWithClock:nil];
    SZFTestStream *inner = [SZFTestStream new];
    id<SZFriendsByteStream> admitted = [admission admitStream:inner listener:@"hidden" address:nil];
    __block NSData *received = nil;
    admitted.onData = ^(NSData *data) {
        received = data;
    };
    inner.onData([NSData dataWithBytes:"hi" length:2]);
    [admitted writeData:[NSData dataWithBytes:"yo" length:2] completion:nil];
    CHECK([received isEqual:[NSData dataWithBytes:"hi" length:2]] &&
          [inner.written isEqual:[NSData dataWithBytes:"yo" length:2]]);
    CHECK(admitted.preferredWriteSize == inner.preferredWriteSize);
    [admitted close];
    CHECK(inner.closed && [admission pendingOnListener:@"hidden"] == 0);
}

static NSString *KeyFor6(NSString *text, uint32_t scope) {
    struct sockaddr_in6 address = {.sin6_len = sizeof address, .sin6_family = AF_INET6, .sin6_scope_id = scope};
    inet_pton(AF_INET6, text.UTF8String, &address.sin6_addr);
    return SZFriendsAdmissionKeyForAddress((const struct sockaddr *)&address);
}

// One host picks any address inside its /64, so whole IPv6 addresses never bounded one peer.
static void TestAddressKeys(void) {
    struct sockaddr_in v4 = {.sin_len = sizeof v4, .sin_family = AF_INET};
    inet_pton(AF_INET, "192.168.1.20", &v4.sin_addr);
    CHECK([SZFriendsAdmissionKeyForAddress((const struct sockaddr *)&v4) isEqual:@"4:192.168.1.20"]);
    CHECK([KeyFor6(@"2001:db8:1:2:aaaa::1", 0) isEqual:KeyFor6(@"2001:db8:1:2:bbbb:cccc:dddd:eeee", 0)] &&
          [KeyFor6(@"2001:db8:1:2::9", 0) isEqual:@"6:2001:0db8:0001:0002/64"], "one /64, one key: %@",
          KeyFor6(@"2001:db8:1:2::9", 0));
    CHECK(![KeyFor6(@"2001:db8:1:3::1", 0) isEqual:KeyFor6(@"2001:db8:1:2::1", 0)], "the next /64 is someone else");
    CHECK([KeyFor6(@"::ffff:192.168.1.20", 0) isEqual:@"4:192.168.1.20"],
          "an IPv4 peer on a dual-stack socket is its IPv4 address, not ::ffff:0:0/64 shared by all of them");
    CHECK([KeyFor6(@"fe80::1", 4) isEqual:KeyFor6(@"fe80::abcd:ef01:2345:6789", 4)] &&
          [KeyFor6(@"fe80::1", 4) isEqual:@"6:fe80:0000:0000:0000/64%4"], "link-local: one key per link");
    CHECK(![KeyFor6(@"fe80::1", 4) isEqual:KeyFor6(@"fe80::1", 7)], "neighbours on another link count apart");
    CHECK([KeyFor6(@"fe80:4::1", 0) isEqual:KeyFor6(@"fe80::1", 4)], "the interface the kernel embeds counts too");
    struct sockaddr local = {.sa_len = sizeof local, .sa_family = AF_UNIX};
    CHECK(SZFriendsAdmissionKeyForAddress(&local) == nil && SZFriendsAdmissionKeyForAddress(NULL) == nil);
}

void SZFriendsRunAdmissionTests(void) {
    TestEvictionInsteadOfRefusal();
    TestEvictedSessionIsTold();
    TestFirstMessageDeadline();
    TestWrapperForwards();
    TestPatternRates();
    TestAddressKeys();
}
