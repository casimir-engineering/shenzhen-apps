// The scripted check-in harness (SZFriendsHostHarness.h).

#import "SZFriendsHostHarness.h"

@implementation SZFHHarness
@end

NSString *const SZFHNonce = @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

// Two rendezvous hosts: main-hk with two URLs, then alt-sg.
SZFHHarness *SZFHMakeHarness(void) {
    SZFHHarness *h = [[SZFHHarness alloc] init];
    h.queue = dispatch_queue_create("szfh.client", DISPATCH_QUEUE_SERIAL);
    h.signer = [SZFHSigner randomSigner];
    h.mainHost = [SZFHSigner randomSigner];
    h.altHost = [SZFHSigner randomSigner];
    NSData *bootstrap = [h.signer envelopeForPayload:SZFHPayload(1, @[
        @{@"id" : @"main-hk", @"urls" : @[ @"wss://a.example.test/v1", @"wss://b.example.test/v1" ], @"priority" : @1,
          @"key" : h.mainHost.publicKey},
        @{@"id" : @"alt-sg", @"url" : @"wss://c.example.test/v1", @"priority" : @2, @"key" : h.altHost.publicKey},
        @{@"id" : @"relay-only", @"url" : @"wss://r.example.test/v1", @"priority" : @3, @"role" : @"relay"},
    ])];
    NSString *dir = SZFHTempDir();
    h.cache = [[SZFriendsHostListCache alloc] initWithCachePath:[dir stringByAppendingPathComponent:@"hosts.json"]
                                                  bootstrapData:bootstrap
                                                     pinnedKeys:@[ h.signer.publicKey ]];
    h.identity = [SZFHTestIdentity randomIdentity];
    h.sockets = [NSMutableArray array];
    h.providedIDs = [NSMutableArray array];
    __weak SZFHHarness *weak = h;
    h.client = [[SZFriendsCheckInClient alloc] initWithListCache:h.cache
                                                        identity:h.identity.asIdentity
                                                      appVersion:@"26.10.12-1"
                                                   socketFactory:^id<SZFriendsHostSocket>(NSURL *url) {
                                                       SZFHFakeSocket *fake = [[SZFHFakeSocket alloc] initWithURL:url];
                                                       @synchronized(weak.sockets) {
                                                           [weak.sockets addObject:fake];
                                                       }
                                                       return fake;
                                                   }
                                                           queue:h.queue];
    h.client.watchesNetworkPath = NO;
    h.client.connectTimeout = 0.3;
    h.client.releaseTimeout = 0.4;
    h.recorder = [[SZFHRecorder alloc] init];
    h.client.delegate = h.recorder;
    return h;
}

SZFHFakeSocket *SZFHSocket(SZFHHarness *h, NSUInteger index) {
    SZFHWaitUntil(3, ^BOOL {
        @synchronized(h.sockets) {
            return h.sockets.count > index;
        }
    });
    @synchronized(h.sockets) {
        return h.sockets.count > index ? h.sockets[index] : nil;
    }
}

void SZFHStart(SZFHHarness *h) {
    __weak SZFHHarness *weak = h;
    [h.client startWithFriendsIDProvider:^NSString *(NSUInteger collisions) {
        NSString *friendsID = collisions == 0 ? @"maple-river" : SZFHDrawID(collisions);
        [weak.providedIDs addObject:friendsID];
        return friendsID;
    }];
    SZFHDrain(h.queue);
}

// Delivers the challenge and returns the check-in the client sent in answer.
NSDictionary *SZFHChallenge(SZFHHarness *h, SZFHFakeSocket *socket, NSString *hostID) {
    [socket deliver:@{@"type" : @"challenge", @"host_id" : hostID, @"nonce" : SZFHNonce, @"time" : @"x",
                      @"protocol" : @3}];
    SZFHDrain(h.queue);
    return socket.sent.lastObject;
}

// The ID the client's latest message on `socket` asked for: what the host's answer is signed for.
NSString *SZFHLastRequested(SZFHFakeSocket *socket) {
    for (NSDictionary *sent in socket.sent.reverseObjectEnumerator) {
        if ([sent[@"friends_id"] isKindOfClass:[NSString class]]) return sent[@"friends_id"];
    }
    return nil;
}

// Delivers `reply` signed by the host that socket reached, for the client's latest request.
void SZFHReply(SZFHHarness *h, SZFHFakeSocket *socket, NSDictionary *reply) {
    SZFHSigner *host = [socket.url.host isEqualToString:@"c.example.test"] ? h.altHost : h.mainHost;
    [socket deliver:SZFHSigned(reply, host, SZFHNonce, SZFHLastRequested(socket))];
    SZFHDrain(h.queue);
}

void SZFHWelcome(SZFHHarness *h, SZFHFakeSocket *socket, NSDictionary *fields) {
    NSMutableDictionary *welcome = [@{@"type" : @"welcome", @"update_required" : @NO} mutableCopy];
    [welcome addEntriesFromDictionary:fields];
    SZFHReply(h, socket, welcome);
}
