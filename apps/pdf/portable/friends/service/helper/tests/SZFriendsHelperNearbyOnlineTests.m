// friends-helper-check: the helper's side of online Friends (SZFriendsNearbyService+Online.m) and the explicit route
// rank in nearby dialing. Fake channels and a recording adapter; no driver ever reaches a host here.

#import "SZFriendsHelperNearbyTests.h"

#import <objc/runtime.h>
#import <sodium.h>

#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"

// The route the fake channel's initiator declared; None (the default) leaves raceRoute to the dialed route.
@implementation SZFNFakeChannel (Route)
static char SZFNRouteKey;
- (SZFriendsRouteMethod)initiatorRoute {
    return (SZFriendsRouteMethod)[objc_getAssociatedObject(self, &SZFNRouteKey) integerValue];
}
- (void)setInitiatorRoute:(SZFriendsRouteMethod)route {
    objc_setAssociatedObject(self, &SZFNRouteKey, @(route), OBJC_ASSOCIATION_RETAIN);
}
@end

// Records which endpoints the service asked to dial, and never connects.
@interface SZFNDialRecorder : SZFNRecordingAdapter
@property(nonatomic, readonly) NSMutableArray<NSString *> *dialed;
@end

@implementation SZFNDialRecorder

- (instancetype)init {
    if ((self = [super init])) _dialed = [NSMutableArray array];
    return self;
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    [_dialed addObject:endpointID];
    [super openStreamToEndpoint:endpointID completion:completion];
}

@end

// A live, adopted session with `person` on `route`, as the session race leaves it.
static SZFriendsPeerLink *SZFNLiveLink(SZFriendsNearbyService *nearby, SZFriendsPersonRecord *person,
                                       SZFriendsRouteMethod route) {
    SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
    [channel setInitiatorRoute:route];
    SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:channel.asChannel
                                                                 purpose:SZFriendsLinkPurposeFriend
                                                                   route:route];
    link.conversationID = person.conversationID;
    link.live = YES;
    link.adopted = YES;
    nearby.activeLinks[person.conversationID] = link;
    return link;
}

static SZFriendsDialPlan *SZFNFriendPlan(SZFriendsPersonRecord *person, SZFriendsRouteMethod route,
                                         NSString *endpoint) {
    SZFriendsSighting *sighting = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                                      route:route
                                                                 endpointID:endpoint
                                                                presenceTag:nil
                                                               callbackTags:@[]
                                                                   isPublic:NO
                                                                     seenAt:[NSDate date]];
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = SZFriendsHandshakeIK;
    options.route = route;
    SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting purpose:SZFriendsLinkPurposeFriend
                                                          options:options];
    plan.conversationID = person.conversationID;
    return plan;
}

// ADR 0011 § Route rank, as nearby dialing applies it: with an Internet session live, a Bluetooth dial is pointless
// (Internet ranks first, though its number is larger) and a LAN dial still goes ahead. One assertion for every kind of
// session, so a friend's files and the sync between a person's own devices keep the same order.
static void SZFNExpectDialRank(SZFriendsNearbyService *nearby, SZFNDialRecorder *adapter,
                               SZFriendsPeerLink * (^live)(SZFriendsRouteMethod route),
                               SZFriendsPeerLink *_Nullable (^carrier)(void),
                               SZFriendsDialPlan * (^plan)(SZFriendsRouteMethod route, NSString *endpoint)) {
    live(SZFriendsRouteMethodInternet);
    EXPECT(carrier().raceRoute == SZFriendsRouteMethodInternet);
    [nearby dial:plan(SZFriendsRouteMethodBluetooth, @"bluetooth-endpoint")];
    [nearby dial:plan(SZFriendsRouteMethodLAN, @"lan-endpoint")];
    SZFNSpin(0.2);
    EXPECT(![adapter.dialed containsObject:@"bluetooth-endpoint"], "no Bluetooth dial beside Internet: %@",
           adapter.dialed);
    EXPECT([adapter.dialed containsObject:@"lan-endpoint"], "the LAN still beats Internet: %@", adapter.dialed);
}

void SZFNTestDialRank(NSString *scratch) {
    EXPECT(SZFriendsNearbyDialIsPointless(SZFriendsRouteMethodInternet, SZFriendsRouteMethodBluetooth));
    EXPECT(!SZFriendsNearbyDialIsPointless(SZFriendsRouteMethodBluetooth, SZFriendsRouteMethodInternet));
    EXPECT(!SZFriendsNearbyDialIsPointless(SZFriendsRouteMethodRelay, SZFriendsRouteMethodInternet));
    EXPECT(SZFriendsNearbyDialIsPointless(SZFriendsRouteMethodLAN, SZFriendsRouteMethodLAN));
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"dial-rank");
    if (services == nil) return;
    SZFNDialRecorder *adapter = [[SZFNDialRecorder alloc] init];
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[ adapter ]);
    SZFriendsPersonRecord *person = SZFNSavePerson(services.store, SZFriendsRelationFriend);
    SZFNExpectDialRank(
        nearby, adapter, ^SZFriendsPeerLink *(SZFriendsRouteMethod route) { return SZFNLiveLink(nearby, person, route); },
        ^SZFriendsPeerLink *{ return [nearby liveLinkForConversation:person.conversationID]; },
        ^SZFriendsDialPlan *(SZFriendsRouteMethod route, NSString *endpoint) {
            return SZFNFriendPlan(person, route, endpoint);
        });
    [services close];

    // The same order for the sync with another of the person's own devices (the profile they joined).
    services = SZFNOpenServices(scratch, @"dial-rank-own");
    if (services == nil) return;
    adapter = [[SZFNDialRecorder alloc] init];
    nearby = SZFNNearbyWith(services, @[ adapter ]);
    NSString *hex = SZFriendsLinkHex(SZFNBytes(32));
    SZFNExpectDialRank(
        nearby, adapter,
        ^SZFriendsPeerLink *(SZFriendsRouteMethod route) {
            SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
            [channel setInitiatorRoute:route];
            SZFriendsPeerLink *link = [[SZFriendsPeerLink alloc] initWithChannel:channel.asChannel
                                                                         purpose:SZFriendsLinkPurposeOwnDevice
                                                                           route:route];
            link.live = YES;
            link.ownDevice = YES;
            nearby.syncLinks[hex] = link;
            return link;
        },
        ^SZFriendsPeerLink *{ return [nearby liveSyncLinkForDeviceHex:hex]; },
        ^SZFriendsDialPlan *(SZFriendsRouteMethod route, NSString *endpoint) {
            SZFriendsDialPlan *plan = SZFNFriendPlan(person, route, endpoint);
            plan.purpose = SZFriendsLinkPurposeOwnDevice;
            plan.conversationID = [@"dev-" stringByAppendingString:hex];
            plan.ownDeviceHex = hex;
            return plan;
        });
    [services close];
}

// The driver's delegate: who may be reached online, and which route outside the driver carries each friend.
void SZFNTestOnlineDelegate(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"online-delegate");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsStore *store = services.store;
    SZFriendsPersonRecord *friend = SZFNSavePerson(store, SZFriendsRelationFriend);
    friend.presenceSecret = SZFNBytes(32);
    [store savePerson:friend error:NULL];
    SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:services.identity
                                                                              queue:dispatch_get_main_queue()];
    SZFriendsOnlineFriend *online = [nearby onlineDriver:driver friendWithIdentityKey:friend.identityKey];
    EXPECT([online.staticKey isEqualToData:friend.staticKey] &&
               [online.presenceSecret isEqualToData:friend.presenceSecret],
           "a friend is reached with the static key IK dials");
    for (NSNumber *relation in @[ @(SZFriendsRelationBlocked), @(SZFriendsRelationRemoved),
                                  @(SZFriendsRelationIncomingRequest), @(SZFriendsRelationOutgoingRequest) ]) {
        SZFriendsPersonRecord *other = SZFNSavePerson(store, (SZFriendsRelation)relation.integerValue);
        EXPECT([nearby onlineDriver:driver friendWithIdentityKey:other.identityKey] == nil, "relation %@", relation);
    }
    EXPECT([nearby onlineDriver:driver friendWithIdentityKey:SZFNBytes(32)] == nil, "nobody we know");
    friend.keyChangePending = YES;
    [store savePerson:friend error:NULL];
    EXPECT([nearby onlineDriver:driver friendWithIdentityKey:friend.identityKey] == nil, "a key change waits");

    EXPECT([nearby onlineDriver:driver nearbyRouteForFriend:friend.identityKey] == SZFriendsRouteMethodNone);
    SZFriendsPeerLink *link = SZFNLiveLink(nearby, friend, SZFriendsRouteMethodBluetooth);
    EXPECT([nearby onlineDriver:driver nearbyRouteForFriend:friend.identityKey] == SZFriendsRouteMethodBluetooth);
    [(SZFNFakeChannel *)(id)link.channel setInitiatorRoute:SZFriendsRouteMethodRelay];
    EXPECT([nearby onlineDriver:driver nearbyRouteForFriend:friend.identityKey] == SZFriendsRouteMethodNone,
           "the driver's own sessions are its business");
    // Without a host saying online, nothing is reached and nothing is made.
    [nearby reachFriendsOnline];
    EXPECT(nearby.onlineDriver == nil);
    [services close];
}

// A test host list may name STUN and TURN servers, on loopback only.
void SZFNTestLoopbackICE(void) {
    unsigned char pk[crypto_sign_PUBLICKEYBYTES], sk[crypto_sign_SECRETKEYBYTES];
    crypto_sign_keypair(pk, sk);
    NSData *pinned = [NSData dataWithBytes:pk length:32];
    NSArray *cases = @[
        @[ @YES, @[ @"stun:127.0.0.1:3478", @"stun:127.0.0.1:3479", @"turn:127.0.0.1:3478?transport=udp" ] ],
        @[ @YES, @[ @"turn:[::1]:3478?transport=udp", @"stun:localhost" ] ],
        @[ @NO, @[ @"stun:friends.example:3478" ] ],
        @[ @NO, @[ @"turn:10.0.0.1:3478?transport=udp" ] ],
        @[ @NO, @[ @"stun:127.0.0.1:3478", @"turns:[2001:db8::1]:5349" ] ],
    ];
    NSString *(^b64)(NSData *) = ^NSString *(NSData *data) {
        NSString *text = [data base64EncodedStringWithOptions:0];
        text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
        text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
    };
    for (NSArray *testCase in cases) {
        NSDictionary *payload = @{
            @"version" : @1, @"issued_at" : @"2026-10-12T00:00:00Z", @"new_id_words" : @2,
            @"hosts" : @[ @{@"id" : @"main-hk", @"role" : @"both", @"urls" : @[ @"ws://127.0.0.1:9/v1" ],
                            @"turn_uris" : testCase[1], @"region" : @"Test", @"priority" : @1,
                            @"public_key" : b64(SZFNBytes(32))} ]
        };
        NSData *payloadBytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
        NSMutableData *signedBytes = [[@"SZFriends host list v1\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [signedBytes appendData:payloadBytes];
        unsigned char signature[crypto_sign_BYTES];
        crypto_sign_detached(signature, NULL, signedBytes.bytes, signedBytes.length, sk);
        NSDictionary *envelope = @{@"payload" : b64(payloadBytes),
                                   @"sigs" : @[ @{@"key" : @"primary",
                                                  @"sig" : b64([NSData dataWithBytes:signature length:64])} ]};
        NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
        SZFriendsHostList *list = [SZFriendsHostList listFromSignedData:data pinnedKeys:@[ pinned ] error:NULL];
        EXPECT(list != nil && SZFriendsHostListIsLoopbackOnly(list) == [testCase[0] boolValue], "%@", testCase[1]);
    }
}
