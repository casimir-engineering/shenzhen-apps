// friends-driver-check: two drivers with the real transport on 127.0.0.1, meeting through in-memory sids. A direct
// connection; two attempts started at once settling on one; and, with FRIENDS_TEST_COTURN, the relay as the last
// resort once direct paths are blocked, then left for a direct path after a network change.

#import "SZFODriverTestSupport.h"

#import <CommonCrypto/CommonHMAC.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <signal.h>
#include <sys/time.h>
#include <unistd.h>

static NSString *const kTurnSecret = @"szfriends-driver-test-secret-0123456789";

static BOOL StreamsWithRoute(SZFODDelegate *delegate, SZFriendsRouteMethod route) {
    return [delegate.routes containsObject:@(route)];
}

static SZFriendsOnlineSlot *DirectSlot(SZFriendsOnlineAttempt *attempt) {
    return attempt ? attempt->_direct : nil;
}

void SZFODTestDirect(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:nil];
    [world befriend];
    SZFriendsOnlineContext *context = world.a.onlineContext;
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    world.a.techniqueLogPath = logPath;
    EXPECT(!context.transportCreated, "the stack waits for the first attempt");
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(context.transportCreated, "and the first attempt makes it");
    EXPECT(SZFODWaitUntil(10, ^BOOL { return world.delegateA.streams.count > 0 && world.delegateB.streams.count > 0; }),
           "a direct stream on both sides");
    EXPECT(StreamsWithRoute(world.delegateA, SZFriendsRouteMethodInternet) &&
           ![world.delegateA.routes containsObject:@(SZFriendsRouteMethodRelay)], "%@", world.delegateA.routes);
    EXPECT([world.delegateA.initiators.firstObject boolValue] && ![world.delegateB.initiators.firstObject boolValue],
           "the offerer is the session's initiator");
    SZFriendsOnlineAttempt *attempt = world.a.attempts.firstObject;
    EXPECT(attempt.carriedRoute == SZFriendsRouteMethodInternet && attempt.order.phase == SZFriendsOnlinePhaseDirect);
    // The order is the only clock: the transport's own direct-phase timer is never armed.
    id<SZFriendsOnlineConnection> connection = DirectSlot(attempt).connection;
    EXPECT([(id)connection conformsToProtocol:@protocol(SZFriendsOnlineConnectionExtras)] &&
           ((id<SZFriendsOnlineConnectionExtras>)connection).directPhase.onExpire == nil);
    NSData *hello = [@"hello over the Internet" dataUsingEncoding:NSUTF8StringEncoding];
    [world.delegateA.streams.firstObject writeData:hello completion:nil];
    EXPECT(SZFODWaitUntil(5, ^BOOL { return [world.delegateB.received containsObject:hello]; }), "bytes arrive");
    // A route that ranks before Internet ends the attempt (a LAN session took over).
    world.delegateA.nearbyRoute = SZFriendsRouteMethodLAN;
    [world.a nearbyRoutesChanged];
    EXPECT(world.a.attempts.count == 0, "superseded by the LAN");
    SZFriendsTechniqueLogEntry *entry = context.techniqueLog.entries.lastObject;
    EXPECT(entry.endReason == SZFriendsOnlineEndSuperseded && entry.firstTechnique != SZFriendsOnlineTechniqueNone &&
           entry.firstTechnique != SZFriendsOnlineTechniqueRelay && !entry.relayRequested, "%@", entry.propertyList);
    // The log on disk holds numbers only: what was tried and what connected, never an address or a key.
    NSData *json = [NSData dataWithContentsOfFile:logPath];
    SZFriendsTechniqueLog *stored = json ? [[SZFriendsTechniqueLog alloc] initWithJSONData:json capacity:10] : nil;
    EXPECT(stored.entries.count == 1 && stored.entries[0].endReason == SZFriendsOnlineEndSuperseded, "%@", stored);
    NSString *text = [[NSString alloc] initWithData:json ?: [NSData data] encoding:NSUTF8StringEncoding];
    NSString *peer = [world.identityB.publicKey base64EncodedStringWithOptions:0];
    EXPECT(text.length > 0 && [text rangeOfString:@"127.0.0.1"].location == NSNotFound &&
               [text rangeOfString:[peer substringToIndex:8]].location == NSNotFound,
           "%@", text);
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:NULL];
    // Nothing is worth starting beside a better route.
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(world.a.attempts.count == 0);
    [world stop];
}

void SZFODTestSimultaneous(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:nil];
    [world befriend];
    [world.a reachFriend:world.identityB.publicKey];
    [world.b reachFriend:world.identityA.publicKey];
    EXPECT(SZFODWaitUntil(10, ^BOOL { return world.delegateA.streams.count > 0 && world.delegateB.streams.count > 0; }),
           "both started, one connects");
    SZFODSpin(0.5);
    BOOL aFirst = SZFriendsOnlineKeySortsFirst(world.identityA.publicKey, world.identityB.publicKey);
    SZFriendsOnlineDriver *offering = aFirst ? world.a : world.b, *answering = aFirst ? world.b : world.a;
    EXPECT(offering.attempts.count == 1 && offering.attempts[0].role == SZFriendsOnlineRoleOfferer,
           "the key that sorts first offers: %@", offering.attempts);
    EXPECT(answering.attempts.count == 1 && answering.attempts[0].role == SZFriendsOnlineRoleAnswerer,
           "and the other answers: %@", answering.attempts);
    SZFODDelegate *offeringDelegate = aFirst ? world.delegateA : world.delegateB;
    EXPECT(![offeringDelegate.initiators containsObject:@NO], "every stream from one offer");
    [world stop];
}

// The friend was away when we offered, so our open reached nobody and waits for an answer that cannot come. They come
// back and offer to us. When our key sorts first, the rule for both starting at once used to keep our dead offer and
// drop theirs: nothing connected until ours ran out and the backoff after it (30 s, then minutes), so what one of a
// person's computers changed while the other was away reached it minutes after it was back. Their open proves they are
// there: we offer again at once, they answer, and it connects within a round trip.
void SZFODTestBackWhileWeWait(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:nil];
    [world befriend];
    BOOL aFirst = SZFriendsOnlineKeySortsFirst(world.identityA.publicKey, world.identityB.publicKey);
    SZFriendsOnlineDriver *first = aFirst ? world.a : world.b, *other = aFirst ? world.b : world.a;
    NSData *firstKey = aFirst ? world.identityA.publicKey : world.identityB.publicKey;
    NSData *otherKey = aFirst ? world.identityB.publicKey : world.identityA.publicKey;
    SZFODDelegate *firstDelegate = aFirst ? world.delegateA : world.delegateB;
    SZFODDelegate *otherDelegate = aFirst ? world.delegateB : world.delegateA;
    // Away: the host takes the open and delivers it to nobody.
    void (^connected)(NSData *, NSData *, void (^)(id<SZFriendsOnlineSignalChannel>)) = first.testOpener;
    NSMutableArray<NSArray<SZFODChannel *> *> *unheard = [NSMutableArray array];
    first.testOpener = ^(NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        (void)rdvKey, (void)payload;
        NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
        [unheard addObject:pair];
        completion(pair[0]);
    };
    [first reachFriend:otherKey];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return unheard.count == 1 && first.attempts.count == 1; }),
           "an offer that reaches nobody: %@", first.attempts);
    // Back: opens are delivered again, and they offer to us.
    first.testOpener = connected;
    [other reachFriend:firstKey];
    EXPECT(SZFODWaitUntil(5, ^BOOL {
               return firstDelegate.streams.count > 0 && otherDelegate.streams.count > 0;
           }),
           "connected within a round trip, not after our dead offer and a backoff: %@ / %@", first.attempts,
           other.attempts);
    EXPECT(first.attempts.count == 1 && first.attempts[0].role == SZFriendsOnlineRoleOfferer,
           "the key that sorts first still offers: %@", first.attempts);
    EXPECT(other.attempts.count == 1 && other.attempts[0].role == SZFriendsOnlineRoleAnswerer,
           "and the other answers: %@", other.attempts);
    EXPECT(unheard.firstObject[0].closed, "the offer nobody heard is closed");
    [world stop];
}

#pragma mark - The relay, with a local coturn

static uint16_t FreeUDPPort(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof address;
    uint16_t port = 0;
    if (fd >= 0 && bind(fd, (struct sockaddr *)&address, sizeof address) == 0 &&
        getsockname(fd, (struct sockaddr *)&address, &length) == 0) {
        port = ntohs(address.sin_port);
    }
    if (fd >= 0) close(fd);
    return port;
}

static BOOL STUNAnswers(uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;
    struct timeval timeout = {0, 200000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(port)};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    uint8_t request[20] = {0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42};
    arc4random_buf(request + 8, 12);
    uint8_t reply[512];
    BOOL answered = sendto(fd, request, sizeof request, 0, (struct sockaddr *)&address, sizeof address) > 0 &&
                    recv(fd, reply, sizeof reply, 0) >= 20;
    close(fd);
    return answered;
}

// coturn relays from this Mac's en0 address, so the path stays relay to relay (peers on 127.0.0.1 could otherwise
// reach a 127.0.0.1 relay address directly); the traffic still never leaves the machine.
static NSString *RelayAddress(void) {
    struct ifaddrs *list = NULL;
    NSString *address = nil;
    if (getifaddrs(&list) != 0) return @"127.0.0.1";
    for (struct ifaddrs *entry = list; entry != NULL && address == nil; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_INET || strcmp(entry->ifa_name, "en0") != 0) {
            continue;
        }
        char text[INET_ADDRSTRLEN];
        const struct sockaddr_in *in = (const struct sockaddr_in *)(const void *)entry->ifa_addr;
        if (inet_ntop(AF_INET, &in->sin_addr, text, sizeof text)) address = @(text);
    }
    freeifaddrs(list);
    return address ?: @"127.0.0.1";
}

static NSTask *StartCoturn(NSString *binary, NSString *directory, uint16_t port) {
    uint16_t minPort = (uint16_t)(50000 + arc4random_uniform(10000));
    NSArray<NSString *> *lines = @[
        @"realm=friends.test", [NSString stringWithFormat:@"listening-port=%u", port], @"listening-ip=127.0.0.1",
        [@"relay-ip=" stringByAppendingString:RelayAddress()], [NSString stringWithFormat:@"min-port=%u", minPort],
        [NSString stringWithFormat:@"max-port=%u", minPort + 63], @"fingerprint", @"use-auth-secret",
        [@"static-auth-secret=" stringByAppendingString:kTurnSecret], @"no-tcp-relay", @"no-multicast-peers",
        @"no-cli", @"no-software-attribute", @"no-rfc5780", @"no-stdout-log", @"log-file=/dev/null", @"simple-log",
        @"no-tls", @"no-dtls", @"allow-loopback-peers",
        [@"pidfile=" stringByAppendingString:[directory stringByAppendingPathComponent:@"turnserver.pid"]],
    ];
    NSString *config = [directory stringByAppendingPathComponent:@"turnserver.conf"];
    [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:config atomically:YES
                                                                               encoding:NSUTF8StringEncoding
                                                                                  error:NULL];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:binary];
    task.arguments = @[ @"-c", config ];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (task.isRunning && deadline.timeIntervalSinceNow > 0) {
        if (STUNAnswers(port)) return task;
    }
    [task terminate];
    return nil;
}

// Only ever the child this test started, by its own process id.
static void StopCoturn(NSTask *task) {
    if (task.isRunning) [task terminate];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (task.isRunning && deadline.timeIntervalSinceNow > 0) usleep(20000);
    if (task.isRunning) kill(task.processIdentifier, SIGKILL);
    [task waitUntilExit];
}

// TURN REST, as the host issues them: "<expires>:<attempt id>", base64 HMAC-SHA1 under the shared secret.
static id<SZFriendsOnlineRelayCredentials> Credentials(uint16_t port) {
    SZFriendsOnlineRelayCredentialsValue *value = [SZFriendsOnlineRelayCredentialsValue new];
    NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:300];
    value.turnURI = [NSString stringWithFormat:@"turn:127.0.0.1:%u?transport=udp", port];
    value.username = [NSString stringWithFormat:@"%lld:%u", (long long)expires.timeIntervalSince1970, arc4random()];
    NSData *key = [kTurnSecret dataUsingEncoding:NSUTF8StringEncoding];
    NSData *message = [value.username dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *mac = [NSMutableData dataWithLength:CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1, key.bytes, key.length, message.bytes, message.length, mac.mutableBytes);
    value.credential = [mac base64EncodedStringWithOptions:0];
    value.expires = expires;
    return value;
}

void SZFODTestRelayAndLeave(void) {
    NSString *coturn = NSProcessInfo.processInfo.environment[@"FRIENDS_TEST_COTURN"];
    if (coturn.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:coturn]) {
        fprintf(stderr, "skip relay and leave: set FRIENDS_TEST_COTURN to a turnserver built from pinned source\n");
        return;
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil
                                                    error:NULL];
    uint16_t port = FreeUDPPort();
    NSTask *task = StartCoturn(coturn, directory, port);
    EXPECT(task != nil, "coturn starts on 127.0.0.1:%u", port);
    if (task == nil) return;
    __block BOOL blocked = YES;
    SZFriendsOnlineDriverTestHooks.directPathsBlocked = ^BOOL { return blocked; };
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:nil];
    world.credentials = ^id<SZFriendsOnlineRelayCredentials> { return Credentials(port); };
    [world befriend];
    [world.a reachFriend:world.identityB.publicKey];
    // The plain checks run their 5 s with nothing to check; only then does the relay open.
    SZFODSpin(SZFriendsOnlinePlainChecksBudget - 1);
    EXPECT(world.delegateA.streams.count == 0 && !world.a.attempts.firstObject.order.logEntry.relayRequested,
           "no relay before the direct phase is over");
    EXPECT(SZFODWaitUntil(10, ^BOOL {
               return StreamsWithRoute(world.delegateA, SZFriendsRouteMethodRelay) &&
                      StreamsWithRoute(world.delegateB, SZFriendsRouteMethodRelay);
           }),
           "relayed when every direct path fails: %@ %@", world.delegateA.routes, world.delegateB.routes);
    SZFriendsOnlineAttempt *attempt = world.a.attempts.firstObject;
    EXPECT(attempt.carriedRoute == SZFriendsRouteMethodRelay, "%ld", (long)attempt.order.phase);
    // Direct paths open again and the network changes: a new direct connection replaces the relay.
    blocked = NO;
    [SZFriendsOnlineDriverTestHooks simulateNetworkChange];
    EXPECT(SZFODWaitUntil(10, ^BOOL { return StreamsWithRoute(world.delegateA, SZFriendsRouteMethodInternet); }),
           "a direct path after the network change: %@", world.delegateA.routes);
    EXPECT(SZFODWaitUntil(2, ^BOOL { return attempt.carriedRoute == SZFriendsRouteMethodInternet; }));
    SZFriendsTechniqueLogEntry *entry = attempt.order.logEntry;
    EXPECT(entry.relayNeeded && entry.leftRelay && entry.directRetries >= 1, "%@", entry.propertyList);
    EXPECT(attempt->_relay == nil, "the relay connection is closed");
    [world stop];
    SZFriendsOnlineDriverTestHooks.directPathsBlocked = nil;
    StopCoturn(task);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}
