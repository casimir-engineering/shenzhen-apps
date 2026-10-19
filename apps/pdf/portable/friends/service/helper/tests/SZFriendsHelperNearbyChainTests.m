// friends-helper-check: device chains on sessions (ADR 0012). A friend's CHAIN is kept only from the root we pinned,
// their other authorized devices then pass the key policy, revoked devices (a first device included) are refused, a
// chain that revokes its own sender ends that session, a forged one ends it too, and our own chain goes to friends
// only, on sessions that speak minor 2, with an existing profile's genesis written on first need.

#import "SZFriendsHelperNearbyTests.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"

// A fake channel that names the device at the other end, as a verified handshake would.
@interface SZFNDeviceChannel : SZFNFakeChannel
@property(nonatomic, copy) NSData *deviceKey;
@property(nonatomic, copy) NSData *deviceStaticKey;
@property(nonatomic) NSUInteger minor;
@end

@implementation SZFNDeviceChannel
- (NSData *)remoteIdentityKey {
    return self.deviceKey;
}
- (NSData *)remoteStaticKey {
    return self.deviceStaticKey;
}
- (NSUInteger)negotiatedMinor {
    return self.minor;
}
- (NSData *)presentedRequestToken {
    return nil;
}
- (NSData *)remoteCertificate {
    return nil;
}
- (SZFriendsRouteMethod)initiatorRoute {
    return SZFriendsRouteMethodLAN;
}
@end

@interface SZFriendsNearbyService (SZFNChainPrivate)
- (void)linkWentLive:(SZFriendsPeerLink *)link;
- (BOOL)keyChangedOnLink:(SZFriendsPeerLink *)link conversationID:(NSString *)conversationID;
@end

static SZFriendsIdentity *SZFNDevice(uint8_t seed) {
    NSMutableData *signing = [NSMutableData dataWithLength:32], *key = [NSMutableData dataWithLength:32];
    memset(signing.mutableBytes, seed, 32);
    memset(key.mutableBytes, seed ^ 0x5a, 32);
    return [SZFriendsIdentity identityWithSigningSeed:signing staticPrivateKey:key];
}

static SZFriendsPeerLink *SZFNDeviceLink(SZFriendsIdentity *device, NSString *conversationID, NSUInteger minor) {
    SZFNDeviceChannel *channel = [[SZFNDeviceChannel alloc] init];
    channel.pattern = SZFriendsHandshakeIK;
    channel.deviceKey = device.publicKey;
    channel.deviceStaticKey = device.staticPublicKey;
    channel.minor = minor;
    SZFriendsPeerLink *link = SZFNLink(channel);
    link.conversationID = conversationID;
    return link;
}

static SZFriendsFrame *SZFNChainFrame(NSData *encoded) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeChain fields:@{@(SZFriendsFieldChain) : encoded}];
}

static SZFriendsDeviceChain *SZFNAdd(SZFriendsDeviceChain *chain, SZFriendsIdentity *device, SZFriendsIdentity *by) {
    return [chain chainByAddingDeviceKey:device.publicKey staticKey:device.staticPublicKey
                                 consent:SZFriendsDeviceConsent(device, chain.rootKey) name:@"MacBook Air"
                                  system:@"macOS 26.1" signedBy:by date:[NSDate date] error:NULL];
}

static SZFriendsPersonRecord *SZFNFriendWithRoot(SZFriendsStore *store, SZFriendsIdentity *root) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = SZFriendsNewIdentifier();
    person.identityKey = root.publicKey;
    person.staticKey = root.staticPublicKey;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:person error:NULL], "a friend is saved");
    return person;
}

static BOOL SZFNAllowsIK(SZFriendsNearbyService *nearby, NSData *key) {
    return [nearby allowRemoteKey:key pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO];
}

void SZFNTestFriendsChains(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"chains");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsIdentity *root = SZFNDevice(1), *laptop = SZFNDevice(2), *stranger = SZFNDevice(3);
    SZFriendsPersonRecord *mei = SZFNFriendWithRoot(store, root);
    SZFriendsDeviceChain *genesis = [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"iMac" system:@"macOS"
                                                                              date:[NSDate date] error:NULL];
    SZFriendsDeviceChain *two = SZFNAdd(genesis, laptop, root);
    EXPECT(SZFNAllowsIK(nearby, root.publicKey) && !SZFNAllowsIK(nearby, laptop.publicKey),
           "before her chain arrives only Mei's first device is known");

    SZFriendsPeerLink *fromRoot = SZFNDeviceLink(root, mei.conversationID, 2);
    [nearby link:fromRoot receivedFrame:SZFNChainFrame(two.encodedData)];
    EXPECT(!((SZFNFakeChannel *)fromRoot.channel).closed, "an honest chain keeps the session");
    EXPECT(SZFNAllowsIK(nearby, laptop.publicKey), "her laptop, which her chain authorizes, may open IK");
    SZFriendsPeerLink *fromLaptop = SZFNDeviceLink(laptop, mei.conversationID, 2);
    BOOL handled = NO;
    EXPECT([nearby otherDeviceOfPerson:mei matchesStaticKeyOnLink:fromLaptop handled:&handled] && handled,
           "the laptop's static key is the one her chain gives it");
    EXPECT(![nearby keyChangedOnLink:fromLaptop conversationID:mei.conversationID] &&
               ![store personWithConversationID:mei.conversationID].keyChangePending &&
               [[store personWithConversationID:mei.conversationID].staticKey isEqualToData:root.staticPublicKey],
           "another device's static key is not a key change and never replaces hers");
    ((SZFNDeviceChannel *)fromLaptop.channel).deviceStaticKey = stranger.staticPublicKey;
    EXPECT([nearby keyChangedOnLink:fromLaptop conversationID:mei.conversationID] &&
               ((SZFNFakeChannel *)fromLaptop.channel).closed &&
               ![store personWithConversationID:mei.conversationID].keyChangePending,
           "a device presenting a static key its chain does not give it is refused, not reviewed");

    // Forged: one flipped byte ends the session and keeps what was stored.
    NSMutableData *forged = [two.encodedData mutableCopy];
    ((uint8_t *)forged.mutableBytes)[forged.length - 2] ^= 1;
    SZFriendsPeerLink *forger = SZFNDeviceLink(root, mei.conversationID, 2);
    [nearby link:forger receivedFrame:SZFNChainFrame(forged)];
    EXPECT(((SZFNFakeChannel *)forger.channel).closed && SZFNAllowsIK(nearby, laptop.publicKey),
           "a forged chain ends the session and changes nothing");

    // Mei revokes the laptop from her first device; the laptop's own session ends when it hands over that chain.
    SZFriendsDeviceChain *revoked = [two chainByRevokingDeviceKey:laptop.publicKey signedBy:root date:[NSDate date]
                                                            error:NULL];
    SZFriendsPeerLink *laptopLink = SZFNDeviceLink(laptop, mei.conversationID, 2);
    [nearby link:laptopLink receivedFrame:SZFNChainFrame(revoked.encodedData)];
    EXPECT(((SZFNFakeChannel *)laptopLink.channel).closed, "a chain revoking its own sender ends that session");
    EXPECT(!SZFNAllowsIK(nearby, laptop.publicKey), "a revoked device is refused before any reply");

    // A revoked first device: still Mei's identity key, so only the chain stops it.
    SZFriendsIdentity *desk = SZFNDevice(4);
    SZFriendsDeviceChain *withDesk = SZFNAdd(revoked, desk, root);
    SZFriendsDeviceChain *rootGone = [withDesk chainByRevokingDeviceKey:root.publicKey signedBy:desk
                                                                   date:[NSDate date] error:NULL];
    [nearby link:SZFNDeviceLink(desk, mei.conversationID, 2) receivedFrame:SZFNChainFrame(rootGone.encodedData)];
    EXPECT([store personWithIdentityKey:root.publicKey] != nil && !SZFNAllowsIK(nearby, root.publicKey) &&
               SZFNAllowsIK(nearby, desk.publicKey), "her removed first device is refused, her desk accepted");
    SZFriendsPeerLink *late = SZFNDeviceLink(root, mei.conversationID, 2);
    ((SZFNFakeChannel *)late.channel).isInitiator = YES;
    [nearby linkWentLive:late];
    EXPECT(((SZFNFakeChannel *)late.channel).closed, "a session we dialed to a removed device closes once live");
    [services close];
}

void SZFNTestOwnChainToFriends(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"own-chain");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsIdentity *root = SZFNDevice(7);
    SZFriendsPersonRecord *friend = SZFNFriendWithRoot(store, root);
    SZFriendsPersonRecord *asking = SZFNSavePerson(store, SZFriendsRelationIncomingRequest);
    EXPECT(store.ownDeviceChain == nil, "an existing profile has no chain until a friend needs it");
    SZFriendsPeerLink *older = SZFNDeviceLink(root, friend.conversationID, 1);
    [nearby sendChainOnLink:older];
    SZFriendsPeerLink *requester = SZFNDeviceLink(SZFNDevice(8), asking.conversationID, 2);
    [nearby sendChainOnLink:requester];
    EXPECT(((SZFNFakeChannel *)older.channel).sent.count == 0 && ((SZFNFakeChannel *)requester.channel).sent.count == 0,
           "no CHAIN to a peer before minor 2, nor to someone who is not a friend");
    SZFriendsPeerLink *link = SZFNDeviceLink(root, friend.conversationID, 2);
    [nearby sendChainOnLink:link];
    SZFriendsFrame *sent = ((SZFNFakeChannel *)link.channel).sent.firstObject;
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:[sent dataForTag:SZFriendsFieldChain]
                                                      expectedRootKey:services.identity.publicKey error:NULL];
    EXPECT(sent.type == SZFriendsFrameTypeChain && chain.links.count == 1 &&
               [chain authorizesDeviceKey:services.identity.publicKey] &&
               [store.ownDeviceChain.encodedData isEqualToData:chain.encodedData],
           "a friend gets our chain, whose genesis was written for this existing profile");
    [nearby sendChainOnLink:link];
    EXPECT([[((SZFNFakeChannel *)link.channel).sent.lastObject dataForTag:SZFriendsFieldChain]
               isEqualToData:chain.encodedData], "the same genesis every time");
    // Wired into every session going live with a friend.
    SZFriendsPeerLink *live = SZFNDeviceLink(root, nil, 2);
    [nearby linkWentLive:live];
    NSArray<SZFriendsFrame *> *frames = ((SZFNFakeChannel *)live.channel).sent;
    NSUInteger chains = 0;
    for (SZFriendsFrame *frame in frames) chains += frame.type == SZFriendsFrameTypeChain;
    EXPECT(chains == 1, "a friend's session carries our chain once it is live: %@", frames);
    [live.channel close];
    [services close];
}
