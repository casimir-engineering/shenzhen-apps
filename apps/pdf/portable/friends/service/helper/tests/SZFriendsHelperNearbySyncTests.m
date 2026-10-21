// friends-helper-check: sync with this person's other devices (SZFriendsNearbyService+Sync.m). Nothing runs before our
// chain holds another device; then that device may open IK (and nothing else), a live session with it carries our
// chain first and then the sync exchange, both ways, with no stranger's limits; changes captured while it is live
// reach it; erasing a chat erases it there too; the tag matcher and advertisement carry our devices' tags; one session
// per device survives a double dial; and a device we revoke is refused.

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/store/SZFriendsStoreSync.h"
#import "service/sync/SZFriendsSync.h"

// A fake channel naming the device at the other end, as a verified handshake would.
@interface SZFNOwnDeviceChannel : SZFNFakeChannel
@property(nonatomic, copy) NSData *deviceKey;
@property(nonatomic) SZFriendsRouteMethod route; // the initiator's declared route; LAN when not set
@end

@implementation SZFNOwnDeviceChannel
- (NSData *)remoteIdentityKey {
    return self.deviceKey;
}
- (NSUInteger)negotiatedMinor {
    return 2;
}
- (SZFriendsRouteMethod)initiatorRoute {
    return self.route != SZFriendsRouteMethodNone ? self.route : SZFriendsRouteMethodLAN;
}
- (NSData *)presentedRequestToken {
    return nil;
}
@end

@interface SZFriendsNearbyService (SZFNSyncPrivate)
- (void)linkWentLive:(SZFriendsPeerLink *)link;
- (void)link:(SZFriendsPeerLink *)link closedWithError:(nullable NSError *)error;
@end

static SZFriendsIdentity *SZFNSyncDevice(uint8_t seed) {
    NSMutableData *signing = [NSMutableData dataWithLength:32], *key = [NSMutableData dataWithLength:32];
    memset(signing.mutableBytes, seed, 32);
    memset(key.mutableBytes, seed ^ 0x5a, 32);
    return [SZFriendsIdentity identityWithSigningSeed:signing staticPrivateKey:key];
}

static SZFriendsPeerLink *SZFNOwnLinkOn(SZFriendsIdentity *device, BOOL weDialed, SZFriendsRouteMethod route) {
    SZFNOwnDeviceChannel *channel = [[SZFNOwnDeviceChannel alloc] init];
    channel.pattern = SZFriendsHandshakeIK;
    channel.isInitiator = weDialed;
    channel.deviceKey = device.publicKey;
    channel.route = route;
    return SZFNLink(channel);
}

static SZFriendsPeerLink *SZFNOwnLink(SZFriendsIdentity *device, BOOL weDialed) {
    return SZFNOwnLinkOn(device, weDialed, SZFriendsRouteMethodLAN);
}

// The laptop's side: its own store and engine, and an exchange whose messages go to the helper's link.
@interface SZFNLaptop : NSObject
@property(nonatomic, strong) SZFriendsStore *store;
@property(nonatomic, strong) SZFriendsSyncEngine *engine;
@property(nonatomic, strong) SZFriendsSyncExchange *exchange;
@property(nonatomic) NSUInteger read; // frames of the helper's fake channel already handed to the exchange
@end

@implementation SZFNLaptop
@end

// Hands frames both ways until neither side has anything new.
static void SZFNSyncRun(SZFriendsPeerLink *link, SZFNLaptop *laptop) {
    NSMutableArray<SZFriendsFrame *> *sent = ((SZFNFakeChannel *)link.channel).sent;
    for (int turn = 0; turn < 200 && laptop.read < sent.count; turn++) {
        SZFriendsFrame *frame = sent[laptop.read++];
        if (frame.type == SZFriendsFrameTypeSync) {
            [laptop.exchange receiveMessage:[frame dataForTag:SZFriendsFieldSync] error:NULL];
        }
    }
}

void SZFNTestOwnDeviceSync(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"own-sync");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFNRecordingAdapter *adapter = [[SZFNRecordingAdapter alloc] init];
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[ adapter ]);
    SZFriendsIdentity *laptopID = SZFNSyncDevice(0x61), *outsider = SZFNSyncDevice(0x62);
    SZFriendsDeviceChain *genesis = [store ownDeviceChainCreatingGenesisWithIdentity:services.identity error:NULL];
    EXPECT([nearby activeSyncEngine] == nil, "nothing runs while our chain holds one device");
    EXPECT(![nearby allowRemoteKey:laptopID.publicKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO],
           "an unknown device is nobody");
    SZFriendsDeviceChain *two = [genesis chainByAddingDeviceKey:laptopID.publicKey staticKey:laptopID.staticPublicKey
                                                       consent:SZFriendsDeviceConsent(laptopID, genesis.rootKey)
                                                          name:@"MacBook Air" system:@"macOS 26.1"
                                                      signedBy:services.identity date:[NSDate date] error:NULL];
    [store mergeOwnDeviceChain:two error:NULL];
    EXPECT([nearby activeSyncEngine] != nil, "sync starts once another device is ours");
    // A device added to our chain is matched nearby soon after, with no session yet (the first device's secret).
    [nearby changed];
    SZFNSpin(0.6);
    NSData *earlySecret = [nearby activeSyncEngine].ownDevicesSecret;
    NSData *earlyTag = SZFriendsPresenceTag(SZFriendsSyncDeviceTagSecret(earlySecret, laptopID.publicKey),
                                            SZFriendsPresenceWindowIndex([NSDate date]));
    EXPECT(earlySecret != nil && nearby.coordinator.merger.tagMatcher(earlyTag) != nil,
           "the laptop's tag is matched once the chain holds it");
    EXPECT([nearby allowRemoteKey:laptopID.publicKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO] &&
               ![nearby allowRemoteKey:laptopID.publicKey pattern:SZFriendsHandshakeXX token:nil link:nil
                           publicEntry:YES],
           "our laptop may open IK, and only IK");

    SZFNLaptop *laptop = [[SZFNLaptop alloc] init];
    laptop.store = [SZFriendsStore storeInDirectory:[scratch stringByAppendingPathComponent:@"laptop"] error:NULL];
    [laptop.store adoptOwnDeviceChain:two localDeviceKey:laptopID.publicKey error:NULL];
    laptop.engine = [[SZFriendsSyncEngine alloc] initWithStore:laptop.store identity:laptopID
                                             receivedDirectory:[scratch stringByAppendingPathComponent:@"laptop-in"]];

    SZFriendsPeerLink *link = SZFNOwnLink(laptopID, NO);
    [nearby linkWentLive:link];
    NSArray<SZFriendsFrame *> *sent = ((SZFNFakeChannel *)link.channel).sent;
    EXPECT(link.ownDevice && sent.count >= 2 && sent[0].type == SZFriendsFrameTypeChain &&
               sent[1].type == SZFriendsFrameTypeSync,
           "a live session with our laptop sends the chain, then sync: %@", sent);
    EXPECT([nearby linkIsWithFriend:link], "and has no stranger's limits");
    __weak SZFriendsPeerLink *weakLink = link;
    laptop.exchange = [[SZFriendsSyncExchange alloc]
        initWithEngine:laptop.engine
               peerKey:services.identity.publicKey
                  send:^(NSData *message) {
                      SZFriendsFrame *frame = [SZFriendsFrame frameWithType:SZFriendsFrameTypeSync
                                                                     fields:@{@(SZFriendsFieldSync) : message}];
                      [nearby link:weakLink receivedFrame:frame];
                  }];
    SZFriendsSyncExchange *laptopExchange = laptop.exchange;
    laptop.engine.onNewEvents = ^{ [laptopExchange pump]; };
    [laptop.engine captureLocalChanges];
    [laptop.exchange start];
    SZFNSyncRun(link, laptop);
    EXPECT(laptop.exchange.peerCaughtUp && [store syncEventCount] == [laptop.store syncEventCount],
           "both hold every event after the first exchange");
    // A change on the laptop reaches this device.
    laptop.store.profileName = @"Raph";
    [laptop.engine captureLocalChanges];
    SZFNSyncRun(link, laptop);
    EXPECT([store.profileName isEqualToString:@"Raph"], "the laptop's profile arrived here");

    // A change here while the session is live reaches the laptop.
    SZFriendsPersonRecord *mei = SZFNSavePerson(store, SZFriendsRelationFriend);
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = @"m1";
    item.conversationID = mei.conversationID;
    item.text = @"from the desktop";
    item.sentAt = item.receivedAt = [NSDate date];
    [store insertItem:item error:NULL];
    [nearby changed];
    SZFNSpin(0.6);
    SZFNSyncRun(link, laptop);
    SZFriendsPersonRecord *there = [laptop.store syncPersonWithIdentityKey:mei.identityKey];
    EXPECT(there != nil && [laptop.store itemWithID:@"m1" inConversation:there.conversationID] != nil,
           "a message here reaches the laptop");

    // A file the laptop holds shows here by its record, before (or without) its bytes.
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = @"t1";
    file.conversationID = mei.conversationID;
    file.itemID = @"f1";
    file.state = SZFriendsTransferStateReceived;
    file.fileName = @"Contract.pdf";
    file.size = 1234;
    file.contentDigest = SZFNBytes(32);
    file.createdAt = [NSDate date];
    file.holders = @[ laptopID.publicKey ];
    [store saveSyncFile:file error:NULL];
    SZFriendsItemRecord *fileItem = [[SZFriendsItemRecord alloc] init];
    fileItem.itemID = @"f1";
    fileItem.conversationID = mei.conversationID;
    fileItem.kind = SZFriendsItemKindTransfer;
    fileItem.transferID = @"t1";
    fileItem.sentAt = fileItem.receivedAt = [NSDate date];
    SZFriendsItemFacts *facts = SZFriendsItemFactsFromRecord(fileItem, services);
    EXPECT([facts.fileName isEqualToString:@"Contract.pdf"] && facts.fileSize == 1234 && facts.localPath == nil,
           "a file on the laptop shows here by name and size: %@", facts.fileName);

    // Erasing the chat here erases it there.
    EXPECT([nearby eraseHistoryInConversation:mei.conversationID], "erased");
    SZFNSyncRun(link, laptop);
    EXPECT([laptop.store itemWithID:@"m1" inConversation:there.conversationID] == nil, "and on the laptop");

    // Nearby, our devices recognise each other's tags, which only they can compute.
    NSString *name = [@"dev-" stringByAppendingString:SZFriendsLinkHex(laptopID.publicKey)];
    EXPECT([nearby ownDeviceTagSecrets][name] != nil && [nearby ownDeviceTagAtDate:[NSDate date]] != nil,
           "the matcher knows the laptop, and this device has a tag of its own");
    [nearby rebuildTagMatcher];
    NSData *laptopSecret = SZFriendsSyncDeviceTagSecret([nearby activeSyncEngine].ownDevicesSecret, laptopID.publicKey);
    NSData *laptopTag = SZFriendsPresenceTag(laptopSecret, SZFriendsPresenceWindowIndex([NSDate date]));
    EXPECT([nearby.coordinator.merger.tagMatcher(laptopTag) isEqualToString:name], "its tag names it nearby");
    SZFriendsOnlineFriend *online = [nearby onlineDriver:(SZFriendsOnlineDriver *)(id)nearby
                                   friendWithIdentityKey:laptopID.publicKey];
    EXPECT([online.staticKey isEqualToData:laptopID.staticPublicKey], "online, the driver reaches it as a friend");
    [nearby refreshAdvertisement];
    EXPECT([adapter.lastCallbackTags containsObject:[nearby ownDeviceTagAtDate:[NSDate date]]],
           "which it advertises: %@", adapter.lastCallbackTags);

    // Both dialed at once: one session per device stays.
    SZFriendsPeerLink *second = SZFNOwnLink(laptopID, YES);
    [nearby linkWentLive:second];
    BOOL firstOpen = !((SZFNFakeChannel *)link.channel).closed;
    BOOL secondOpen = !((SZFNFakeChannel *)second.channel).closed;
    EXPECT(firstOpen != secondOpen, "exactly one of the two sessions stays");

    // Ended sessions leave nothing behind; a device we revoke is refused.
    [nearby link:link closedWithError:nil];
    [nearby link:second closedWithError:nil];
    EXPECT(nearby.syncLinks.count == 0, "no session left: %@", nearby.syncLinks);
    // Seen nearby by its tag, the laptop is dialed with IK, once until the dial ends.
    SZFriendsSighting *sighting = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                                      route:SZFriendsRouteMethodLAN
                                                                 endpointID:@"laptop"
                                                                presenceTag:SZFNBytes(SZFriendsPresenceTagLength)
                                                               callbackTags:@[ laptopTag ]
                                                                   isPublic:NO
                                                                     seenAt:[NSDate date]];
    [nearby.coordinator.merger addSighting:sighting];
    [nearby reconsider];
    NSString *hex = SZFriendsLinkHex(laptopID.publicKey);
    EXPECT(nearby.syncDialAfter[hex] != nil && nearby.dialing.count == 1, "dialed: %@", nearby.dialing);
    [nearby reconsider];
    EXPECT(nearby.dialing.count == 1, "and not twice");
    SZFriendsDeviceChain *revoked = [two chainByRevokingDeviceKey:laptopID.publicKey signedBy:services.identity
                                                             date:[NSDate date] error:NULL];
    [store mergeOwnDeviceChain:revoked error:NULL];
    EXPECT(![nearby isOwnDeviceKey:laptopID.publicKey] && ![nearby isOwnDeviceKey:outsider.publicKey],
           "a revoked device, like an outsider, is not one of ours");
    // It may finish IK only to be told it was removed (+Removed): nothing else of it is admitted.
    EXPECT([nearby allowRemoteKey:laptopID.publicKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO] &&
               ![nearby allowRemoteKey:laptopID.publicKey pattern:SZFriendsHandshakeXX token:nil link:nil
                          publicEntry:YES] &&
               ![nearby allowRemoteKey:laptopID.publicKey pattern:SZFriendsHandshakeNN token:nil link:nil
                          publicEntry:NO],
           "IK only, for the chain that removed it");
    // Our matcher knows its tags still, under the own-devices secret it holds, to find it and tell it.
    NSString *removedName = [@"rmv-" stringByAppendingString:hex];
    EXPECT([nearby removedDeviceTagSecrets][removedName].count >= 1, "its tags: %@", [nearby removedDeviceTagSecrets]);
    [laptop.store close];
    [services close];
}

// Friends reach whichever of a person's devices they find: a friend's other device has tags of its own, which our
// matcher names with the friend's conversation, and the driver reaches it online with the static key its chain gives
// it; on our side, a device that is not the first advertises its own tag instead of the person's.
void SZFNTestFriendDevices(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"friend-devices");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFNRecordingAdapter *adapter = [[SZFNRecordingAdapter alloc] init];
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[ adapter ]);
    SZFriendsIdentity *meiRoot = SZFNSyncDevice(0x71), *meiLaptop = SZFNSyncDevice(0x72);
    SZFriendsPersonRecord *mei = SZFNSavePerson(store, SZFriendsRelationFriend);
    // SZFNSavePerson gives Mei random keys; she is the person whose root is meiRoot here.
    SZFriendsPersonRecord *friend = [[SZFriendsPersonRecord alloc] init];
    friend.identityKey = meiRoot.publicKey;
    friend.staticKey = meiRoot.staticPublicKey;
    friend.presenceSecret = SZFNBytes(32);
    friend.picture = [SZFriendsPicture placeholder];
    friend.relation = SZFriendsRelationFriend;
    friend.lastInteractionAt = [NSDate date];
    [store savePerson:friend error:NULL];
    (void)mei;
    SZFriendsDeviceChain *genesis = [SZFriendsDeviceChain genesisChainWithIdentity:meiRoot name:@"iMac" system:@"macOS"
                                                                              date:[NSDate date] error:NULL];
    SZFriendsDeviceChain *two = [genesis chainByAddingDeviceKey:meiLaptop.publicKey staticKey:meiLaptop.staticPublicKey
                                                       consent:SZFriendsDeviceConsent(meiLaptop, genesis.rootKey)
                                                          name:@"MacBook" system:@"macOS" signedBy:meiRoot
                                                          date:[NSDate date] error:NULL];
    [store mergeDeviceChainData:two.encodedData forRootKey:meiRoot.publicKey error:NULL];
    [nearby rebuildTagMatcher];
    NSData *secret = SZFriendsSyncFriendDeviceTagSecret(friend.presenceSecret, meiLaptop.publicKey);
    NSData *tag = SZFriendsPresenceTag(secret, SZFriendsPresenceWindowIndex([NSDate date]));
    NSString *name = nearby.coordinator.merger.tagMatcher(tag);
    NSData *device = nil;
    EXPECT([SZFriendsNearbyFriendDeviceConversation(name, &device) isEqualToString:friend.conversationID] &&
               [device isEqualToData:meiLaptop.publicKey],
           "her laptop's tag names her conversation and the laptop: %@", name);
    SZFriendsOnlineFriend *online = [nearby onlineDriver:(SZFriendsOnlineDriver *)(id)nearby
                                   friendWithIdentityKey:meiLaptop.publicKey];
    EXPECT([online.staticKey isEqualToData:meiLaptop.staticPublicKey] &&
               [online.presenceSecret isEqualToData:friend.presenceSecret],
           "online, her laptop is reached with the static key her chain gives it");

    // Our side: the first device advertises the person's tag; a second device its own.
    store.ownPresenceSecret = SZFNBytes(32);
    [store ownDeviceChainCreatingGenesisWithIdentity:services.identity error:NULL];
    EXPECT([nearby ownFriendPresenceTagAtDate:[NSDate date]] == nil, "the first device keeps the person's tag");
    SZFriendsIdentity *first = SZFNSyncDevice(0x73);
    SZFriendsDeviceChain *ours = [SZFriendsDeviceChain genesisChainWithIdentity:first name:@"iMac" system:@"macOS"
                                                                           date:[NSDate date] error:NULL];
    SZFriendsIdentity *me = services.identity;
    ours = [ours chainByAddingDeviceKey:me.publicKey staticKey:me.staticPublicKey
                                consent:SZFriendsDeviceConsent(me, ours.rootKey) name:@"Mac mini" system:@"macOS"
                               signedBy:first date:[NSDate date] error:NULL];
    EXPECT([store adoptOwnDeviceChain:ours localDeviceKey:me.publicKey error:NULL], "joined another profile");
    NSData *mine = [nearby ownFriendPresenceTagAtDate:[NSDate date]];
    [nearby refreshAdvertisement];
    EXPECT(mine != nil && [adapter.lastTag isEqualToData:mine], "a second device advertises a tag of its own");
    // Just joined, it cannot match its siblings' tags yet: it tries IK at devices nobody's tags match, once a window.
    SZFriendsSighting *unknown = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                                     route:SZFriendsRouteMethodLAN
                                                                endpointID:@"somebody"
                                                               presenceTag:SZFNBytes(SZFriendsPresenceTagLength)
                                                              callbackTags:@[]
                                                                  isPublic:NO
                                                                    seenAt:[NSDate date]];
    [nearby.coordinator.merger addSighting:unknown];
    [nearby reconsider];
    NSUInteger probes = 0;
    for (NSString *key in nearby.attempts) probes += [key hasPrefix:@"own|"];
    EXPECT(probes == 1 && nearby.dialing.count == 1, "one probe for the first device: %@", nearby.attempts);
    [nearby reconsider];
    EXPECT(nearby.dialing.count == 1, "and only once this window");
    [services close];
}

// The profile moves like a friend's files (ADR 0001 § Session race, ADR 0011 § Route rank): of two sessions with one
// of our devices the better route in the owner's order carries the sync, whichever went live first and whoever dialed;
// a double dial on one class answered here waits and takes over when the initiator closes the other; and while a
// session carries the sync, a sighting on a better route is dialed and one on a worse route is not.
void SZFNTestOwnDeviceRouteMigration(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"own-routes");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFNRecordingAdapter *adapter = [[SZFNRecordingAdapter alloc] init];
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[ adapter ]);
    SZFriendsIdentity *laptopID = SZFNSyncDevice(0x63);
    SZFriendsDeviceChain *genesis = [store ownDeviceChainCreatingGenesisWithIdentity:services.identity error:NULL];
    SZFriendsDeviceChain *two = [genesis chainByAddingDeviceKey:laptopID.publicKey staticKey:laptopID.staticPublicKey
                                                       consent:SZFriendsDeviceConsent(laptopID, genesis.rootKey)
                                                          name:@"MacBook Air" system:@"macOS 26.1"
                                                      signedBy:services.identity date:[NSDate date] error:NULL];
    [store mergeOwnDeviceChain:two error:NULL];
    EXPECT([nearby activeSyncEngine] != nil, "sync runs with the laptop in our chain");
    NSString *hex = SZFriendsLinkHex(laptopID.publicKey);
    SZFriendsRouteMethod order[] = {SZFriendsRouteMethodLAN, SZFriendsRouteMethodPeerToPeerWiFi,
                                    SZFriendsRouteMethodInternet, SZFriendsRouteMethodBluetooth,
                                    SZFriendsRouteMethodRelay};
    size_t count = sizeof(order) / sizeof(order[0]);
    for (size_t i = 0; i < count; i++) {
        for (size_t j = i + 1; j < count; j++) {
            for (int firstBetter = 0; firstBetter < 2; firstBetter++) {
                for (int dialers = 0; dialers < 4; dialers++) {
                    SZFriendsRouteMethod firstRoute = firstBetter ? order[i] : order[j];
                    SZFriendsRouteMethod secondRoute = firstBetter ? order[j] : order[i];
                    SZFriendsPeerLink *first = SZFNOwnLinkOn(laptopID, dialers & 1, firstRoute);
                    SZFriendsPeerLink *second = SZFNOwnLinkOn(laptopID, (dialers >> 1) & 1, secondRoute);
                    [nearby linkWentLive:first];
                    [nearby linkWentLive:second];
                    SZFriendsPeerLink *better = firstBetter ? first : second, *worse = firstBetter ? second : first;
                    EXPECT(nearby.syncLinks[hex] == better && better.syncExchange != nil &&
                               !((SZFNFakeChannel *)better.channel).closed && ((SZFNFakeChannel *)worse.channel).closed,
                           "route %ld carries the sync over route %ld (first %ld, dialers %d)", (long)order[i],
                           (long)order[j], (long)firstRoute, dialers);
                    [nearby link:first closedWithError:nil];
                    [nearby link:second closedWithError:nil];
                    EXPECT(nearby.syncLinks.count == 0, "nothing left after both end");
                }
            }
        }
    }
    // The laptop dialed twice on one class: this side keeps the first, holds the second, and moves to it when the
    // laptop closes the first.
    SZFriendsPeerLink *carrying = SZFNOwnLinkOn(laptopID, NO, SZFriendsRouteMethodLAN);
    SZFriendsPeerLink *standby = SZFNOwnLinkOn(laptopID, NO, SZFriendsRouteMethodLAN);
    [nearby.links addObject:carrying]; // as -startLink: would have
    [nearby.links addObject:standby];
    [nearby linkWentLive:carrying];
    [nearby linkWentLive:standby];
    EXPECT(nearby.syncLinks[hex] == carrying && !((SZFNFakeChannel *)standby.channel).closed &&
               standby.syncExchange == nil,
           "the responder waits for the initiator's choice");
    [nearby link:carrying closedWithError:nil];
    EXPECT(nearby.syncLinks[hex] == standby && standby.syncExchange != nil, "the standby session carries the sync");
    [nearby link:standby closedWithError:nil];

    // With Bluetooth carrying the sync, the laptop seen on the network is dialed; seen on Bluetooth again, it is not.
    SZFriendsPeerLink *bluetooth = SZFNOwnLinkOn(laptopID, YES, SZFriendsRouteMethodBluetooth);
    [nearby linkWentLive:bluetooth];
    EXPECT(nearby.syncLinks[hex] == bluetooth, "Bluetooth carries the sync");
    [nearby changed];
    SZFNSpin(0.6);
    [nearby rebuildTagMatcher];
    NSData *secret = SZFriendsSyncDeviceTagSecret([nearby activeSyncEngine].ownDevicesSecret, laptopID.publicKey);
    NSData *tag = SZFriendsPresenceTag(secret, SZFriendsPresenceWindowIndex([NSDate date]));
    SZFriendsSighting *(^seen)(SZFriendsRouteMethod, NSString *) = ^(SZFriendsRouteMethod route, NSString *endpoint) {
        return [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                   route:route
                                              endpointID:endpoint
                                             presenceTag:SZFNBytes(SZFriendsPresenceTagLength)
                                            callbackTags:@[ tag ]
                                                isPublic:NO
                                                  seenAt:[NSDate date]];
    };
    [nearby.coordinator.merger addSighting:seen(SZFriendsRouteMethodRelay, @"laptop-worse")];
    [nearby reconsider];
    EXPECT(nearby.dialing.count == 0, "a worse route is not dialed beside Bluetooth: %@", nearby.dialing);
    [nearby.coordinator.merger addSighting:seen(SZFriendsRouteMethodLAN, @"laptop-lan")];
    [nearby reconsider];
    BOOL lanDialed = NO;
    for (NSString *key in nearby.dialing) lanDialed = lanDialed || [key hasSuffix:@"|laptop-lan"];
    EXPECT(lanDialed, "the network is dialed while Bluetooth carries the sync: %@", nearby.dialing);
    [nearby link:bluetooth closedWithError:nil];
    [services close];
}
