// friends-e2e-check: real helpers checking in with the local Node host service (portable/server/friends) on
// loopback, through a list signed with a throwaway key. Never the production host: the list names 127.0.0.1 only,
// and a helper under SZFRIENDS_STATE_DIR refuses any other (SZFriendsHostCheckIn.h). Skipped, with a line saying
// why, when Node.js 22.16 or the service's node_modules are missing.

#import "SZFriendsE2EHost.h"
#import "SZFriendsE2EScenarios.h"

#import <signal.h>
#import <sodium.h>

static NSString *SZFE2EBase64URL(NSData *data) {
    NSString *text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

// The signed envelope of ADR 0005 for one host at `url`, whose replies are signed with `hostKey`.
static NSData *SZFE2ESignedList(NSInteger version, NSString *url, NSData *hostKey, const unsigned char *secretKey) {
    NSDictionary *payload = @{
        @"version" : @(version), @"issued_at" : @"2026-10-12T00:00:00Z", @"new_id_words" : @2,
        @"hosts" : @[ @{@"id" : @"main-hk", @"role" : @"rendezvous", @"urls" : @[ url ], @"turn_uris" : @[],
                        @"region" : @"Test", @"priority" : @1, @"public_key" : SZFE2EBase64URL(hostKey)} ]
    };
    NSData *payloadBytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableData *signedBytes = [[@"SZFriends host list v1\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:payloadBytes];
    unsigned char signature[crypto_sign_BYTES];
    crypto_sign_detached(signature, NULL, signedBytes.bytes, signedBytes.length, secretKey);
    NSDictionary *envelope = @{@"payload" : SZFE2EBase64URL(payloadBytes),
                               @"sigs" : @[ @{@"key" : @"primary",
                                              @"sig" : SZFE2EBase64URL([NSData dataWithBytes:signature length:64])} ]};
    return [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
}

// Why the scenario cannot run here, or nil when it can.
static NSString *SZFE2EHostUnavailable(NSString *serverDir) {
    if (serverDir.length == 0) return @"SZFRIENDS_E2E_HOST_SERVER_DIR is not set";
    NSString *ws = [serverDir stringByAppendingPathComponent:@"node_modules/ws/package.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:ws]) {
        return @"the host service's node_modules are missing (make -C portable friends-host-server-check installs "
               @"them)";
    }
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
        return [NSString stringWithFormat:@"Node.js 22.16 or later is needed (found %@)",
                                          version.length ? version : @"none"];
    }
    return nil;
}

@interface SZFE2EHost : NSObject
@property(nonatomic) NSTask *task;
@property(nonatomic) NSInteger port;
@end

@implementation SZFE2EHost
@end

// PKCS#8 for an Ed25519 seed: a fixed 16-byte prefix, then the seed (the host service's own key file format).
static NSString *SZFE2EHostKeyPEM(NSData *seed) {
    static const unsigned char prefix[] = {0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
                                           0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20};
    NSMutableData *der = [NSMutableData dataWithBytes:prefix length:sizeof prefix];
    [der appendData:seed];
    return [NSString stringWithFormat:@"-----BEGIN PRIVATE KEY-----\n%@\n-----END PRIVATE KEY-----\n",
                                      [der base64EncodedStringWithOptions:0]];
}

static SZFE2EHost *SZFE2EStartHost(NSString *serverDir, NSString *directory, NSData *publicKey, NSData *list,
                                   NSData *hostSeed) {
    NSString *listFile = [directory stringByAppendingPathComponent:@"host-list.json"];
    [list writeToFile:listFile atomically:YES];
    NSString *keyFile = [directory stringByAppendingPathComponent:@"host-key.pem"];
    [SZFE2EHostKeyPEM(hostSeed) writeToFile:keyFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    SZFE2EHost *host = [[SZFE2EHost alloc] init];
    host.task = [[NSTask alloc] init];
    host.task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    host.task.arguments = @[ @"node", @"--disable-warning=ExperimentalWarning",
                             [serverDir stringByAppendingPathComponent:@"src/main.js"] ];
    host.task.environment = @{
        @"PATH" : NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        @"FRIENDS_HOST_ID" : @"main-hk",
        @"FRIENDS_LISTEN_HOST" : @"127.0.0.1",
        @"FRIENDS_LISTEN_PORT" : @"0",
        @"FRIENDS_DATA_DIR" : [directory stringByAppendingPathComponent:@"host-data"],
        @"FRIENDS_PINNED_KEYS" : SZFE2EBase64URL(publicKey),
        @"FRIENDS_HOST_LIST_FILE" : listFile,
        @"FRIENDS_HOST_KEY_FILE" : keyFile,
        @"FRIENDS_IDENTITY_SECRET" : @"friends-e2e-identity-secret-0123456789abcdef",
        // Every helper here connects from 127.0.0.1; the per-address limits have their own tests in the service.
        @"FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY" : @"100",
        @"FRIENDS_MAX_CONNECTIONS_PER_ADDRESS" : @"100",
    };
    NSPipe *output = [NSPipe pipe];
    host.task.standardOutput = output;
    NSString *errors = [directory stringByAppendingPathComponent:@"host-stderr.log"];
    [[NSFileManager defaultManager] createFileAtPath:errors contents:nil attributes:nil];
    host.task.standardError = [NSFileHandle fileHandleForWritingAtPath:errors];
    if (![host.task launchAndReturnError:NULL]) return nil;
    SZFE2ETrackPID(host.task.processIdentifier);
    // The service logs one JSON line per event; the first, "listening", carries the port it bound.
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
    @synchronized(buffer) {
        host.port = port;
    }
    return host;
}

static void SZFE2EStopHost(SZFE2EHost *host) {
    if (host.task.isRunning) [host.task terminate];
    if (!SZFE2EWaitUntil(5, ^BOOL { return !host.task.isRunning; })) kill(host.task.processIdentifier, SIGKILL);
    [host.task waitUntilExit];
    SZFE2EUntrackPID(host.task.processIdentifier);
}

NSDictionary *SZFE2EProfileID(SZFE2EClient *client, NSString *subscription) {
    return [client dataFor:subscription][@"id"];
}

NSString *SZFE2EAttestationPath(SZFE2EHelper *helper) {
    return [helper.stateDirectory stringByAppendingPathComponent:@"host-attestation.json"];
}

NSString *SZFE2EReservedAndAttested(SZFE2EClient *client, SZFE2EHelper *helper) {
    NSString *profile = [client subscribe:@"profile" params:nil];
    BOOL done = SZFE2EWaitUntil(10, ^BOOL {
        return [SZFE2EProfileID(client, profile)[@"state"] isEqual:@"reserved"] &&
               [[NSFileManager defaultManager] fileExistsAtPath:SZFE2EAttestationPath(helper)];
    });
    if (!done) SZFE2EFail(__FILE__, __LINE__, "reserved and attested", [SZFE2EProfileID(client, profile) description]);
    NSString *friendsID = done ? SZFE2EProfileID(client, profile)[@"friends_id"] : nil;
    [client intent:@"unsubscribe" fields:@{@"subscription" : profile}];
    return friendsID;
}

@interface SZFE2ELocalHost ()
@property(nonatomic) SZFE2EHost *host;
@property(nonatomic, readwrite) NSDictionary<NSString *, NSString *> *helperEnvironment;
@end

@implementation SZFE2ELocalHost

+ (nullable instancetype)startInWorld:(SZFE2EWorld *)world skip:(NSString **)skip {
    NSString *serverDir = NSProcessInfo.processInfo.environment[@"SZFRIENDS_E2E_HOST_SERVER_DIR"];
    *skip = SZFE2EHostUnavailable(serverDir);
    if (*skip != nil) return nil;
    unsigned char publicKey[crypto_sign_PUBLICKEYBYTES], secretKey[crypto_sign_SECRETKEYBYTES];
    crypto_sign_keypair(publicKey, secretKey);
    NSData *pinned = [NSData dataWithBytes:publicKey length:sizeof publicKey];
    // The host's own key, which signs its replies and attestations; the list names its public half (ADR 0005).
    unsigned char seed[crypto_sign_SEEDBYTES], hostPublic[crypto_sign_PUBLICKEYBYTES];
    unsigned char hostSecret[crypto_sign_SECRETKEYBYTES];
    randombytes_buf(seed, sizeof seed);
    crypto_sign_seed_keypair(hostPublic, hostSecret, seed);
    NSData *hostKey = [NSData dataWithBytes:hostPublic length:sizeof hostPublic];
    NSData *hostSeed = [NSData dataWithBytes:seed length:sizeof seed];
    NSString *directory = world.scenarioDirectory;
    SZFE2EHost *host = SZFE2EStartHost(serverDir, directory, pinned,
                                       SZFE2ESignedList(1, @"ws://127.0.0.1:9/v1", hostKey, secretKey), hostSeed);
    if (host.port <= 0) {
        if (host != nil) SZFE2EStopHost(host);
        NSString *log = [directory stringByAppendingPathComponent:@"host-stderr.log"];
        NSString *errors = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:NULL];
        SZFE2EFail(__FILE__, __LINE__, "the host service listens on loopback", errors ?: @"no errors logged");
        return nil;
    }
    // The helpers' list is newer than the service's own, so the service never replaces it with one naming port 9.
    NSString *url = [NSString stringWithFormat:@"ws://127.0.0.1:%ld/v1", (long)host.port];
    NSString *listPath = [directory stringByAppendingPathComponent:@"helper-list.json"];
    NSString *keysPath = [directory stringByAppendingPathComponent:@"helper-keys.json"];
    [SZFE2ESignedList(2, url, hostKey, secretKey) writeToFile:listPath atomically:YES];
    NSDictionary *keys =
        @{@"keys" : @[ @{@"name" : @"primary", @"public_key" : SZFE2EBase64URL(pinned), @"test" : @YES} ]};
    [[NSJSONSerialization dataWithJSONObject:keys options:0 error:NULL] writeToFile:keysPath atomically:YES];
    SZFE2ELocalHost *local = [[SZFE2ELocalHost alloc] init];
    local.host = host;
    local.helperEnvironment = @{@"SZFRIENDS_TEST_HOST_LIST" : listPath, @"SZFRIENDS_TEST_HOST_KEYS" : keysPath};
    return local;
}

- (void)stop {
    if (self.host != nil) SZFE2EStopHost(self.host);
    self.host = nil;
}

@end

// The orchestration open issue: check-in had no end-to-end test. Reservation at first contact, a collision that
// renames the newcomer (and tells them), and the release that Reset Friends sends, against the real service.
BOOL SZFE2EScenarioHostCheckIn(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2ELocalHost *host = [SZFE2ELocalHost startInWorld:world skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip host check-in: %s\n", why.UTF8String);
        return why != nil;
    }
    NSDictionary *env = host.helperEnvironment;
    BOOL ok = NO;
    @try {
        SZFE2EHelper *helperA = [world helperNamed:@"a"];
        helperA.extraEnvironment = env;
        CHECK([helperA start]);
        SZFE2EClient *a = [SZFE2EClient clientForHelper:helperA];
        CHECK([a.welcome[@"capabilities"] containsObject:@"host.checkin"], "%@", a.welcome[@"capabilities"]);
        NSString *profileA = [a subscribe:@"profile" params:nil];
        CHECK(SZFE2EWaitUntil(10, ^BOOL { return [SZFE2EProfileID(a, profileA)[@"state"] isEqual:@"reserved"]; }),
              "A's ID is reserved at first contact: %@", SZFE2EProfileID(a, profileA));
        NSString *taken = SZFE2EProfileID(a, profileA)[@"friends_id"];

        NSMutableDictionary *envB = [env mutableCopy];
        envB[@"SZFRIENDS_E2E_FRIENDS_ID"] = taken;
        SZFE2EHelper *helperB = [world helperNamed:@"b"];
        helperB.extraEnvironment = envB;
        CHECK([helperB start]);
        SZFE2EClient *b = [SZFE2EClient clientForHelper:helperB];
        NSString *profileB = [b subscribe:@"profile" params:nil], *listB = [b subscribe:@"list" params:nil];
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  NSDictionary *idB = SZFE2EProfileID(b, profileB);
                  return [idB[@"state"] isEqual:@"changed"] && ![idB[@"friends_id"] isEqual:taken];
              }),
              "the newcomer with a taken ID is renamed: %@", SZFE2EProfileID(b, profileB));
        CHECK([[b dataFor:listB][@"banner"][@"kind"] isEqual:@"id_changed"], "and told: %@", [b dataFor:listB]);

        NSDictionary *reset = [a intent:@"reset_friends" fields:@{@"confirm" : @"reset"}];
        CHECK([reset[@"ok"] boolValue], "A resets: %@", reset);
        CHECK([a waitReady], "A's client is back after the reset");
        profileA = [a subscribe:@"profile" params:nil];
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  NSDictionary *idA = SZFE2EProfileID(a, profileA);
                  return [idA[@"state"] isEqual:@"reserved"] && ![idA[@"friends_id"] isEqual:taken];
              }),
              "the new identity has an ID of its own: %@", SZFE2EProfileID(a, profileA));

        NSMutableDictionary *envC = [env mutableCopy];
        envC[@"SZFRIENDS_E2E_FRIENDS_ID"] = taken;
        SZFE2EHelper *helperC = [world helperNamed:@"c"];
        helperC.extraEnvironment = envC;
        CHECK([helperC start]);
        SZFE2EClient *c = [SZFE2EClient clientForHelper:helperC];
        NSString *profileC = [c subscribe:@"profile" params:nil];
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  NSDictionary *idC = SZFE2EProfileID(c, profileC);
                  return [idC[@"state"] isEqual:@"reserved"] && [idC[@"friends_id"] isEqual:taken];
              }),
              "the reset released the old ID, so it is free again: %@", SZFE2EProfileID(c, profileC));
        ok = YES;
    } @finally {
        [host stop];
    }
    return ok;
}
