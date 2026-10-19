// Connection setup against scripted sockets: opens by key, Friends ID and link; payloads both ways; the 64-message
// limit; how sids end; incoming opens; relay credentials; and every sid ending with the connection. No network.

#import "SZFriendsHostOnlineTests.h"

static NSString *const SZFHSid = @"AAAAAAAAAAAAAAAAAAAAAA";  // 16 bytes
static NSString *const SZFHSid2 = @"AQEBAQEBAQEBAQEBAQEBAQ"; // 16 bytes

static SZFHFakeSocket *SZFHOnlineSocket(SZFHHarness *h) {
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river", @"online" : @YES});
    return socket;
}

static SZFriendsHostSignal *SZFHOpen(SZFHHarness *h, SZFHFakeSocket *socket, NSDictionary *answer,
                                     void (^open)(void (^completion)(SZFriendsHostSignal *, NSError *)),
                                     NSError **error) {
    __block SZFriendsHostSignal *opened = nil;
    __block NSError *failed = nil;
    SZFHOnQueue(h.queue, ^{
        open(^(SZFriendsHostSignal *signal, NSError *e) {
            opened = signal;
            failed = e;
        });
    });
    NSMutableDictionary *reply = [answer mutableCopy];
    reply[@"req"] = SZFHLast(socket, @"sig_open")[@"req"] ?: @0;
    [socket deliver:reply];
    SZFHDrain(h.queue);
    if (error) *error = failed;
    return opened;
}

static void SZFHTestOutgoing(void) {
    SZFHOnlineRecorder *recorder = [[SZFHOnlineRecorder alloc] init];
    SZFHHarness *h = SZFHOnlineHarness(recorder, nil);
    SZFHFakeSocket *socket = SZFHOnlineSocket(h);
    NSData *rdvKey = SZFriendsHostRendezvousKey([NSMutableData dataWithLength:32]);
    SZFriendsHostSignal *signal = SZFHOpen(h, socket, @{@"type" : @"sig_opened", @"sid" : SZFHSid}, ^(id completion) {
        [h.client.online openToRendezvousKey:rdvKey payload:SZFHUTF8(@"hello") completion:completion];
    }, NULL);
    NSDictionary *open = SZFHLast(socket, @"sig_open");
    SZFHExpect([open[@"to"] isEqual:@{@"rdv_key" : SZFriendsHostBase64URLEncode(rdvKey)}] &&
                   [open[@"payload"] isEqual:SZFriendsHostBase64URLEncode(SZFHUTF8(@"hello"))],
               @"sig_open: %@", open);
    SZFHExpect([signal.sid isEqual:SZFHSid] && !signal.incoming && signal.via == SZFriendsHostSignalViaRendezvous,
               @"the opened signal");
    [recorder watch:signal];
    __block BOOL sent = NO;
    SZFHOnQueue(h.queue, ^{
        sent = [signal sendPayload:SZFHUTF8(@"offer")];
    });
    SZFHExpect(sent && [SZFHLast(socket, @"sig_msg") isEqual:(@{@"type" : @"sig_msg", @"v" : @1, @"sid" : SZFHSid,
                                                                @"payload" : SZFriendsHostBase64URLEncode(
                                                                    SZFHUTF8(@"offer"))})],
               @"sig_msg: %@", SZFHLast(socket, @"sig_msg"));
    [socket deliver:@{@"type" : @"sig_msg", @"sid" : SZFHSid, @"payload" : @"YQ"}];  // "a"
    [socket deliver:@{@"type" : @"sig_msg", @"sid" : SZFHSid2, @"payload" : @"eA"}]; // "x", for no sid of ours
    SZFHDrain(h.queue);
    SZFHExpect([[recorder payloadsOn:signal] isEqualToArray:@[ SZFHUTF8(@"a") ]], @"payloads: %@",
               [recorder payloadsOn:signal]);
    // Relay credentials name the TURN URIs of the signed list, never the host's answer.
    __block SZFriendsHostRelayCredentials *credentials = nil;
    __block NSError *credentialError = nil;
    SZFHOnQueue(h.queue, ^{
        [signal requestRelayCredentials:^(SZFriendsHostRelayCredentials *c, NSError *e) {
            credentials = c;
            credentialError = e;
        }];
    });
    NSDictionary *ask = SZFHLast(socket, @"relay_credentials");
    SZFHExpect([ask[@"sid"] isEqual:SZFHSid], @"relay_credentials: %@", ask);
    [socket deliver:@{@"type" : @"relay_credentials_result", @"req" : ask[@"req"], @"username" : @"1700000000:abc",
                      @"credential" : @"c2VjcmV0", @"expires" : @1700000000, @"ice_servers" : @[ @"turn:evil" ]}];
    SZFHDrain(h.queue);
    SZFHExpect([credentials.turnURIs isEqualToArray:@[ @"turn:h.example.test:3478?transport=udp" ]] &&
                   [credentials.username isEqual:@"1700000000:abc"] && [credentials.credential isEqual:@"c2VjcmV0"],
               @"credentials: %@ %@", credentials.turnURIs, credentialError);
    SZFHOnQueue(h.queue, ^{
        [signal requestRelayCredentials:^(SZFriendsHostRelayCredentials *c, NSError *e) {
            credentials = c;
            credentialError = e;
        }];
    });
    [socket deliver:@{@"type" : @"relay_refused", @"req" : SZFHLast(socket, @"relay_credentials")[@"req"],
                      @"reason" : @"not_answered"}];
    SZFHDrain(h.queue);
    SZFHExpect(credentials == nil && credentialError.code == SZFriendsHostOnlineErrorNotAnswered, @"refusal");

    [socket deliver:@{@"type" : @"sig_closed", @"sid" : SZFHSid, @"reason" : @"closed"}];
    SZFHDrain(h.queue);
    SZFHExpect([recorder saw:SZFHEnded(SZFriendsHostSignalEndClosed)] &&
                   signal.ended,
               @"events: %@", recorder.events);
    NSUInteger before = socket.sent.count;
    SZFHOnQueue(h.queue, ^{
        sent = [signal sendPayload:SZFHUTF8(@"late")];
        [signal requestRelayCredentials:^(__unused SZFriendsHostRelayCredentials *c, NSError *e) {
            credentialError = e;
        }];
    });
    SZFHExpect(!sent && socket.sent.count == before && credentialError.code == SZFriendsHostOnlineErrorInvalid,
               @"an ended sid still sent (relay_credentials for it would close the connection)");

    // By Friends ID and by link; a refusal; bad arguments never reach the host.
    NSError *error = nil;
    SZFHOpen(h, socket, @{@"type" : @"sig_refused", @"reason" : @"rate_limited"}, ^(id completion) {
        [h.client.online openToFriendsID:@"cedar-lake" payload:SZFHUTF8(@"nn") completion:completion];
    }, &error);
    SZFHExpect([SZFHLast(socket, @"sig_open")[@"to"] isEqual:@{@"friends_id" : @"cedar-lake"}] &&
                   error.code == SZFriendsHostOnlineErrorRateLimited,
               @"open by ID: %@", error);
    NSMutableData *linkID = [NSMutableData dataWithLength:16];
    NSDictionary *linkOpened = @{@"type" : @"sig_opened", @"sid" : SZFHSid2, @"owner_online" : @YES};
    SZFriendsHostSignal *link = SZFHOpen(h, socket, linkOpened,
                                         ^(id completion) {
                                             [h.client.online openToLinkID:linkID
                                                                   payload:SZFHUTF8(@"sealed")
                                                                completion:completion];
                                         },
                                         NULL);
    SZFHExpect(link.ownerOnline && [link.linkID isEqualToData:linkID] && link.via == SZFriendsHostSignalViaLink,
               @"open to a link");
    before = socket.sent.count;
    SZFHOpen(h, socket, @{@"type" : @"sig_opened", @"sid" : SZFHSid}, ^(id completion) {
        [h.client.online openToRendezvousKey:rdvKey payload:[NSMutableData dataWithLength:4097] completion:completion];
    }, &error);
    SZFHExpect(error.code == SZFriendsHostOnlineErrorInvalid && socket.sent.count == before + 1 &&
                   [socket.sent.lastObject[@"type"] isEqual:@"sig_close"],
               @"an oversized payload was sent, or a sid nobody asked for was left open: %@", socket.sent.lastObject);

    // The connection ends: every sid ends with it, then the online side says it is gone.
    [recorder watch:link];
    [socket hangUp];
    SZFHDrain(h.queue);
    NSArray *tail = [recorder.events subarrayWithRange:NSMakeRange(recorder.events.count - 2, 2)];
    SZFHExpect([tail isEqualToArray:(@[ SZFHEnded(SZFriendsHostSignalEndConnectionLost),
                                        @"available 0" ])],
               @"events: %@", recorder.events);
    [h.client stop];
    SZFHDrain(h.queue);
}

static void SZFHTestIncoming(void) {
    SZFHOnlineRecorder *recorder = [[SZFHOnlineRecorder alloc] init];
    SZFHHarness *h = SZFHOnlineHarness(recorder, nil);
    SZFHFakeSocket *socket = SZFHOnlineSocket(h);
    NSString *first = SZFriendsHostBase64URLEncode(SZFHUTF8(@"ik1"));
    [socket deliver:@{@"type" : @"sig_incoming", @"sid" : SZFHSid, @"via" : @"rdv", @"link_id" : [NSNull null],
                      @"payload" : first}];
    // Malformed opens are dropped without a word: a bad sid, an unknown via, a link without its id.
    [socket deliver:@{@"type" : @"sig_incoming", @"sid" : @"short", @"via" : @"rdv", @"payload" : first}];
    [socket deliver:@{@"type" : @"sig_incoming", @"sid" : SZFHSid2, @"via" : @"other", @"payload" : first}];
    [socket deliver:@{@"type" : @"sig_incoming", @"sid" : SZFHSid2, @"via" : @"link", @"payload" : first}];
    SZFHDrain(h.queue);
    NSString *expected = [NSString stringWithFormat:@"incoming %ld ik1", (long)SZFriendsHostSignalViaRendezvous];
    SZFHExpect([recorder.events isEqualToArray:(@[ @"available 1", expected ])], @"events: %@", recorder.events);
    SZFriendsHostSignal *signal = recorder.incoming.firstObject;
    SZFHExpect(signal.incoming && [signal.sid isEqual:SZFHSid], @"the incoming signal");
    __block NSUInteger accepted = 0;
    SZFHOnQueue(h.queue, ^{
        for (int i = 0; i < 70; i++) accepted += [signal sendPayload:SZFHUTF8(@"m")] ? 1 : 0;
    });
    SZFHExpect(accepted == SZFriendsHostSignalMessagesMax && accepted == 64,
               @"%lu payloads sent: the 65th would end the sid for both", (unsigned long)accepted);
    [socket deliver:@{@"type" : @"sig_closed", @"sid" : SZFHSid, @"reason" : @"answered_elsewhere"}];
    SZFHDrain(h.queue);
    SZFHExpect([recorder saw:SZFHEnded(SZFriendsHostSignalEndAnsweredElsewhere)],
               @"events: %@", recorder.events);
    // A target that chooses not to answer just closes; the host is told, the caller is not.
    [socket deliver:@{@"type" : @"sig_incoming", @"sid" : SZFHSid2, @"via" : @"id", @"payload" : first}];
    SZFHDrain(h.queue);
    SZFriendsHostSignal *unanswered = recorder.incoming.lastObject;
    SZFHOnQueue(h.queue, ^{
        [unanswered close];
        [unanswered close];
    });
    SZFHExpect(unanswered.via == SZFriendsHostSignalViaFriendsID &&
                   [SZFHLast(socket, @"sig_close") isEqual:(@{@"type" : @"sig_close", @"v" : @1, @"sid" : SZFHSid2})],
               @"sig_close");
    [h.client stop];
    SZFHDrain(h.queue);
}

void SZFHRunOnlineSignalTests(void) {
    SZFHTestOutgoing();
    SZFHTestIncoming();
}
