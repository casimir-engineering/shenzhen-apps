// friends-helper-check: first contact from a device other than a person's first (ADR 0012, Consequences). A joined
// computer sends its chain before its request and before its answer to an Add by ID; the first computer sends none.
// The person it reaches is kept under the root the chain names, with the first computer's static key, so the other
// devices of that person find the same row; a chain that does not name the device that sent it changes nothing; and a
// row an answer made under the device's own key moves to the root once its chain arrives.

#import "SZFriendsHelperNearbyTests.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"

// A fake channel from a device whose keys a verified handshake would name, on session minor 2.
@interface SZFNContactChannel : SZFNFakeChannel
@property(nonatomic, copy) NSData *deviceKey;
@property(nonatomic, copy) NSData *deviceStaticKey;
@end

@implementation SZFNContactChannel
- (NSData *)remoteIdentityKey {
    return self.deviceKey;
}
- (NSData *)remoteStaticKey {
    return self.deviceStaticKey;
}
- (NSUInteger)negotiatedMinor {
    return 2;
}
- (SZFriendsRouteMethod)initiatorRoute {
    return SZFriendsRouteMethodLAN;
}
- (NSData *)presentedRequestToken {
    return nil;
}
@end

static SZFriendsIdentity *SZFNSeeded(uint8_t seed) {
    NSMutableData *signing = [NSMutableData dataWithLength:32], *key = [NSMutableData dataWithLength:32];
    memset(signing.mutableBytes, seed, 32);
    memset(key.mutableBytes, seed ^ 0x5a, 32);
    return [SZFriendsIdentity identityWithSigningSeed:signing staticPrivateKey:key];
}

// Mei's first computer (root) and her laptop, added to it.
static SZFriendsDeviceChain *SZFNMeiChain(SZFriendsIdentity *root, SZFriendsIdentity *laptop) {
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"Mei’s iMac"
                                                                         system:@"macOS 26.1" date:[NSDate date]
                                                                          error:NULL];
    return [chain chainByAddingDeviceKey:laptop.publicKey staticKey:laptop.staticPublicKey
                                 consent:SZFriendsDeviceConsent(laptop, root.publicKey) name:@"Mei’s MacBook Air"
                                  system:@"macOS 26.1" signedBy:root date:[NSDate date] error:NULL];
}

static SZFriendsPeerLink *SZFNDeviceLink(SZFriendsNearbyService *nearby, SZFriendsIdentity *device, BOOL dialed) {
    SZFNContactChannel *channel = [[SZFNContactChannel alloc] init];
    channel.pattern = SZFriendsHandshakeXX;
    channel.isInitiator = dialed;
    channel.deviceKey = device.publicKey;
    channel.deviceStaticKey = device.staticPublicKey;
    SZFriendsPeerLink *link = SZFNLink(channel);
    link.live = YES;
    [nearby.links addObject:link];
    return link;
}

static SZFriendsFrame *SZFNChainFrame(SZFriendsDeviceChain *chain) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeChain fields:@{@(SZFriendsFieldChain) : chain.encodedData}];
}

static void TestRequestFromALaptop(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"first-contact-in");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsStore *store = services.store;
    SZFriendsIdentity *root = SZFNSeeded(0x61), *laptop = SZFNSeeded(0x62), *other = SZFNSeeded(0x63);
    SZFriendsDeviceChain *chain = SZFNMeiChain(root, laptop);

    // A chain that is not the sender's: kept nowhere, and the request names the device as before.
    SZFriendsPeerLink *wrong = SZFNDeviceLink(nearby, other, NO);
    wrong.stranger = YES;
    [nearby link:wrong receivedFrame:SZFNChainFrame(chain)];
    EXPECT(wrong.pendingChain == nil, "a chain that does not name its sender is ignored");

    SZFriendsPeerLink *link = SZFNDeviceLink(nearby, laptop, NO);
    link.stranger = YES;
    [nearby link:link receivedFrame:SZFNChainFrame(chain)];
    [nearby link:link receivedFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeRequest
                                                           fields:@{@(SZFriendsFieldID) : SZFNBytes(16)}]];
    SZFriendsPersonRecord *mei = [store personWithIdentityKey:root.publicKey];
    EXPECT(mei != nil && mei.relation == SZFriendsRelationIncomingRequest, "the request is Mei's, by her root");
    EXPECT([mei.staticKey isEqual:root.staticPublicKey], "dialed at her first computer");
    EXPECT([[store personWithIdentityKey:laptop.publicKey].conversationID isEqual:mei.conversationID],
           "her laptop finds the same row");
    EXPECT([[store rootKeyForDeviceKey:laptop.publicKey] isEqual:root.publicKey], "her chain is kept");
}

static void TestAnswerMovesToTheRoot(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"first-contact-answer");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsStore *store = services.store;
    SZFriendsIdentity *root = SZFNSeeded(0x71), *laptop = SZFNSeeded(0x72);
    // Our Add by ID was answered by Mei's laptop: the row names the laptop's key.
    SZFriendsPersonRecord *row = [[SZFriendsPersonRecord alloc] init];
    row.conversationID = SZFriendsNewIdentifier();
    row.identityKey = laptop.publicKey;
    row.staticKey = laptop.staticPublicKey;
    row.relation = SZFriendsRelationOutgoingRequest;
    row.picture = [SZFriendsPicture placeholder];
    row.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:row error:NULL], "an answered Add by ID");
    SZFriendsPeerLink *link = SZFNDeviceLink(nearby, laptop, NO);
    link.conversationID = row.conversationID;
    link.adopted = YES;
    [nearby link:link receivedFrame:SZFNChainFrame(SZFNMeiChain(root, laptop))];
    SZFriendsPersonRecord *moved = [store personWithConversationID:row.conversationID];
    EXPECT([moved.identityKey isEqual:root.publicKey] && [moved.staticKey isEqual:root.staticPublicKey],
           "the row is Mei's now: %@", moved.identityKey);
    EXPECT(!((SZFNFakeChannel *)(id)link.channel).closed, "and the session goes on");
}

static void TestLaptopSendsItsChainFirst(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"first-contact-out");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsStore *store = services.store;
    SZFriendsIdentity *root = SZFNSeeded(0x81), *stranger = SZFNSeeded(0x83);
    SZFriendsDeviceChain *chain = SZFNMeiChain(root, services.identity);
    EXPECT([store adoptOwnDeviceChain:chain localDeviceKey:services.identity.publicKey error:NULL], "joined");
    SZFriendsPersonRecord *lena = [[SZFriendsPersonRecord alloc] init];
    lena.conversationID = SZFriendsNewIdentifier();
    lena.identityKey = stranger.publicKey;
    lena.staticKey = stranger.staticPublicKey;
    lena.relation = SZFriendsRelationOutgoingRequest;
    lena.picture = [SZFriendsPicture placeholder];
    lena.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:lena error:NULL], "a request to Lena");
    [nearby enqueueKind:SZFriendsOutboxKindRequest conversationID:lena.conversationID payload:nil];
    SZFriendsPeerLink *link = SZFNDeviceLink(nearby, stranger, YES);
    link.conversationID = lena.conversationID;
    link.adopted = YES;
    [nearby deliverPendingOnLink:link];
    NSArray<SZFriendsFrame *> *sent = ((SZFNFakeChannel *)(id)link.channel).sent;
    NSUInteger chainAt = NSNotFound, requestAt = NSNotFound;
    for (NSUInteger i = 0; i < sent.count; i++) {
        if (sent[i].type == SZFriendsFrameTypeChain && chainAt == NSNotFound) chainAt = i;
        if (sent[i].type == SZFriendsFrameTypeRequest && requestAt == NSNotFound) requestAt = i;
    }
    EXPECT(chainAt != NSNotFound && requestAt != NSNotFound && chainAt < requestAt,
           "the chain goes before the request: %lu %lu", (unsigned long)chainAt, (unsigned long)requestAt);
}

void SZFNTestFirstContact(NSString *scratch) {
    TestRequestFromALaptop(scratch);
    TestAnswerMovesToTheRoot(scratch);
    TestLaptopSendsItsChainFirst(scratch);
}
