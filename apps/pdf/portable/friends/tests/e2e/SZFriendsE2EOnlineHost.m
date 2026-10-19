// The online scenarios' world (SZFriendsE2EOnline.h): the local Node host with protocol 2 and the relay on, coturn at
// the cap, and two helpers' stores seeded as friends.

#import "SZFriendsE2EOnline.h"

#import <sodium.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <signal.h>
#include <sys/time.h>
#include <unistd.h>

#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperServices.h"

static NSString *const kTurnSecret = @"szfriends-e2e-online-turn-secret-0123456789";
static NSString *const kEventsPassword = @"e2eOnlineEventsPassword0123456789ab";
// The host's relay cap (ADR 0010): 5 Mbit/s per allocation.
static NSString *const kMaxBps = @"625000";

static NSString *Base64URL(NSData *data) {
    NSString *text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

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

// en0's IPv4 address, which coturn relays from; loopback when en0 has none.
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

static void StopTask(NSTask *task) {
    if (task == nil) return;
    if (task.isRunning) [task terminate];
    if (!SZFE2EWaitUntil(5, ^BOOL { return !task.isRunning; })) kill(task.processIdentifier, SIGKILL);
    [task waitUntilExit];
    SZFE2EUntrackPID(task.processIdentifier);
}

// coturn's configuration from the host's own generator (src/coturn-config.js), as production writes it, with the
// test allowances test/coturn-run.js takes: loopback peers allowed (still only the relay's own address, as the
// deny-all leaves nothing else) and a pidfile of its own. Relaying from en0's address keeps every relayed path relay
// to relay, which is all the generated configuration lets through. Nil when node or the generator refuses.
static NSString *GeneratedCoturnConfig(NSString *serverDir, NSString *directory, uint16_t port, NSString *relay) {
    uint16_t minPort = (uint16_t)(50000 + arc4random_uniform(10000));
    NSDictionary *options = @{
        @"realm" : @"friends.test", @"secret" : kTurnSecret, @"listeningIps" : @[ @"127.0.0.1" ],
        @"relayIps" : @[ relay ], @"listeningPort" : @(port), @"minPort" : @(minPort), @"maxPort" : @(minPort + 63),
        @"test" : @{@"allowLoopbackPeers" : @YES,
                    @"pidfile" : [directory stringByAppendingPathComponent:@"turnserver.pid"]},
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:options options:0 error:NULL];
    NSTask *node = [NSTask new];
    node.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    NSString *script = @"const m = await import(process.argv[1]); "
                       @"process.stdout.write(m.coturnConfig(JSON.parse(process.argv[2])));";
    node.arguments = @[ @"node", @"--input-type=module", @"-e", script,
                        [serverDir stringByAppendingPathComponent:@"src/coturn-config.js"],
                        [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ];
    NSPipe *output = [NSPipe pipe];
    node.standardOutput = output;
    node.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![node launchAndReturnError:NULL]) return nil;
    NSData *text = [output.fileHandleForReading readDataToEndOfFile];
    [node waitUntilExit];
    return node.terminationStatus == 0 ? [[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding] : nil;
}

static NSTask *StartCoturn(NSString *binary, NSString *serverDir, NSString *directory, uint16_t port) {
    NSString *relay = RelayAddress();
    NSString *text = GeneratedCoturnConfig(serverDir, directory, port, relay);
    // The production limits, which the relay scenario then runs under: 5 Mbit/s, two allocations per credential,
    // and peers on the relay's own address only.
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    if (![lines containsObject:[@"max-bps=" stringByAppendingString:kMaxBps]] ||
        ![lines containsObject:@"user-quota=2"] ||
        ![lines containsObject:[@"allowed-peer-ip=" stringByAppendingString:relay]] ||
        ![lines containsObject:@"denied-peer-ip=0.0.0.0-255.255.255.255"]) {
        SZFE2EFail(__FILE__, __LINE__, "coturn runs the host's generated configuration",
                   text ?: @"node could not generate it");
        return nil;
    }
    NSString *config = [directory stringByAppendingPathComponent:@"turnserver.conf"];
    [text writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:binary];
    task.arguments = @[ @"-c", config ];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return nil;
    SZFE2ETrackPID(task.processIdentifier);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (task.isRunning && deadline.timeIntervalSinceNow > 0) {
        if (STUNAnswers(port)) return task;
    }
    StopTask(task);
    return nil;
}

// Why the host cannot run here, or nil.
static NSString *HostUnavailable(NSString *serverDir) {
    if (serverDir.length == 0) return @"SZFRIENDS_E2E_HOST_SERVER_DIR is not set";
    NSString *ws = [serverDir stringByAppendingPathComponent:@"node_modules/ws/package.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:ws]) return @"the host service's node_modules are missing";
    NSTask *probe = [[NSTask alloc] init];
    probe.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    probe.arguments = @[ @"node", @"-e", @"process.stdout.write(process.versions.node)" ];
    NSPipe *output = [NSPipe pipe];
    probe.standardOutput = output;
    probe.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![probe launchAndReturnError:NULL]) return @"node is not on PATH";
    [probe waitUntilExit];
    NSString *version = [[NSString alloc] initWithData:[output.fileHandleForReading readDataToEndOfFile]
                                              encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
    NSInteger major = parts.count > 0 ? parts[0].integerValue : 0, minor = parts.count > 1 ? parts[1].integerValue : 0;
    if (probe.terminationStatus != 0 || major < 22 || (major == 22 && minor < 16)) {
        return [NSString stringWithFormat:@"Node.js 22.16 or later is needed (found %@)", version ?: @"none"];
    }
    return nil;
}

// The ADR 0005 envelope for one host that is also the relay, with the STUN and TURN URIs of HOST-PROTOCOL-ONLINE.md.
static NSData *SignedList(NSInteger version, NSString *url, NSArray<NSString *> *ice, NSData *hostKey,
                          const unsigned char *secretKey) {
    NSDictionary *payload = @{
        @"version" : @(version), @"issued_at" : @"2026-10-14T00:00:00Z", @"new_id_words" : @2,
        @"hosts" : @[ @{@"id" : @"main-hk", @"role" : @"both", @"urls" : @[ url ], @"turn_uris" : ice,
                        @"region" : @"Test", @"priority" : @1, @"public_key" : Base64URL(hostKey)} ]
    };
    NSData *payloadBytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableData *signedBytes = [[@"SZFriends host list v1\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:payloadBytes];
    unsigned char signature[crypto_sign_BYTES];
    crypto_sign_detached(signature, NULL, signedBytes.bytes, signedBytes.length, secretKey);
    NSDictionary *envelope = @{@"payload" : Base64URL(payloadBytes),
                               @"sigs" : @[ @{@"key" : @"primary",
                                              @"sig" : Base64URL([NSData dataWithBytes:signature length:64])} ]};
    return [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
}

static NSString *HostKeyPEM(NSData *seed) {
    static const unsigned char prefix[] = {0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
                                           0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20};
    NSMutableData *der = [NSMutableData dataWithBytes:prefix length:sizeof prefix];
    [der appendData:seed];
    return [NSString stringWithFormat:@"-----BEGIN PRIVATE KEY-----\n%@\n-----END PRIVATE KEY-----\n",
                                      [der base64EncodedStringWithOptions:0]];
}

@implementation SZFE2EOnlineHost {
    NSTask *_host;
    NSTask *_coturn;
    NSString *_listPath, *_keysPath;
}

+ (instancetype)startInWorld:(SZFE2EWorld *)world relay:(BOOL)relay skip:(NSString **)skip {
    NSString *serverDir = NSProcessInfo.processInfo.environment[@"SZFRIENDS_E2E_HOST_SERVER_DIR"];
    NSString *coturn = NSProcessInfo.processInfo.environment[@"FRIENDS_TEST_COTURN"];
    *skip = HostUnavailable(serverDir);
    if (*skip == nil && relay && (coturn.length == 0 || ![[NSFileManager defaultManager]
                                                            isExecutableFileAtPath:coturn])) {
        *skip = @"set FRIENDS_TEST_COTURN to a turnserver built from pinned source";
    }
    if (*skip != nil) return nil;
    SZFE2EOnlineHost *online = [[self alloc] init];
    return [online startIn:world.scenarioDirectory serverDir:serverDir coturn:relay ? coturn : nil] ? online : nil;
}

- (BOOL)startIn:(NSString *)directory serverDir:(NSString *)serverDir coturn:(NSString *)coturn {
    uint16_t turnPort = FreeUDPPort(), stunPort = FreeUDPPort();
    if (coturn != nil) {
        _coturn = StartCoturn(coturn, serverDir, directory, turnPort);
        if (_coturn == nil) {
            SZFE2EFail(__FILE__, __LINE__, "coturn answers STUN on loopback", coturn);
            return NO;
        }
    }
    NSArray<NSString *> *ice = @[
        [NSString stringWithFormat:@"stun:127.0.0.1:%u", turnPort], [NSString stringWithFormat:@"stun:127.0.0.1:%u",
                                                                                               stunPort],
        [NSString stringWithFormat:@"turn:127.0.0.1:%u?transport=udp", turnPort]
    ];
    unsigned char publicKey[crypto_sign_PUBLICKEYBYTES], secretKey[crypto_sign_SECRETKEYBYTES];
    crypto_sign_keypair(publicKey, secretKey);
    unsigned char seed[crypto_sign_SEEDBYTES], hostPublic[crypto_sign_PUBLICKEYBYTES];
    unsigned char hostSecret[crypto_sign_SECRETKEYBYTES];
    randombytes_buf(seed, sizeof seed);
    crypto_sign_seed_keypair(hostPublic, hostSecret, seed);
    NSData *hostKey = [NSData dataWithBytes:hostPublic length:32], *pinned = [NSData dataWithBytes:publicKey length:32];
    NSString *serviceList = [directory stringByAppendingPathComponent:@"host-list.json"];
    [SignedList(1, @"ws://127.0.0.1:9/v1", ice, hostKey, secretKey) writeToFile:serviceList atomically:YES];
    NSString *keyFile = [directory stringByAppendingPathComponent:@"host-key.pem"];
    [HostKeyPEM([NSData dataWithBytes:seed length:sizeof seed]) writeToFile:keyFile atomically:YES
                                                                   encoding:NSUTF8StringEncoding
                                                                      error:NULL];
    NSInteger port = [self startHost:serverDir directory:directory list:serviceList key:keyFile pinned:pinned
                            stunPort:stunPort turnURI:ice[2]];
    if (port <= 0) return NO;
    // The helpers' list is newer than the service's own, so the service never replaces it with one naming port 9.
    _listPath = [directory stringByAppendingPathComponent:@"helper-list.json"];
    _keysPath = [directory stringByAppendingPathComponent:@"helper-keys.json"];
    NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%ld/v1", (long)port];
    [SignedList(2, url, ice, hostKey, secretKey) writeToFile:_listPath atomically:YES];
    NSDictionary *keys = @{@"keys" : @[ @{@"name" : @"primary", @"public_key" : Base64URL(pinned), @"test" : @YES} ]};
    [[NSJSONSerialization dataWithJSONObject:keys options:0 error:NULL] writeToFile:_keysPath atomically:YES];
    return YES;
}

- (NSInteger)startHost:(NSString *)serverDir
             directory:(NSString *)directory
                  list:(NSString *)list
                   key:(NSString *)key
                pinned:(NSData *)pinned
              stunPort:(uint16_t)stunPort
               turnURI:(NSString *)turnURI {
    _host = [[NSTask alloc] init];
    _host.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    _host.arguments = @[ @"node", @"--disable-warning=ExperimentalWarning",
                         [serverDir stringByAppendingPathComponent:@"src/main.js"] ];
    _host.environment = @{
        @"PATH" : NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        @"FRIENDS_HOST_ID" : @"main-hk", @"FRIENDS_LISTEN_HOST" : @"127.0.0.1", @"FRIENDS_LISTEN_PORT" : @"0",
        @"FRIENDS_DATA_DIR" : [directory stringByAppendingPathComponent:@"host-data"],
        @"FRIENDS_PINNED_KEYS" : Base64URL(pinned), @"FRIENDS_HOST_LIST_FILE" : list, @"FRIENDS_HOST_KEY_FILE" : key,
        @"FRIENDS_IDENTITY_SECRET" : @"friends-e2e-online-identity-secret-0123456789",
        @"FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY" : @"100", @"FRIENDS_MAX_CONNECTIONS_PER_ADDRESS" : @"100",
        // Protocol 2 with its own STUN port, and the relay's credentials for the coturn above.
        @"FRIENDS_M2" : @"on", @"FRIENDS_STUN_PORTS" : [NSString stringWithFormat:@"%u", stunPort],
        @"FRIENDS_STUN_LISTEN" : @"127.0.0.1", @"FRIENDS_TURN_URIS" : turnURI, @"FRIENDS_RELAY" : @"on",
        @"FRIENDS_TURN_SECRET" : kTurnSecret, @"FRIENDS_TURN_REALM" : @"friends.test",
        @"FRIENDS_TURN_LISTEN_IPS" : @"127.0.0.1", @"FRIENDS_TURN_EVENTS_PASSWORD" : kEventsPassword,
        @"FRIENDS_TURN_EVENTS_PORT" : @"0", @"FRIENDS_TURN_MAX_SESSION_S" : @"0",
    };
    NSPipe *output = [NSPipe pipe];
    _host.standardOutput = output;
    NSString *errors = [directory stringByAppendingPathComponent:@"host-stderr.log"];
    [[NSFileManager defaultManager] createFileAtPath:errors contents:nil attributes:nil];
    _host.standardError = [NSFileHandle fileHandleForWritingAtPath:errors];
    if (![_host launchAndReturnError:NULL]) return 0;
    SZFE2ETrackPID(_host.processIdentifier);
    // The service logs one JSON line per event; "listening" carries the port it bound.
    NSMutableData *buffer = [NSMutableData data];
    __block NSInteger port = 0;
    output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        @synchronized(buffer) {
            [buffer appendData:chunk];
            NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *event = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
                if ([event isKindOfClass:[NSDictionary class]] && [event[@"event"] isEqual:@"listening"]) {
                    port = [event[@"port"] integerValue];
                }
            }
            if (chunk.length == 0) handle.readabilityHandler = nil;
        }
    };
    SZFE2EWaitUntil(10, ^BOOL {
        @synchronized(buffer) {
            return port > 0;
        }
    });
    NSInteger bound = 0;
    @synchronized(buffer) {
        bound = port;
    }
    if (bound <= 0) {
        NSString *log = [NSString stringWithContentsOfFile:errors encoding:NSUTF8StringEncoding error:NULL];
        SZFE2EFail(__FILE__, __LINE__, "the host service listens on loopback", log ?: @"no errors logged");
    }
    return bound;
}

- (NSDictionary<NSString *, NSString *> *)environmentForHelper:(NSString *)name {
    (void)name;
    return @{
        @"SZFRIENDS_TEST_HOST_LIST" : _listPath, @"SZFRIENDS_TEST_HOST_KEYS" : _keysPath,
        // A Bonjour type of its own: these friends are never nearby.
        @"SZFRIENDS_TEST_SERVICE_TYPE" : [NSString stringWithFormat:@"_szfo%08x._tcp", arc4random()],
    };
}

- (void)stop {
    StopTask(_host);
    StopTask(_coturn);
    _host = _coturn = nil;
}

@end

#pragma mark - Friends without ever meeting nearby

static SZFriendsHelperServices *OpenServices(SZFE2EHelper *helper) {
    NSString *state = helper.stateDirectory;
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSDictionary *env = @{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"file"};
    SZFriendsStatePaths *paths = [[SZFriendsStatePaths alloc] initWithStateDirectory:state];
    if (![paths prepareStateDirectoryWithError:NULL] || ![paths prepareDirectoriesWithError:NULL]) return nil;
    SZFriendsHelperServices *services =
        [[SZFriendsHelperServices alloc] initWithPaths:paths environment:env
                                             resources:[SZFriendsHelperResources loadFromBundle:[NSBundle mainBundle]]];
    [services open];
    return services.store != nil && services.identity != nil ? services : nil;
}

static NSString *SaveFriend(SZFriendsHelperServices *services, SZFriendsHelperServices *other, NSString *name) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = SZFriendsNewIdentifier();
    person.identityKey = other.identity.publicKey;
    person.staticKey = other.identity.staticPublicKey;
    person.presenceSecret = other.store.ownPresenceSecret;
    person.name = name;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate date];
    return [services.store savePerson:person error:NULL] ? person.conversationID : nil;
}

BOOL SZFE2EOnlineSeedFriends(SZFE2EHelper *a, SZFE2EHelper *b, NSString **bAtA, NSString **aAtB) {
    SZFriendsHelperServices *servicesA = OpenServices(a), *servicesB = OpenServices(b);
    CHECK(servicesA != nil && servicesB != nil, "both stores open");
    servicesA.store.profileName = @"Ana";
    servicesB.store.profileName = @"Ben";
    *bAtA = SaveFriend(servicesA, servicesB, @"Ben");
    *aAtB = SaveFriend(servicesB, servicesA, @"Ana");
    [servicesA close];
    [servicesB close];
    CHECK(*bAtA != nil && *aAtB != nil, "each holds the other as a friend");
    return YES;
}

NSString *SZFE2EOnlineBlockPath(SZFE2EHelper *helper) {
    return [helper.stateDirectory stringByAppendingPathComponent:@"online-block-direct"];
}
