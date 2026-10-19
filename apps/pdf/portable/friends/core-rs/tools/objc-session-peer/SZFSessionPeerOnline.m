// The Objective-C interop peer online (crates/szfriends-interop/tests/online_interop.rs): the helper's own check-in
// client to the local Node host (a loopback list and its keys, as a test home's helper takes them), its online driver
// in loopback test mode, and every stream the driver opens made a session exactly as the nearby service makes one
// (service/helper/nearby/SZFriendsNearbyService+Online.m): IK initiator on the offerer's side, responder on the other.
//
//   {"cmd":"online","list":path,"keys":path,"friends":[{identity_key,static_key,presence_secret}],
//    "presence_secret":hex,"block_direct":bool}
//   {"cmd":"reach","identity_key":hex}
//   {"cmd":"block_direct","on":bool}
//   {"cmd":"open_link","link_id":hex,"secret":hex}: the helper's own opener of a download link (SZFriendsLinkOpening,
//   the browser stand-in of its link tests) through this peer's host connection, into memory.
// Events: {"event":"online","available":bool}, {"event":"online_stream","session":n,"route":"internet"|"relay",
// "initiator":bool}, then the session's own events.

#import "SZFSessionPeer.h"

#import <CommonCrypto/CommonDigest.h>

#import "service/host/SZFriendsHostConnection.h"
#import "service/host/SZFriendsHostRendezvous.h"
#import "service/links/SZFriendsLinksInternal.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"
#import "service/online/transport/SZFriendsOnlineTransportInternal.h"
#import "service/session/SZFriendsSecureChannelInternal.h"

@interface SZFPeer (NetworkPrivate)
- (SZFriendsSecureChannel *)responderOnStream:(id<SZFriendsByteStream>)stream;
- (void)configure:(SZFriendsSecureChannel *)channel;
@end

@interface SZFOnline : NSObject <SZFriendsOnlineDriverDelegate, SZFriendsCheckInDelegate>
@property(nonatomic, weak) SZFPeer *peer;
@property(nonatomic) NSMutableDictionary<NSData *, SZFriendsOnlineFriend *> *friends;
@property(nonatomic, copy) NSData *presenceSecret;
@property(nonatomic) SZFriendsHostListCache *cache;
@property(nonatomic) SZFriendsCheckInClient *client;
@property(nonatomic) SZFriendsOnlineDriver *driver;
@end

// A download link's file, kept in memory, its SHA-256 computed as it arrives.
@interface SZFLinkSink : NSObject <SZFriendsLinkSink>
@property(nonatomic) NSMutableData *bytes;
@property(nonatomic, copy, nullable) NSString *name;
@end

@implementation SZFLinkSink

- (BOOL)linkDidReceiveMetadata:(SZFriendsLinkMetadata *)metadata {
    self.name = metadata.name;
    self.bytes = [NSMutableData data];
    return YES;
}

- (BOOL)linkDidReceiveBytes:(NSData *)bytes atOffset:(uint64_t)offset {
    if (offset != self.bytes.length) return NO;
    [self.bytes appendData:bytes];
    return YES;
}

- (BOOL)linkDidFinish {
    return YES;
}

- (void)linkDidStop:(SZFriendsLinkOutcome)outcome {
    (void)outcome;
}

@end

static SZFOnline *SZFOnlineState;
static NSMutableArray *SZFLinkOpenings;
static BOOL SZFBlockDirect;

static NSString *SZFRandomID(void) {
    NSMutableString *text = [NSMutableString string];
    for (int word = 0; word < 2; word++) {
        if (word) [text appendString:@"-"];
        for (int i = 0; i < 6; i++) [text appendFormat:@"%c", 'a' + arc4random_uniform(26)];
    }
    return text;
}

@implementation SZFOnline

- (void)checkInStateDidChange:(SZFriendsHostState)state {
    (void)state;
}

- (void)checkInDidReserveID:(NSString *)friendsID {
    (void)friendsID;
}

- (void)checkInDidRenameIDFrom:(NSString *)friendsID to:(NSString *)newID {
    (void)friendsID, (void)newID;
}

- (void)checkInRequiresUpdate {
}

- (void)onlineDriverDidBecomeAvailable:(SZFriendsOnlineDriver *)driver {
    (void)driver;
    [self.peer emit:@{@"event" : @"online", @"available" : @YES}];
}

- (SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver friendWithIdentityKey:(NSData *)identityKey {
    (void)driver;
    return self.friends[identityKey];
}

- (SZFriendsRouteMethod)onlineDriver:(SZFriendsOnlineDriver *)driver nearbyRouteForFriend:(NSData *)identityKey {
    (void)driver, (void)identityKey;
    return SZFriendsRouteMethodNone;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
       didOpenStream:(id<SZFriendsByteStream>)stream
               route:(SZFriendsRouteMethod)route
           initiator:(BOOL)initiator
              friend:(NSData *)identityKey {
    (void)driver;
    SZFPeer *peer = self.peer;
    SZFriendsOnlineFriend *friend = self.friends[identityKey];
    if (peer == nil || friend == nil) {
        [stream close];
        return;
    }
    SZFPeerSession *session = [[SZFPeerSession alloc] init];
    session.sessionID = [peer nextSessionID];
    session.stream = stream;
    SZFriendsSecureChannel *channel = nil;
    if (initiator) {
        // As nearby dials a friend: IK to the static key we hold, on the route the stream came by.
        SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
        options.pattern = SZFriendsHandshakeIK;
        options.route = route;
        options.remoteStaticKey = friend.staticKey;
        options.expectedIdentityKey = friend.identityKey;
        channel = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:stream
                                                                   identity:peer.identity
                                                                    options:options
                                                                      queue:peer.queue];
    } else {
        channel = [peer responderOnStream:stream];
    }
    [peer configure:channel];
    [peer attachChannel:channel toSession:session];
    [peer emit:@{@"event" : @"online_stream", @"session" : @(session.sessionID),
                 @"route" : route == SZFriendsRouteMethodRelay ? @"relay" : @"internet", @"initiator" : @(initiator)}];
    [channel start];
}

@end

@implementation SZFPeer (Online)

- (NSDictionary *)onlineWithCommand:(NSDictionary *)command {
    if (SZFOnlineState != nil) return @{@"error" : @"already online"};
    NSData *list = [NSData dataWithContentsOfFile:command[@"list"] ?: @""];
    NSData *keysData = [NSData dataWithContentsOfFile:command[@"keys"] ?: @""];
    NSArray<NSData *> *keys = keysData ? SZFriendsHostPinnedKeysFromData(keysData, NULL, NULL) : nil;
    if (list == nil || keys.count == 0) return @{@"error" : @"no list or keys"};
    SZFOnline *online = [[SZFOnline alloc] init];
    online.peer = self;
    online.friends = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in command[@"friends"] ?: @[]) {
        SZFriendsOnlineFriend *friend = [[SZFriendsOnlineFriend alloc] init];
        friend.identityKey = SZFBytes(entry[@"identity_key"]);
        friend.staticKey = SZFBytes(entry[@"static_key"]);
        friend.presenceSecret = SZFBytes(entry[@"presence_secret"]);
        if (friend.identityKey.length != 32 || friend.staticKey.length != 32) return @{@"error" : @"bad friend"};
        online.friends[friend.identityKey] = friend;
        [self.friendKeys addObject:friend.identityKey];
    }
    online.presenceSecret = SZFBytes(command[@"presence_secret"]);
    SZFBlockDirect = [command[@"block_direct"] boolValue];
    SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
    SZFriendsOnlineDriverTestHooks.directPathsBlocked = ^BOOL {
        return SZFBlockDirect;
    };
    NSString *home = command[@"home"] ?: NSTemporaryDirectory();
    online.cache = [[SZFriendsHostListCache alloc] initWithCachePath:[home stringByAppendingPathComponent:@"hosts.json"]
                                                       bootstrapData:list
                                                          pinnedKeys:keys];
    online.client = [[SZFriendsCheckInClient alloc] initWithListCache:online.cache
                                                             identity:self.identity
                                                           appVersion:@"26.10.17-1"
                                                        socketFactory:SZFriendsHostWebSocketFactory(self.queue)
                                                                queue:self.queue];
    online.client.delegate = online;
    online.client.watchesNetworkPath = NO;
    online.client.attestationPath = nil;
    online.driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:self.identity queue:self.queue];
    online.driver.delegate = online;
    __weak SZFOnline *weakOnline = online;
    online.driver.ownPresenceSecret = ^NSData * { return weakOnline.presenceSecret; };
    online.driver.hostList = ^SZFriendsHostList * { return weakOnline.cache.currentList; };
    [online.driver attachHostOnline:online.client.online];
    [online.client startWithFriendsIDProvider:^NSString *(NSUInteger collisions) {
        (void)collisions;
        return SZFRandomID();
    }];
    SZFOnlineState = online;
    return @{};
}

- (NSDictionary *)reachWithCommand:(NSDictionary *)command {
    NSData *key = SZFBytes(command[@"identity_key"]);
    if (SZFOnlineState == nil || key.length != 32) return @{@"error" : @"not online"};
    [SZFOnlineState.driver reachFriend:key];
    return @{@"attempting" : @([SZFOnlineState.driver hasAttemptForFriend:key])};
}

- (NSDictionary *)blockDirectWithCommand:(NSDictionary *)command {
    SZFBlockDirect = [command[@"on"] boolValue];
    if (!SZFBlockDirect) [SZFriendsOnlineDriverTestHooks simulateNetworkChange];
    return @{};
}

- (NSDictionary *)openLinkWithCommand:(NSDictionary *)command {
    NSData *linkID = SZFBytes(command[@"link_id"]), *secret = SZFBytes(command[@"secret"]);
    SZFriendsHostOnline *host = SZFOnlineState.client.online;
    if (host == nil || linkID.length != 16 || secret.length != 32) return @{@"error" : @"not online, or a bad link"};
    SZFriendsOnlineTestLinksUseLocalAddresses = YES;
    SZFriendsLinkEnvironment *environment = [[SZFriendsLinkEnvironment alloc] init];
    environment.transport = [[SZFriendsOnlineDataChannelTransport alloc] initForTestingWithBindAddress:@"127.0.0.1"];
    environment.queue = self.queue;
    environment.directPathsBlocked = ^BOOL {
        return SZFBlockDirect;
    };
    for (SZFriendsHostEntry *entry in SZFOnlineState.cache.currentList.entries) {
        for (NSString *uri in entry.turnURIs) {
            if ([uri hasPrefix:@"stun:"] && environment.stunURI == nil) environment.stunURI = uri;
        }
    }
    SZFLinkSink *sink = [[SZFLinkSink alloc] init];
    SZFriendsLinkOpening *opening = [[SZFriendsLinkOpening alloc] initWithLinkID:linkID secret:secret
                                                                     environment:environment sink:sink];
    if (opening == nil) return @{@"error" : @"no opening"};
    if (SZFLinkOpenings == nil) SZFLinkOpenings = [NSMutableArray array];
    [SZFLinkOpenings addObject:opening];
    __weak SZFriendsLinkOpening *weakOpening = opening;
    [opening startWithOpen:^(NSData *hello, void (^done)(id, BOOL)) {
        [host openToLinkID:linkID payload:hello completion:^(SZFriendsHostSignal *signal, NSError *error) {
            // As the helper's link service: the host's link_ended reads as revoked or expired.
            if ([error.domain isEqual:SZFriendsHostOnlineErrorDomain] &&
                error.code == SZFriendsHostOnlineErrorLinkEnded) {
                [weakOpening noteLinkEnded];
            }
            done(signal ? SZFriendsOnlineChannelForSignal(signal) : nil, signal.ownerOnline);
        }];
    }
        completion:^(SZFriendsLinkOutcome outcome) {
            uint8_t digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(sink.bytes.bytes, (CC_LONG)sink.bytes.length, digest);
            [self emit:@{@"event" : @"link_downloaded", @"outcome" : @(outcome), @"size" : @(sink.bytes.length),
                         @"sha256" : SZFHex([NSData dataWithBytes:digest length:sizeof digest]),
                         @"name" : sink.name ?: [NSNull null], @"attempt" : @(weakOpening.attempt)}];
        }];
    return @{};
}

- (void)stopOnline {
    [SZFOnlineState.driver stop];
    [SZFOnlineState.client stop];
    SZFOnlineState = nil;
}

@end
