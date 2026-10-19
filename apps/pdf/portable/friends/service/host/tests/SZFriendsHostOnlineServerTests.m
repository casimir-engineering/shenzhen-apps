// Protocol 2 against the Node host service (portable/server/friends/) with FRIENDS_M2 and FRIENDS_RELAY on, on
// 127.0.0.1 with throwaway keys and its STUN responder on a loopback port of its choosing; coturn is not started (no
// relay traffic here, only credentials). The service's clock runs over an hour ahead of this Mac's, so records are
// accepted only when the client keeps their expiry in the host's time, and its 60 s lookup period is aligned to end
// about 8 s after it starts, so a record shows within the test's bounded waits. Then a protocol 1-era host
// (FRIENDS_M2 off): the client checks in as before and sends nothing online.

#import "SZFriendsHostOnlineTests.h"

#import <CommonCrypto/CommonHMAC.h>
#import <signal.h>

static NSString *const SZFHOnlineTurnSecret = @"online-test-turn-secret-0123456789abcdef";
static NSString *const SZFHOnlineTurnURI = @"turn:127.0.0.1:3478?transport=udp";
static NSTask *SZFHOnlineServer;

static void SZFHStopOnlineServerAtExit(void) {
    if (SZFHOnlineServer.isRunning) kill(SZFHOnlineServer.processIdentifier, SIGKILL);
}

@interface SZFHOnlineHost : NSObject
@property(nonatomic) NSTask *task;
@property(nonatomic) NSInteger port;
@property(nonatomic) NSString *dir;
@property(nonatomic) SZFHSigner *signer;
@property(nonatomic) SZFHSigner *hostKey;
@end

@implementation SZFHOnlineHost
@end

// `clockOffset` (seconds, whole milliseconds) is added to the service's Date.now through a preloaded module.
static SZFHOnlineHost *SZFHStartOnlineHost(BOOL online, NSTimeInterval clockOffset) {
    SZFHOnlineHost *host = [[SZFHOnlineHost alloc] init];
    host.signer = [SZFHSigner randomSigner];
    host.hostKey = [SZFHSigner randomSigner];
    host.dir = SZFHTempDir();
    NSString *listFile = [host.dir stringByAppendingPathComponent:@"list.json"];
    NSString *keyFile = [host.dir stringByAppendingPathComponent:@"host-key.pem"];
    [[host.signer envelopeForPayload:SZFHPayload(1, @[ @{@"id" : @"main-hk", @"url" : @"ws://127.0.0.1:9/v1",
                                                          @"priority" : @1, @"key" : host.hostKey.publicKey} ])]
        writeToFile:listFile
         atomically:YES];
    [SZFHPrivateKeyPEM(host.hostKey) writeToFile:keyFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSMutableDictionary *env = [@{
        @"PATH" : SZFHEnv(@"PATH") ?: @"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        @"FRIENDS_HOST_ID" : @"main-hk",
        @"FRIENDS_LISTEN_HOST" : @"127.0.0.1",
        @"FRIENDS_LISTEN_PORT" : @"0",
        @"FRIENDS_DATA_DIR" : [host.dir stringByAppendingPathComponent:@"data"],
        @"FRIENDS_PINNED_KEYS" : SZFriendsHostBase64URLEncode(host.signer.publicKey),
        @"FRIENDS_HOST_LIST_FILE" : listFile,
        @"FRIENDS_HOST_KEY_FILE" : keyFile,
        @"FRIENDS_IDENTITY_SECRET" : @"host-online-test-identity-secret-0123456789",
        @"FRIENDS_DASHBOARD_PASSWORD" : @"host-online-test-password",
        @"FRIENDS_DASHBOARD_SOCKET" : [host.dir stringByAppendingPathComponent:@"data/dashboard.sock"],
        @"FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY" : @"100",
        @"FRIENDS_MAX_CONNECTIONS_PER_ADDRESS" : @"100",
    } mutableCopy];
    if (online) {
        [env addEntriesFromDictionary:@{
            @"FRIENDS_M2" : @"on",
            @"FRIENDS_RELAY" : @"on",
            @"FRIENDS_STUN_LISTEN" : @"127.0.0.1",
            @"FRIENDS_STUN_PORTS" : @"0",
            @"FRIENDS_TURN_SECRET" : SZFHOnlineTurnSecret,
            @"FRIENDS_TURN_REALM" : @"friends.test",
            @"FRIENDS_TURN_LISTEN_IPS" : @"127.0.0.1",
            @"FRIENDS_TURN_EVENTS_PASSWORD" : @"online-test-events-password-0123",
            @"FRIENDS_TURN_EVENTS_LISTEN" : @"127.0.0.1",
            @"FRIENDS_TURN_EVENTS_PORT" : @"0",
        }];
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    NSString *preload = [NSString stringWithFormat:@"--import=data:text/javascript,%@%lld",
                                                   @"const r=Date.now;Date.now=()=>r()+",
                                                   (long long)llround(clockOffset * 1000)];
    task.arguments = @[ @"node", @"--disable-warning=ExperimentalWarning", preload,
                        [SZFHEnv(@"SZFRIENDS_HOST_SERVER_DIR") stringByAppendingPathComponent:@"src/main.js"] ];
    task.environment = env;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithStandardError];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        SZFHFail(__FILE__, __LINE__, @"could not start node: %@", error);
        return nil;
    }
    SZFHOnlineServer = task;
    host.task = task;
    __block NSInteger port = 0;
    NSMutableData *buffer = [NSMutableData data];
    output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        @synchronized(buffer) {
            [buffer appendData:chunk];
            NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
                if ([event isKindOfClass:[NSDictionary class]] && [event[@"event"] isEqual:@"listening"]) {
                    port = [event[@"port"] integerValue];
                }
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
    @synchronized(buffer) {
        host.port = port;
    }
    return host;
}

static void SZFHStopOnlineHost(SZFHOnlineHost *host) {
    [host.task terminate];
    if (!SZFHWaitUntil(5, ^BOOL {
            return !host.task.isRunning;
        })) {
        kill(host.task.processIdentifier, SIGKILL);
    }
}

@interface SZFHOnlineClient : NSObject
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) SZFriendsCheckInClient *client;
@property(nonatomic) SZFHRecorder *recorder;
@property(nonatomic) SZFHOnlineRecorder *online;
@property(nonatomic) SZFHTestIdentity *identity;
@property(nonatomic) NSMutableArray<NSData *> *published; // every blob handed to the client, newest last
@end

@implementation SZFHOnlineClient
@end

static SZFHOnlineClient *SZFHOnlineLive(SZFHOnlineHost *host, NSString *friendsID) {
    SZFHOnlineClient *live = [[SZFHOnlineClient alloc] init];
    live.queue = dispatch_queue_create("szfh.online", DISPATCH_QUEUE_SERIAL);
    live.identity = [SZFHTestIdentity randomIdentity];
    live.published = [NSMutableArray array];
    NSMutableDictionary *entry = [SZFHPayload(1, @[ @{@"id" : @"main-hk", @"priority" : @1,
                                                      @"url" : [NSString stringWithFormat:@"ws://127.0.0.1:%ld/v1",
                                                                                          (long)host.port],
                                                      @"key" : host.hostKey.publicKey} ])[@"hosts"][0] mutableCopy];
    entry[@"role"] = @"both";
    entry[@"turn_uris"] = @[ @"stun:127.0.0.1:3478", SZFHOnlineTurnURI ];
    NSMutableDictionary *payload = [SZFHPayload(1, @[]) mutableCopy];
    payload[@"hosts"] = @[ entry ];
    NSString *cachePath = [SZFHTempDir() stringByAppendingPathComponent:@"hosts.json"];
    SZFriendsHostListCache *cache = [[SZFriendsHostListCache alloc] initWithCachePath:cachePath
                                                                        bootstrapData:[host.signer
                                                                                          envelopeForPayload:payload]
                                                                           pinnedKeys:@[ host.signer.publicKey ]];
    live.client = [[SZFriendsCheckInClient alloc] initWithListCache:cache
                                                           identity:live.identity.asIdentity
                                                         appVersion:@"26.10.14-1"
                                                      socketFactory:SZFriendsHostWebSocketFactory(live.queue)
                                                              queue:live.queue];
    live.client.watchesNetworkPath = NO;
    live.client.connectTimeout = 3;
    live.recorder = [[SZFHRecorder alloc] init];
    live.client.delegate = live.recorder;
    live.online = [[SZFHOnlineRecorder alloc] init];
    __weak SZFHOnlineClient *weak = live;
    SZFHOnQueue(live.queue, ^{
        live.client.online.delegate = live.online;
        live.client.online.sealedRecordProvider = ^NSData * {
            NSMutableData *blob = [NSMutableData dataWithLength:SZFriendsHostSealedRecordLength];
            arc4random_buf(blob.mutableBytes, blob.length);
            @synchronized(weak.published) {
                [weak.published addObject:blob];
            }
            return blob;
        };
    });
    [live.client startWithFriendsIDProvider:^NSString *(NSUInteger collisions) {
        return collisions == 0 ? friendsID : SZFHDrawID(collisions + 30);
    }];
    return live;
}

static NSArray<NSData *> *SZFHLookup(SZFHOnlineClient *live, NSArray<NSData *> *keys, NSError **error) {
    __block NSArray<NSData *> *found = nil;
    __block NSError *failed = nil;
    __block BOOL done = NO;
    SZFHOnQueue(live.queue, ^{
        [live.client.online lookupRendezvousKeys:keys
                                      completion:^(NSArray<NSData *> *blobs, NSError *e) {
                                          found = blobs;
                                          failed = e;
                                          done = YES;
                                      }];
    });
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   __block BOOL finished = NO;
                   SZFHOnQueue(live.queue, ^{
                       finished = done;
                   });
                   return finished;
               }),
               @"no lookup answer");
    if (error) *error = failed;
    return found;
}

static SZFriendsHostSignal *SZFHLiveOpen(SZFHOnlineClient *live, NSDictionary *target, NSData *payload) {
    __block SZFriendsHostSignal *opened = nil;
    SZFHOnQueue(live.queue, ^{
        void (^completion)(SZFriendsHostSignal *, NSError *) = ^(SZFriendsHostSignal *signal, NSError *error) {
            SZFHExpect(signal != nil, @"open failed: %@", error);
            if (signal) [live.online watch:signal];
            opened = signal;
        };
        SZFriendsHostOnline *online = live.client.online;
        if (target[@"rdv"]) [online openToRendezvousKey:target[@"rdv"] payload:payload completion:completion];
        if (target[@"id"]) [online openToFriendsID:target[@"id"] payload:payload completion:completion];
    });
    SZFHWaitUntil(5, ^BOOL {
        __block BOOL done = NO;
        SZFHOnQueue(live.queue, ^{
            done = opened != nil;
        });
        return done;
    });
    return opened;
}

static SZFriendsHostRelayCredentials *SZFHLiveCredentials(SZFHOnlineClient *live, SZFriendsHostSignal *signal,
                                                          NSError **error) {
    __block SZFriendsHostRelayCredentials *result = nil;
    __block NSError *failed = nil;
    __block BOOL done = NO;
    SZFHOnQueue(live.queue, ^{
        [signal requestRelayCredentials:^(SZFriendsHostRelayCredentials *credentials, NSError *e) {
            result = credentials;
            failed = e;
            done = YES;
        }];
    });
    SZFHWaitUntil(5, ^BOOL {
        __block BOOL finished = NO;
        SZFHOnQueue(live.queue, ^{
            finished = done;
        });
        return finished;
    });
    if (error) *error = failed;
    return result;
}

static NSString *SZFHTurnCredential(NSString *username) {
    uint8_t mac[CC_SHA1_DIGEST_LENGTH];
    NSData *key = SZFHUTF8(SZFHOnlineTurnSecret), *message = SZFHUTF8(username);
    CCHmac(kCCHmacAlgSHA1, key.bytes, key.length, message.bytes, message.length, mac);
    return [[NSData dataWithBytes:mac length:sizeof mac] base64EncodedStringWithOptions:0];
}

static BOOL SZFHAvailable(SZFHOnlineClient *live) {
    __block BOOL available = NO;
    SZFHOnQueue(live.queue, ^{
        available = live.client.online.available;
    });
    return available;
}

static NSDate *SZFHShownFrom(SZFHOnlineClient *live) {
    __block NSDate *shown = nil;
    SZFHOnQueue(live.queue, ^{
        shown = live.client.online.recordShownFrom;
    });
    return shown;
}

static void SZFHRunOnlineLiveScenario(SZFHOnlineClient *alice, SZFHOnlineClient *bob) {
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return SZFHAvailable(alice) && SZFHAvailable(bob);
               }),
               @"online never became available: %@ %@", alice.online.events, alice.recorder.events);
    // Accepted only if its expiry was in the host's time, over an hour from this Mac's.
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   return SZFHShownFrom(alice) != nil;
               }),
               @"the host did not accept alice's record");
    NSData *aliceKey = SZFriendsHostRendezvousKey(alice.identity.publicKey);
    NSData *bobKey = SZFriendsHostRendezvousKey(bob.identity.publicKey);
    NSData *nobody = SZFriendsHostRendezvousKey([NSMutableData dataWithLength:32]);
    NSDate *shownFrom = SZFHShownFrom(alice);
    NSError *error = nil;
    NSArray<NSData *> *before = SZFHLookup(bob, @[ aliceKey, nobody ], &error);
    NSArray<NSData *> *again = SZFHLookup(bob, @[ aliceKey, nobody ], NULL);
    SZFHExpect(before.count == 2 && before[0].length == 512 && before[1].length == 512, @"lookup: %@", error);
    if (shownFrom.timeIntervalSinceNow > 1) {
        // Within one period a key always gets the same bytes, whoever is behind it.
        SZFHExpect([before isEqualToArray:again], @"a lookup changed within one period");
        SZFHExpect(![alice.published containsObject:before[0]], @"a record showed in the period it was published in");
    }
    SZFHExpect(shownFrom.timeIntervalSinceNow < 10, @"the record shows only in %.1f s", shownFrom.timeIntervalSinceNow);
    SZFHWaitUntil(10, ^BOOL {
        return shownFrom.timeIntervalSinceNow < -0.5;
    });
    NSArray<NSData *> *after = SZFHLookup(bob, @[ aliceKey, nobody ], NULL);
    @synchronized(alice.published) {
        SZFHExpect(after.count == 2 && [alice.published containsObject:after[0]],
                   @"bob's lookup does not show alice's record");
    }
    SZFHExpect(after.count == 2 && ![after[1] isEqualToData:before[1]], @"the filler did not change with the period");

    // A friend's open, answered: payloads both ways, then relay credentials for both ends.
    SZFriendsHostSignal *call = SZFHLiveOpen(alice, @{@"rdv" : bobKey}, SZFHUTF8(@"hello"));
    NSString *incoming = [NSString stringWithFormat:@"incoming %ld hello", (long)SZFriendsHostSignalViaRendezvous];
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   return [bob.online saw:incoming];
               }),
               @"bob never saw the open: %@", bob.online.events);
    SZFriendsHostSignal *answer = bob.online.incoming.lastObject;
    SZFriendsHostRelayCredentials *early = SZFHLiveCredentials(alice, call, &error);
    SZFHExpect(early == nil && error.code == SZFriendsHostOnlineErrorNotAnswered, @"credentials before an answer");
    SZFHOnQueue(bob.queue, ^{
        [answer sendPayload:SZFHUTF8(@"answer")];
    });
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   return [[alice.online payloadsOn:call] containsObject:SZFHUTF8(@"answer")];
               }),
               @"alice never got the answer");
    SZFHOnQueue(alice.queue, ^{
        [call sendPayload:SZFHUTF8(@"candidates")];
    });
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   return [[bob.online payloadsOn:answer] containsObject:SZFHUTF8(@"candidates")];
               }),
               @"bob never got the second payload");
    SZFriendsHostRelayCredentials *credentials = SZFHLiveCredentials(alice, call, &error);
    NSArray<NSString *> *parts = [credentials.username componentsSeparatedByString:@":"];
    SZFHExpect(parts.count == 2 && [credentials.turnURIs isEqualToArray:@[ SZFHOnlineTurnURI ]] &&
                   [credentials.credential isEqualToString:SZFHTurnCredential(credentials.username)] &&
                   fabs(credentials.expires.timeIntervalSinceNow - 300) < 10,
               @"alice's credentials: %@ %@ %@", credentials.username, credentials.expires, error);
    SZFHExpect(SZFHLiveCredentials(bob, answer, &error) != nil, @"bob's credentials: %@", error);

    // Add by ID online reaches the holder of the ID; a holder that does not answer tells the caller nothing.
    SZFriendsHostSignal *byID = SZFHLiveOpen(alice, @{@"id" : @"otter-moon"}, SZFHUTF8(@"nn"));
    NSString *byIDEvent = [NSString stringWithFormat:@"incoming %ld nn", (long)SZFriendsHostSignalViaFriendsID];
    SZFHExpect(byID && SZFHWaitUntil(5, ^BOOL {
                   return [bob.online saw:byIDEvent];
               }),
               @"the open by Friends ID did not arrive: %@", bob.online.events);
    SZFriendsHostSignal *declined = bob.online.incoming.lastObject;
    SZFHOnQueue(bob.queue, ^{
        [declined close];
    });
    // An open to nobody gets its sid exactly the same way.
    SZFriendsHostSignal *toNobody = SZFHLiveOpen(alice, @{@"rdv" : nobody}, SZFHUTF8(@"hello"));
    SZFHExpect(toNobody.sid.length == 22 && !toNobody.ended, @"an open to nobody");
    usleep(500000);
    SZFHExpect(!byID.ended && ![alice.online saw:SZFHEnded(SZFriendsHostSignalEndClosed)],
               @"the caller learnt that the target did not answer: %@", alice.online.events);
    // An end that answered closes the sid for both.
    SZFHOnQueue(bob.queue, ^{
        [answer close];
    });
    SZFHExpect(SZFHWaitUntil(5, ^BOOL {
                   return call.ended;
               }),
               @"alice's sid did not end when bob closed it: %@", alice.online.events);
    SZFHExpect([alice.online saw:SZFHEnded(SZFriendsHostSignalEndClosed)],
               @"events: %@", alice.online.events);
}

void SZFHRunOnlineServerTests(void) {
    atexit(SZFHStopOnlineServerAtExit);
    // Over an hour ahead, and aligned so the host's period ends about 8 s after it starts.
    NSTimeInterval base = 3600, now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval offset = base + (60 - fmod(now + base + 8, 60));
    SZFHOnlineHost *host = SZFHStartOnlineHost(YES, offset);
    if (host.port > 0) {
        SZFHOnlineClient *alice = SZFHOnlineLive(host, @"cedar-lake");
        SZFHOnlineClient *bob = SZFHOnlineLive(host, @"otter-moon");
        SZFHRunOnlineLiveScenario(alice, bob);
        [alice.client stop];
        [bob.client stop];
        SZFHDrain(alice.queue);
        SZFHDrain(bob.queue);
    }
    if (host) SZFHStopOnlineHost(host);

    // Online Friends off: the welcome says so, and the connection stays exactly a protocol 1 connection (an online
    // message would be an unknown type, closed with 1008).
    host = SZFHStartOnlineHost(NO, 0);
    if (host.port == 0) return;
    SZFHOnlineClient *carol = SZFHOnlineLive(host, @"tulip-field");
    SZFHExpect(SZFHWaitUntil(8, ^BOOL {
                   return [carol.recorder saw:@"reserved tulip-field"];
               }),
               @"no check-in with online Friends off: %@", carol.recorder.events);
    usleep(700000);
    __block BOOL available = YES;
    SZFHOnQueue(carol.queue, ^{
        available = carol.client.online.available;
    });
    NSUInteger connects = [[carol.recorder.events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:
                                                                                  @"SELF == 'state 2'"]] count];
    SZFHExpect(!available && carol.online.events.count == 0 && carol.client.state == SZFriendsHostStateConnected &&
                   connects == 1,
               @"a host without online Friends: %@ %@", carol.online.events, carol.recorder.events);
    [carol.client stop];
    SZFHDrain(carol.queue);
    SZFHStopOnlineHost(host);
}
