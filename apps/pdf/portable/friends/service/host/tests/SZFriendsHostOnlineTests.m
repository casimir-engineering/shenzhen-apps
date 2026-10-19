// Protocol 2 against scripted sockets: nothing online unless the welcome says so, the record each period with its
// signature and the host's clock, lookups split and reassembled, sids both ways, relay credentials, and everything
// ending with the connection. No network.

#import "SZFriendsHostHarness.h"
#import "SZFriendsHostOnlineTests.h"

#import <sodium.h>

@implementation SZFHOnlineRecorder {
    NSMutableArray<NSString *> *_events;
    NSMutableArray<SZFriendsHostSignal *> *_incoming;
    NSMapTable<SZFriendsHostSignal *, NSMutableArray<NSData *> *> *_payloads;
}

- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
        _incoming = [NSMutableArray array];
        _payloads = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}

- (void)record:(NSString *)event {
    @synchronized(self) {
        [_events addObject:event];
    }
}

- (NSArray<NSString *> *)events {
    @synchronized(self) {
        return [_events copy];
    }
}

- (BOOL)saw:(NSString *)event {
    return [self.events containsObject:event];
}

- (NSArray<SZFriendsHostSignal *> *)incoming {
    @synchronized(self) {
        return [_incoming copy];
    }
}

- (NSArray<NSData *> *)payloadsOn:(SZFriendsHostSignal *)signal {
    @synchronized(self) {
        return [[_payloads objectForKey:signal] copy] ?: @[];
    }
}

- (void)watch:(SZFriendsHostSignal *)signal {
    @synchronized(self) {
        [_payloads setObject:[NSMutableArray array] forKey:signal];
    }
    __weak SZFHOnlineRecorder *weakSelf = self;
    __weak SZFriendsHostSignal *weakSignal = signal;
    signal.onPayload = ^(NSData *payload) {
        SZFHOnlineRecorder *recorder = weakSelf;
        SZFriendsHostSignal *strongSignal = weakSignal;
        if (!recorder || !strongSignal) return;
        @synchronized(recorder) {
            [[recorder->_payloads objectForKey:strongSignal] addObject:payload];
        }
    };
    signal.onEnd = ^(SZFriendsHostSignalEnd reason) {
        [weakSelf record:SZFHEnded(reason)];
    };
}

- (void)hostOnline:(SZFriendsHostOnline *)online didChangeAvailability:(BOOL)available {
    [self record:[NSString stringWithFormat:@"available %d", available]];
}

- (void)hostOnline:(SZFriendsHostOnline *)online
    didReceiveSignal:(SZFriendsHostSignal *)signal
             payload:(NSData *)payload {
    @synchronized(self) {
        [_incoming addObject:signal];
    }
    [self watch:signal];
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"?";
    [self record:[NSString stringWithFormat:@"incoming %ld %@", (long)signal.via, text]];
}

@end

void SZFHOnQueue(dispatch_queue_t queue, void (^block)(void)) {
    dispatch_sync(queue, block);
}

NSString *SZFHEnded(SZFriendsHostSignalEnd reason) {
    return [NSString stringWithFormat:@"ended %ld", (long)reason];
}

NSData *SZFHUTF8(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// The scripted harness, with main-hk also a relay that lists its TURN URIs.
SZFHHarness *SZFHOnlineHarness(SZFHOnlineRecorder *recorder, NSData *_Nullable (^provider)(void)) {
    SZFHHarness *h = SZFHMakeHarness();
    NSDictionary *mainHost = @{@"id" : @"main-hk", @"url" : @"wss://a.example.test/v1", @"priority" : @1,
                               @"key" : h.mainHost.publicKey};
    NSMutableDictionary *payload = [SZFHPayload(2, @[ mainHost ]) mutableCopy];
    NSMutableDictionary *host = [payload[@"hosts"][0] mutableCopy];
    host[@"role"] = @"both";
    host[@"turn_uris"] = @[ @"stun:h.example.test:3478", @"turn:h.example.test:3478?transport=udp" ];
    payload[@"hosts"] = @[ host ];
    SZFHExpect([h.cache offerSignedList:[h.signer envelopeForPayload:payload] error:NULL], @"relay list refused");
    SZFHOnQueue(h.queue, ^{
        h.client.online.delegate = recorder;
        h.client.online.sealedRecordProvider = provider;
    });
    return h;
}

NSDictionary *SZFHLast(SZFHFakeSocket *socket, NSString *type) {
    for (NSDictionary *sent in socket.sent.reverseObjectEnumerator) {
        if ([sent[@"type"] isEqual:type]) return sent;
    }
    return nil;
}

// Protocol 1 hosts, and protocol 2 hosts with online Friends off, get exactly the check-in they always got.
static void SZFHTestOffline(void) {
    for (id online in @[ [NSNull null], @NO ]) {
        SZFHOnlineRecorder *recorder = [[SZFHOnlineRecorder alloc] init];
        SZFHHarness *h = SZFHOnlineHarness(recorder, ^NSData * { return [NSMutableData dataWithLength:512]; });
        SZFHStart(h);
        SZFHFakeSocket *socket = SZFHSocket(h, 0);
        NSDictionary *checkin = SZFHChallenge(h, socket, @"main-hk");
        SZFHExpect([checkin[@"protocol"] isEqual:@(SZFriendsHostProtocolVersion)] && SZFriendsHostProtocolVersion >= 2,
                   @"the check-in declares protocol 2 or later");
        NSMutableDictionary *fields = [@{@"reservation" : @"reserved", @"friends_id" : @"maple-river"} mutableCopy];
        if (online != [NSNull null]) fields[@"online"] = online;
        SZFHWelcome(h, socket, fields);
        __block BOOL available = YES;
        __block NSError *lookupError = nil;
        SZFHOnQueue(h.queue, ^{
            available = h.client.online.available;
            [h.client.online lookupRendezvousKeys:@[ [NSMutableData dataWithLength:32] ]
                                       completion:^(__unused NSArray *blobs, NSError *error) {
                                           lookupError = error;
                                       }];
        });
        SZFHExpect(!available && recorder.events.count == 0, @"online without the welcome saying so");
        SZFHExpect(lookupError.code == SZFriendsHostOnlineErrorUnavailable, @"a lookup went out offline");
        SZFHExpect(socket.sent.count == 1, @"something besides the check-in was sent: %@", socket.sent);
        [h.client stop];
        SZFHDrain(h.queue);
    }
}

static void SZFHTestRecords(void) {
    SZFHOnlineRecorder *recorder = [[SZFHOnlineRecorder alloc] init];
    NSMutableArray<NSData *> *blobs = [NSMutableArray array];
    SZFHHarness *h = SZFHOnlineHarness(recorder, ^NSData * {
        NSMutableData *blob = [NSMutableData dataWithLength:512];
        randombytes_buf(blob.mutableBytes, blob.length);
        [blobs addObject:blob];
        return blob;
    });
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    // The host's clock is 1,000 s ahead of this Mac's: expiries are in the host's time.
    NSDate *hostTime = [NSDate dateWithTimeIntervalSinceNow:1000];
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    [socket deliver:@{@"type" : @"challenge", @"host_id" : @"main-hk", @"nonce" : SZFHNonce,
                      @"time" : [formatter stringFromDate:hostTime]}];
    SZFHDrain(h.queue);
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river", @"online" : @YES});
    SZFHExpect([recorder.events isEqualToArray:@[ @"available 1" ]], @"events: %@", recorder.events);
    NSDictionary *publish = SZFHLast(socket, @"rdv_publish");
    NSData *sealed = SZFriendsHostBase64URLDecode(publish[@"sealed"], 512);
    long long seq = [publish[@"seq"] longLongValue], expires = [publish[@"expires"] longLongValue];
    SZFHExpect(sealed && [sealed isEqualToData:blobs.lastObject], @"the record is not the provider's blob");
    SZFHExpect(llabs(expires - (long long)(hostTime.timeIntervalSince1970 + 300)) <= 2, @"expiry not in host time");
    long long millis = (long long)([NSDate date].timeIntervalSince1970 * 1000);
    SZFHExpect(seq >= millis - 5000 && seq <= millis, @"seq is not a millisecond clock");
    NSData *rdvKey = SZFriendsHostRendezvousKey(h.identity.publicKey);
    NSData *message = SZFriendsHostRendezvousRecordMessage(@"main-hk", rdvKey, (uint64_t)seq, expires, sealed);
    SZFHExpect(SZFHVerify(SZFriendsHostBase64URLDecode(publish[@"sig"], 64), message,
                          @"SZFriends rendezvous record v1", h.identity.publicKey),
               @"the record signature does not cover host id, rdv key, seq, expiry and the blob");
    // The host names the period its lookups show the record in; the next publish goes in the first half of it.
    long long shownFrom = ((long long)hostTime.timeIntervalSince1970 / 60 + 1) * 60;
    [socket deliver:@{@"type" : @"rdv_published", @"seq" : @(seq), @"accepted" : @YES, @"reason" : [NSNull null],
                      @"shown_from" : @(shownFrom)}];
    SZFHDrain(h.queue);
    __block NSDate *shown = nil;
    SZFHOnQueue(h.queue, ^{
        shown = h.client.online.recordShownFrom;
    });
    SZFHExpect(fabs(shown.timeIntervalSince1970 - (shownFrom - 1000)) < 2, @"shown_from not on this Mac's clock");

    // Lookups: 40 keys go as 32 and 8, and come back in order.
    NSMutableArray<NSData *> *keys = [NSMutableArray array];
    for (int i = 0; i < 40; i++) [keys addObject:[NSMutableData dataWithLength:32]];
    ((uint8_t *)((NSMutableData *)keys[39]).mutableBytes)[0] = 39;
    __block NSArray<NSData *> *found = nil;
    __block NSError *failed = nil;
    SZFHOnQueue(h.queue, ^{
        [h.client.online lookupRendezvousKeys:keys
                                   completion:^(NSArray *result, NSError *error) {
                                       found = result;
                                       failed = error;
                                   }];
    });
    NSArray<NSDictionary *> *lookups = [socket.sent filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:
                                                                                     @"type == 'rdv_lookup'"]];
    SZFHExpect(lookups.count == 2 && [lookups[0][@"keys"] count] == 32 && [lookups[1][@"keys"] count] == 8,
               @"lookup split: %@", [lookups valueForKey:@"keys"]);
    for (NSDictionary *lookup in lookups.reverseObjectEnumerator) {
        NSMutableArray *records = [NSMutableArray array];
        for (NSString *key in lookup[@"keys"]) {
            NSMutableData *blob = [NSMutableData dataWithLength:512];
            NSData *keyBytes = SZFriendsHostBase64URLDecode(key, 32);
            ((uint8_t *)blob.mutableBytes)[0] = keyBytes.length ? ((const uint8_t *)keyBytes.bytes)[0] : 0xff;
            [records addObject:SZFriendsHostBase64URLEncode(blob)];
        }
        [socket deliver:@{@"type" : @"rdv_records", @"req" : lookup[@"req"], @"records" : records}];
    }
    SZFHDrain(h.queue);
    SZFHExpect(found.count == 40 && ((const uint8_t *)found[39].bytes)[0] == 39 && failed == nil, @"lookup result");
    SZFHOnQueue(h.queue, ^{
        [h.client.online lookupRendezvousKeys:@[ [NSData data] ]
                                   completion:^(__unused NSArray *result, NSError *error) {
                                       failed = error;
                                   }];
    });
    SZFHExpect(failed.code == SZFriendsHostOnlineErrorInvalid, @"a short key was looked up");
    SZFHOnQueue(h.queue, ^{
        [h.client.online lookupRendezvousKeys:@[ keys[0] ]
                                   completion:^(__unused NSArray *result, NSError *error) {
                                       failed = error;
                                   }];
    });
    [socket deliver:@{@"type" : @"rdv_records", @"req" : SZFHLast(socket, @"rdv_lookup")[@"req"],
                      @"records" : [NSNull null], @"reason" : @"rate_limited"}];
    SZFHDrain(h.queue);
    SZFHExpect(failed.code == SZFriendsHostOnlineErrorRateLimited, @"a refused lookup: %@", failed);

    // A lookup still waiting when the connection ends fails at once; the online side goes away with it.
    failed = nil;
    SZFHOnQueue(h.queue, ^{
        [h.client.online lookupRendezvousKeys:@[ keys[0] ]
                                   completion:^(__unused NSArray *result, NSError *error) {
                                       failed = error;
                                   }];
    });
    [socket hangUp];
    SZFHDrain(h.queue);
    SZFHExpect(failed.code == SZFriendsHostOnlineErrorUnavailable, @"a pending lookup outlived the connection");
    SZFHExpect([recorder.events.lastObject isEqual:@"available 0"], @"events: %@", recorder.events);
    [h.client stop];
    SZFHDrain(h.queue);
}

void SZFHRunOnlineTests(void) {
    SZFHTestOffline();
    SZFHTestRecords();
    SZFHRunOnlineSignalTests();
}
