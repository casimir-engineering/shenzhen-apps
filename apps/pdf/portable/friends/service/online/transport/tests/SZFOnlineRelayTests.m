// The relay as a new peer connection with TURN credentials, through a coturn built from pinned source
// (server/friends/README.md § Testing) and named by FRIENDS_TEST_COTURN. coturn listens and relays on 127.0.0.1 with
// the host's credential scheme (TURN REST: base64 HMAC-SHA1 of "<expires>:<attempt id>"), logs nothing, and is
// stopped by this test; without it the scenario skips and says so.

#import "SZFOnlineTestSupport.h"

#import <CommonCrypto/CommonHMAC.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static NSString *const kSecret = @"szfriends-transport-test-secret-0123456789";
static const uint64_t kRelayBytes = 8ull * 1024 * 1024;

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

// One STUN Binding request to 127.0.0.1:port; YES when anything answers within 200 ms.
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

// Where coturn relays from. Peers bound to 127.0.0.1 can also reach a relay address on 127.0.0.1 directly, and
// libjuice then settles on that direct pair (as the stack spike saw), so relaying from this Mac's own en0 address
// keeps the path relay to relay; the traffic still never leaves the machine. Loopback when en0 has no IPv4.
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

static NSTask *StartCoturn(NSString *binary, NSString *directory, uint16_t port, NSString *relayAddress) {
    uint16_t minPort = (uint16_t)(50000 + arc4random_uniform(10000));
    NSArray<NSString *> *lines = @[
        @"realm=friends.test", [NSString stringWithFormat:@"listening-port=%u", port], @"listening-ip=127.0.0.1",
        [@"relay-ip=" stringByAppendingString:relayAddress], [NSString stringWithFormat:@"min-port=%u", minPort],
        [NSString stringWithFormat:@"max-port=%u", minPort + 63], @"fingerprint", @"use-auth-secret",
        [@"static-auth-secret=" stringByAppendingString:kSecret], @"no-tcp-relay", @"no-multicast-peers", @"no-cli",
        @"no-software-attribute", @"no-rfc5780", @"no-stdout-log", @"log-file=/dev/null", @"simple-log", @"no-tls",
        @"no-dtls", @"allow-loopback-peers", @"cli-password=unused-test-only",
        [@"pidfile=" stringByAppendingString:[directory stringByAppendingPathComponent:@"turnserver.pid"]],
    ];
    NSString *config = [directory stringByAppendingPathComponent:@"turnserver.conf"];
    if (![[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:config
                                                                                atomically:YES
                                                                                  encoding:NSUTF8StringEncoding
                                                                                     error:NULL]) {
        return nil;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:binary];
    task.arguments = @[ @"-c", config ];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (task.isRunning && [deadline timeIntervalSinceNow] > 0) {
        if (STUNAnswers(port)) return task;
    }
    [task terminate];
    return nil;
}

// Only ever the child this test started, by its own process id.
static void StopCoturn(NSTask *task) {
    if (!task.isRunning) return;
    [task terminate];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (task.isRunning && [deadline timeIntervalSinceNow] > 0) usleep(20000);
    if (task.isRunning) kill(task.processIdentifier, SIGKILL);
    [task waitUntilExit];
}

static SZFORelayCredentials *Credentials(uint16_t port, NSString *secret) {
    NSMutableData *attempt = [NSMutableData dataWithLength:16];
    arc4random_buf(attempt.mutableBytes, attempt.length);
    NSString *attemptID = [[[attempt base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+"
                                                                                                 withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/"
                                  withString:@"_"];
    NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:300];
    SZFORelayCredentials *relay = [SZFORelayCredentials new];
    relay.turnURI = [NSString stringWithFormat:@"turn:127.0.0.1:%u?transport=udp", port];
    relay.username = [NSString stringWithFormat:@"%lld:%@", (long long)expires.timeIntervalSince1970,
                                                [attemptID stringByReplacingOccurrencesOfString:@"=" withString:@""]];
    NSData *key = [secret dataUsingEncoding:NSUTF8StringEncoding];
    NSData *message = [relay.username dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *mac = [NSMutableData dataWithLength:CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1, key.bytes, key.length, message.bytes, message.length, mac.mutableBytes);
    relay.credential = [mac base64EncodedStringWithOptions:0];
    relay.expires = expires;
    return relay;
}

static void TestRelayedTransfer(SZFriendsOnlineDataChannelTransport *transport, uint16_t port, BOOL loopbackRelay) {
    SZFOPair *pair = [[SZFOPair alloc] initWithTransport:transport
                                                 purpose:SZFriendsOnlinePurposeFriend
                                                    kind:SZFriendsOnlineConnectionRelay];
    // Each side asks the host for its own credentials (ADR 0011 § The direct phase, step 3).
    pair.offererRelay = Credentials(port, kSecret);
    pair.answererRelay = Credentials(port, kSecret);
    SZFO_CHECK([pair start]);
    SZFO_CHECK([pair waitForStreams], "a relayed stream opens (%@ / %@)", pair.offererEvents.error,
               pair.answererEvents.error);
    __block id<SZFriendsByteStream> initiator = nil, responder = nil;
    SZFOOnQueue(pair.offererQueue, ^{
        initiator = pair.offererEvents.streams.firstObject;
        SZFriendsOnlineRoute route = pair.offererEvents.openedRoute;
        SZFO_CHECK(route.method == SZFriendsRouteMethodRelay && route.technique == SZFriendsOnlineTechniqueRelay,
                   "reported as the relay: class 5, technique 9 (%ld)", (long)route.technique);
        SZFO_CHECK(pair.offererEvents.candidates.count > 0);
        for (NSString *candidate in pair.offererEvents.candidates) {
            SZFO_CHECK([candidate hasSuffix:@" typ relay"], "relay candidates only: %@", candidate);
        }
    });
    SZFOOnQueue(pair.answererQueue, ^{
        responder = pair.answererEvents.streams.firstObject;
        // Relaying from 127.0.0.1, the answerer may settle on the direct pair libjuice still checks under the
        // relay-only policy, and must then say so.
        SZFriendsOnlineRoute route = pair.answererEvents.openedRoute;
        SZFO_CHECK(route.method == SZFriendsRouteMethodRelay ||
                       (loopbackRelay && route.technique == SZFriendsOnlineTechniquePeerReflexive),
                   "technique %ld", (long)route.technique);
    });
    NSTimeInterval seconds = 0;
    BOOL moved = initiator && responder && SZFOTransfer(initiator, responder, kRelayBytes, 10, &seconds);
    SZFO_CHECK(moved, "8 MiB under Noise through the relay, digest checked");
    if (moved) printf("  8 MiB through the local coturn in %.2f s\n", seconds);
    [pair close];
}

static void TestRefusedCredentials(SZFriendsOnlineDataChannelTransport *transport, uint16_t port) {
    dispatch_queue_t queue = dispatch_queue_create("szfo.relay", DISPATCH_QUEUE_SERIAL);
    SZFORecorder *events = [SZFORecorder new];
    __block id<SZFriendsOnlineConnection> connection = nil;
    SZFOOnQueue(queue, ^{
        SZFORequest *request = [SZFORequest offererForPurpose:SZFriendsOnlinePurposeFriend];
        request.kind = SZFriendsOnlineConnectionRelay;
        request.relay = Credentials(port, @"not-the-relay-secret-0123456789abcdef");
        connection = [transport openConnection:request delegate:events queue:queue error:NULL];
    });
    SZFO_CHECK(connection != nil);
    SZFO_CHECK(SZFOWaitUntil(queue, 10, ^BOOL {
        return events.error != nil;
    }), "TURN's 401 ends the attempt");
    SZFOOnQueue(queue, ^{
        SZFO_CHECK(events.error.code == SZFriendsOnlineErrorRelayRefused, "%@", events.error);
        SZFO_CHECK(events.candidates.count == 0 && events.streams.count == 0);
        [connection close];
    });
}

void SZFORunRelayTests(void) {
    NSString *binary = NSProcessInfo.processInfo.environment[@"FRIENDS_TEST_COTURN"];
    if (binary.length == 0 || ![NSFileManager.defaultManager isExecutableFileAtPath:binary]) {
        printf("  relay scenarios skipped: set FRIENDS_TEST_COTURN to a turnserver built from pinned source "
               "(server/friends/README.md § Testing)\n");
        return;
    }
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfo-coturn.XXXXXX"];
    char *template = strdup(pattern.fileSystemRepresentation);
    NSString *directory = template && mkdtemp(template) ? @(template) : nil;
    free(template);
    uint16_t port = FreeUDPPort();
    NSString *relayAddress = RelayAddress();
    NSTask *coturn = directory && port ? StartCoturn(binary, directory, port, relayAddress) : nil;
    SZFO_CHECK(coturn != nil, "coturn answers STUN on 127.0.0.1:%u", port);
    if (coturn != nil) {
        SZFriendsOnlineDataChannelTransport *transport =
            [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
        TestRelayedTransfer(transport, port, [relayAddress isEqualToString:@"127.0.0.1"]);
        TestRefusedCredentials(transport, port);
        StopCoturn(coturn);
    }
    if (directory) [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
}
