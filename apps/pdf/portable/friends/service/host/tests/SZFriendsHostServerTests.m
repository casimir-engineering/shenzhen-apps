// The real client, socket and list cache against the Node host service from portable/server/friends/, run on
// 127.0.0.1 with a temporary data directory and throwaway keys. Proves the two sides agree on the wire: check-in
// signatures, signed host replies, reservations and renames, list pushes, release, failover and refusals.

#import "SZFriendsHostTestSupport.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <signal.h>
#import <sys/socket.h>

static NSString *const SZFHDashboardPassword = @"host-client-test-password";
static NSTask *SZFHServer;

@interface SZFHServerHandle : NSObject
@property(nonatomic) NSTask *task;
@property(nonatomic) NSInteger port;
@property(nonatomic) NSString *dataDir;
@property(nonatomic) NSString *dashboardSocket;
@property(nonatomic) SZFHSigner *signer;
@property(nonatomic) SZFHSigner *hostKey; // main-hk's host key, which signs its replies
@end

@implementation SZFHServerHandle
@end

static void SZFHStopServerAtExit(void) {
    if (SZFHServer.isRunning) kill(SZFHServer.processIdentifier, SIGKILL);
}

// A port nothing listens on: bound, then closed, so a connection to it is refused at once.
static NSInteger SZFHClosedPort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(fd, (struct sockaddr *)&address, sizeof address);
    socklen_t length = sizeof address;
    getsockname(fd, (struct sockaddr *)&address, &length);
    close(fd);
    return ntohs(address.sin_port);
}

static SZFHServerHandle *SZFHStartServer(void) {
    NSString *serverDir = SZFHEnv(@"SZFRIENDS_HOST_SERVER_DIR");
    SZFHServerHandle *server = [[SZFHServerHandle alloc] init];
    server.signer = [SZFHSigner randomSigner];
    server.hostKey = [SZFHSigner randomSigner];
    NSString *dir = SZFHTempDir();
    server.dataDir = [dir stringByAppendingPathComponent:@"data"];
    server.dashboardSocket = [server.dataDir stringByAppendingPathComponent:@"dashboard.sock"];
    NSString *listFile = [dir stringByAppendingPathComponent:@"list.json"];
    NSString *keyFile = [dir stringByAppendingPathComponent:@"host-key.pem"];
    [[server.signer envelopeForPayload:SZFHPayload(1, @[ @{@"id" : @"main-hk", @"url" : @"ws://127.0.0.1:9/v1",
                                                            @"priority" : @1, @"key" : server.hostKey.publicKey} ])]
        writeToFile:listFile
         atomically:YES];
    [SZFHPrivateKeyPEM(server.hostKey) writeToFile:keyFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = @[ @"node", @"--disable-warning=ExperimentalWarning",
                        [serverDir stringByAppendingPathComponent:@"src/main.js"] ];
    task.environment = @{
        @"PATH" : SZFHEnv(@"PATH") ?: @"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        @"FRIENDS_HOST_ID" : @"main-hk",
        @"FRIENDS_LISTEN_HOST" : @"127.0.0.1",
        @"FRIENDS_LISTEN_PORT" : @"0",
        @"FRIENDS_DATA_DIR" : server.dataDir,
        @"FRIENDS_PINNED_KEYS" : SZFriendsHostBase64URLEncode(server.signer.publicKey),
        @"FRIENDS_HOST_LIST_FILE" : listFile,
        @"FRIENDS_HOST_KEY_FILE" : keyFile,
        @"FRIENDS_IDENTITY_SECRET" : @"host-client-test-identity-secret-0123456789",
        @"FRIENDS_DASHBOARD_PASSWORD" : SZFHDashboardPassword,
        @"FRIENDS_DASHBOARD_SOCKET" : server.dashboardSocket,
        // Every client here connects from 127.0.0.1; the per-address limits have their own tests in the service.
        @"FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY" : @"100",
        @"FRIENDS_MAX_CONNECTIONS_PER_ADDRESS" : @"100",
    };
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithStandardError];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        SZFHFail(__FILE__, __LINE__, @"could not start node: %@", error);
        return nil;
    }
    SZFHServer = task;
    server.task = task;
    // The service logs one JSON line per event; the first, "listening", carries the port it bound.
    __block NSInteger port = 0;
    NSMutableData *buffer = [NSMutableData data];
    NSFileHandle *reader = output.fileHandleForReading;
    reader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        @synchronized(buffer) {
            [buffer appendData:chunk];
            NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
                if ([event[@"event"] isEqual:@"listening"]) port = [event[@"port"] integerValue];
            }
            if (chunk.length == 0) handle.readabilityHandler = nil;
        }
    };
    SZFHExpect(SZFHWaitUntil(10, ^BOOL {
                   @synchronized(buffer) {
                       return port > 0;
                   }
               }),
               @"the host service did not start within 10 s");
    server.port = port;
    return server;
}

static void SZFHStopServer(SZFHServerHandle *server) {
    [server.task terminate];
    if (!SZFHWaitUntil(5, ^BOOL {
            return !server.task.isRunning;
        })) {
        kill(server.task.processIdentifier, SIGKILL);
    }
    [[NSFileManager defaultManager] removeItemAtPath:[server.dataDir stringByDeletingLastPathComponent] error:NULL];
}

@interface SZFHLiveClient : NSObject
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) SZFriendsHostListCache *cache;
@property(nonatomic) SZFriendsCheckInClient *client;
@property(nonatomic) SZFHRecorder *recorder;
@property(nonatomic) NSString *cachePath;
@end

@implementation SZFHLiveClient
@end

static SZFHLiveClient *SZFHLive(SZFHServerHandle *server, NSArray<NSDictionary *> *hosts, SZFHTestIdentity *identity) {
    SZFHLiveClient *live = [[SZFHLiveClient alloc] init];
    live.queue = dispatch_queue_create("szfh.live", DISPATCH_QUEUE_SERIAL);
    live.cachePath = [SZFHTempDir() stringByAppendingPathComponent:@"hosts.json"];
    NSData *bootstrap = [server.signer envelopeForPayload:SZFHPayload(1, hosts)];
    live.cache = [[SZFriendsHostListCache alloc] initWithCachePath:live.cachePath
                                                     bootstrapData:bootstrap
                                                        pinnedKeys:@[ server.signer.publicKey ]];
    live.client = [[SZFriendsCheckInClient alloc] initWithListCache:live.cache
                                                           identity:identity.asIdentity
                                                         appVersion:@"26.10.12-1"
                                                      socketFactory:SZFriendsHostWebSocketFactory(live.queue)
                                                              queue:live.queue];
    live.client.watchesNetworkPath = NO;
    live.client.connectTimeout = 3;
    live.client.releaseTimeout = 4;
    live.recorder = [[SZFHRecorder alloc] init];
    live.client.delegate = live.recorder;
    return live;
}

static NSArray<NSDictionary *> *SZFHHostsWithKey(SZFHServerHandle *server, NSData *key) {
    return @[ @{@"id" : @"main-hk", @"url" : [NSString stringWithFormat:@"ws://127.0.0.1:%ld/v1", (long)server.port],
                @"priority" : @1, @"key" : key} ];
}

static NSArray<NSDictionary *> *SZFHHosts(SZFHServerHandle *server) {
    return SZFHHostsWithKey(server, server.hostKey.publicKey);
}

static void SZFHStartLive(SZFHLiveClient *live, NSString *currentID) {
    [live.client startWithFriendsIDProvider:^NSString *(NSUInteger collisions) {
        return collisions == 0 ? currentID : SZFHDrawID(collisions);
    }];
}

static BOOL SZFHRelease(SZFHLiveClient *live) {
    __block int calls = 0;
    __block BOOL released = NO;
    [live.client releaseIdentityWithCompletion:^(BOOL ok) {
        released = ok;
        calls += 1;
    }];
    SZFHExpect(SZFHWaitUntil(6, ^BOOL {
                   return calls > 0;
               }),
               @"release did not complete");
    return calls == 1 && released;
}

// The device chains the helper's own code wrote for the host's tests (test/vectors/device-chain-v1.json), by case.
static NSDictionary<NSString *, NSDictionary *> *SZFHChainCases(void) {
    NSString *path = [SZFHEnv(@"SZFRIENDS_HOST_SERVER_DIR") stringByAppendingPathComponent:
                                                                @"test/vectors/device-chain-v1.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *vectors = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableDictionary *cases = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in vectors[@"cases"]) cases[entry[@"name"]] = entry;
    return cases;
}

// A device of the vectors' person (seed byte `seedByte`: 0x11 is root a, 0x22 device b), checking in with `chain`.
static SZFHLiveClient *SZFHLiveDevice(SZFHServerHandle *server, NSDictionary *chainCase, uint8_t seedByte) {
    NSMutableData *seed = [NSMutableData dataWithLength:32];
    memset(seed.mutableBytes, seedByte, 32);
    SZFHLiveClient *live = SZFHLive(server, SZFHHosts(server), [SZFHTestIdentity identityWithSeed:seed]);
    NSData *root = SZFHHex(chainCase[@"root"]);
    NSData *chain = SZFriendsHostBase64URLDecode(chainCase[@"chain"], 0);
    live.client.drawsIDs = NO;
    live.client.membershipProvider = ^NSData *(NSData **out) {
        *out = chain;
        return root;
    };
    return live;
}

// Protocol 3 against the real service: a device that joined checks in for its person with the chain that added it,
// and the person's ID is reserved and attested for the root; the first device's release leaves that ID while its
// chain lists the other; a chain that revokes it gets 4002, which stops it.
static void SZFHRunLiveDeviceTests(SZFHServerHandle *server) {
    NSDictionary<NSString *, NSDictionary *> *cases = SZFHChainCases();
    SZFHExpect(cases[@"add"] != nil && cases[@"revoke_after_seeing"] != nil, @"the chain vectors are missing");
    if (cases[@"add"] == nil || cases[@"revoke_after_seeing"] == nil) return;
    NSData *root = SZFHHex(cases[@"add"][@"root"]);
    SZFHLiveClient *joined = SZFHLiveDevice(server, cases[@"add"], 0x22);
    SZFHStartLive(joined, @"lark-lake");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [joined.recorder saw:@"reserved lark-lake"];
               }),
               @"a joined device did not check in for its person: %@", joined.recorder.events);
    SZFHExpect(SZFHWaitUntil(4, ^BOOL {
                   return [joined.client attestationForFriendsID:@"lark-lake"] != nil;
               }),
               @"no attestation kept for the person's ID: %@", joined.recorder.events);
    SZFHExpect([[joined.client attestationForFriendsID:@"lark-lake"].identityKey isEqualToData:root],
               @"the person's ID is attested for the root");
    [joined.client stop];

    // Reset Friends on the first device while its chain lists b: the host keeps the person's ID for b.
    SZFHLiveClient *leaving = SZFHLiveDevice(server, cases[@"add"], 0x11);
    SZFHStartLive(leaving, @"lark-lake");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [leaving.recorder saw:@"reserved lark-lake"];
               }),
               @"the first device checks in with the chain that lists b: %@", leaving.recorder.events);
    SZFHExpect(!SZFHRelease(leaving), @"the host released the ID b still uses");

    // The first device brings the chain that removes b: from then on b is turned away even with the chain from before.
    SZFHLiveClient *first = SZFHLiveDevice(server, cases[@"revoke_after_seeing"], 0x11);
    SZFHStartLive(first, @"lark-lake");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [first.recorder saw:@"reserved lark-lake"];
               }),
               @"the first device checks in with its chain: %@", first.recorder.events);
    [first.client stop];
    SZFHLiveClient *stale = SZFHLiveDevice(server, cases[@"add"], 0x22);
    SZFHStartLive(stale, @"lark-lake");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [stale.recorder saw:@"revoked"];
               }),
               @"an older chain no longer lets b in: %@", stale.recorder.events);
    SZFHLiveClient *removed = SZFHLiveDevice(server, cases[@"revoke_after_seeing"], 0x22);
    SZFHStartLive(removed, @"lark-lake");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [removed.recorder saw:@"revoked"];
               }),
               @"a removed device was not told: %@", removed.recorder.events);
    SZFHExpect(removed.client.state == SZFriendsHostStateStopped && ![removed.recorder saw:@"reserved lark-lake"],
               @"a removed device stops: %@", removed.recorder.events);
}

void SZFHRunServerTests(void) {
    atexit(SZFHStopServerAtExit);
    SZFHServerHandle *server = SZFHStartServer();
    if (server.port == 0) return;
    SZFHTestIdentity *alice = [SZFHTestIdentity randomIdentity];
    SZFHTestIdentity *bob = [SZFHTestIdentity randomIdentity];

    // The client keeps the attestation only after it has reported the reservation, on its own queue, so the checks
    // wait for it; the recorders hold that queue a moment after reporting, so a check that reads too early fails
    // every run instead of one run in nine.
    SZFHLiveClient *a = SZFHLive(server, SZFHHosts(server), alice);
    a.recorder.reserveDelay = 0.3;
    SZFHStartLive(a, @"maple-river");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [a.recorder saw:@"reserved maple-river"];
               }),
               @"no reservation over the real socket: %@", a.recorder.events);
    SZFHExpect(a.client.state == SZFriendsHostStateConnected && a.client.friendsIDReserved, @"connected and reserved");
    // The host attests the reservation with the key the list gives it, and the client keeps that for Add by ID.
    SZFHExpect(SZFHWaitUntil(4, ^BOOL {
                   return [a.recorder saw:@"attestation maple-river main-hk"];
               }),
               @"no attestation event from the host: %@", a.recorder.events);
    SZFriendsHostAttestation *attested = [a.client attestationForFriendsID:@"maple-river"];
    SZFHExpect([attested.hostID isEqualToString:@"main-hk"] && [attested.identityKey isEqualToData:alice.publicKey],
               @"no attestation from the host: %@", a.recorder.events);
    SZFHExpect(SZFriendsHostAttestationCheck(attested, a.cache.currentList, @"maple-river", alice.publicKey,
                                             [NSDate date]) == SZFriendsHostAttestationValid,
               @"the host's attestation does not check out");

    SZFHLiveClient *b = SZFHLive(server, SZFHHosts(server), bob);
    b.recorder.reserveDelay = 0.3;
    SZFHStartLive(b, @"maple-river");
    NSString *renamed = [NSString stringWithFormat:@"renamed maple-river %@", SZFHDrawID(1)];
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [b.recorder saw:renamed];
               }),
               @"the newcomer was not renamed: %@", b.recorder.events);
    NSString *renamedAttestation = [NSString stringWithFormat:@"attestation %@ main-hk", SZFHDrawID(1)];
    SZFHExpect(SZFHWaitUntil(4, ^BOOL {
                   return [b.recorder saw:renamedAttestation];
               }),
               @"no attestation event for the new ID: %@", b.recorder.events);
    SZFHExpect([b.client attestationForFriendsID:SZFHDrawID(1)] != nil && [b.client attestationForFriendsID:
                                                                                  @"maple-river"] == nil,
               @"the rename was not attested for the new ID: %@", b.recorder.events);

    // A list that gives main-hk another public key: the host's signed answers no longer verify, so nothing is
    // reserved even though the connection checks in.
    NSArray *wrongHosts = SZFHHostsWithKey(server, [SZFHSigner randomSigner].publicKey);
    SZFHLiveClient *wrongKey = SZFHLive(server, wrongHosts, [SZFHTestIdentity randomIdentity]);
    SZFHStartLive(wrongKey, @"quiet-meadow");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return wrongKey.client.state == SZFriendsHostStateConnected;
               }),
               @"the wrong-key client never checked in: %@", wrongKey.recorder.events);
    SZFHDrain(wrongKey.queue);
    SZFHExpect(![wrongKey.recorder saw:@"reserved quiet-meadow"] && !wrongKey.client.friendsIDReserved,
               @"a reply signed by another key reserved an ID: %@", wrongKey.recorder.events);
    [wrongKey.client stop];

    // A reinstall that kept Alice's key adopts her recorded ID, whatever it claims.
    SZFHLiveClient *again = SZFHLive(server, SZFHHosts(server), alice);
    SZFHStartLive(again, @"pebble-moon");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [again.recorder saw:@"reserved maple-river"];
               }),
               @"the recorded ID was not adopted: %@", again.recorder.events);
    [again.client stop];

    // A list published on the host reaches a connected client within seconds and is cached.
    NSData *v2 = [server.signer envelopeForPayload:SZFHPayload(2, SZFHHosts(server))];
    NSInteger status =
        SZFHDashboardRequest(server.dashboardSocket, @"POST", @"/lists", @"admin", SZFHDashboardPassword, v2);
    SZFHExpect(status == 200, @"publishing v2 answered %ld", (long)status);
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   return b.cache.currentList.version == 2;
               }),
               @"the pushed list did not arrive");
    SZFHExpect([[NSData dataWithContentsOfFile:b.cachePath] isEqualToData:b.cache.currentList.signedData],
               @"the pushed list was not cached");

    // Release frees Alice's ID for someone new.
    SZFHExpect(SZFHRelease(a), @"release over the open connection failed");
    SZFHExpect(a.client.state == SZFriendsHostStateStopped, @"the client should stop after a release");
    SZFHLiveClient *carol = SZFHLive(server, SZFHHosts(server), [SZFHTestIdentity randomIdentity]);
    SZFHStartLive(carol, @"maple-river");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [carol.recorder saw:@"reserved maple-river"];
               }),
               @"the released ID was not free: %@", carol.recorder.events);
    [carol.client stop];

    // Release from a stopped client opens its own connection.
    [b.client stop];
    SZFHExpect(SZFHRelease(b), @"release on a fresh connection failed");

    // Failover: the main host in this client's list refuses connections; the next host answers.
    NSArray *failover = @[ @{@"id" : @"dead-hk", @"url" : [NSString stringWithFormat:@"ws://127.0.0.1:%ld/v1",
                                                                                     (long)SZFHClosedPort()],
                             @"priority" : @1},
                           @{@"id" : @"main-hk", @"url" : SZFHHosts(server)[0][@"url"], @"priority" : @2} ];
    SZFHLiveClient *f = SZFHLive(server, failover, [SZFHTestIdentity randomIdentity]);
    SZFHStartLive(f, @"fall-back");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return f.client.state == SZFriendsHostStateConnected;
               }),
               @"no failover to the second host: %@", f.recorder.events);
    [f.client stop];

    // Refusals: a host answering under another name, and a signature the host does not accept, never connect.
    NSArray *impostor = @[ @{@"id" : @"other-hk", @"url" : SZFHHosts(server)[0][@"url"], @"priority" : @1} ];
    SZFHLiveClient *wrongName = SZFHLive(server, impostor, [SZFHTestIdentity randomIdentity]);
    SZFHLiveClient *forged = SZFHLive(server, SZFHHosts(server), [SZFHTestIdentity brokenIdentity]);
    SZFHStartLive(wrongName, @"wrong-name");
    SZFHStartLive(forged, @"forged-key");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return wrongName.client.state == SZFriendsHostStateUnreachable &&
                          forged.client.state == SZFriendsHostStateUnreachable;
               }),
               @"refused clients should be unreachable: %ld %ld", (long)wrongName.client.state,
               (long)forged.client.state);
    SZFHExpect(![forged.recorder saw:@"state 2"] && ![wrongName.recorder saw:@"state 2"],
               @"a refused client connected");
    [wrongName.client stop];
    [forged.client stop];

    // With no host reachable, release answers NO once nobody is left to ask.
    NSArray *nowhere = @[ @{@"id" : @"dead-hk", @"url" : [NSString stringWithFormat:@"ws://127.0.0.1:%ld/v1",
                                                                                    (long)SZFHClosedPort()],
                            @"priority" : @1} ];
    SZFHLiveClient *lonely = SZFHLive(server, nowhere, [SZFHTestIdentity randomIdentity]);
    SZFHExpect(!SZFHRelease(lonely), @"release with no host reported success");

    SZFHRunLiveDeviceTests(server);
    SZFHStopServer(server);
}
