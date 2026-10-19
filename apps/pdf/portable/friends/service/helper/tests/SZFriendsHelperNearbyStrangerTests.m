// friends-helper-check: what someone who is not a friend may cost, as the wave-3 security re-check narrowed it. A
// stranger's session moves forward only on frames that advance their request, lasts three minutes at most, and gives
// up its place to a newcomer when the cap is full; a pending request opens our hidden listener for six hours, not
// for as long as it waits, and lapses after 14 days. Links carry fake channels; nothing is dialed or listened on.

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHelperTesting.h"
#import "service/identity/SZFriendsIdentity.h"

// Counts how often the idle check asks about one link, to show a friend's quiet session is not checked continuously.
@interface SZFNCountingNearby : SZFriendsNearbyService
@property(nonatomic, weak) SZFriendsPeerLink *watched;
@property(nonatomic) NSUInteger watchedChecks;
@end

@implementation SZFNCountingNearby
- (BOOL)linkIsWithFriend:(SZFriendsPeerLink *)link {
    if (link == self.watched) self.watchedChecks++;
    return [super linkIsWithFriend:link];
}
@end

static SZFriendsPeerLink *SZFNStrangerLink(SZFriendsNearbyService *nearby, SZFriendsHandshakePattern pattern) {
    SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
    channel.pattern = pattern;
    SZFriendsPeerLink *link = SZFNLink(channel);
    link.stranger = YES;
    [nearby.links addObject:link];
    return link;
}

static SZFriendsFrame *SZFNFrame(SZFriendsFrameType type, NSDictionary<NSNumber *, NSData *> *fields) {
    return [SZFriendsFrame frameWithType:type fields:fields];
}

static SZFNFakeChannel *SZFNChannelOf(SZFriendsPeerLink *link) {
    return (SZFNFakeChannel *)(id)link.channel;
}

// An Add by ID of ours to `friendsID`, on a keyless "Request sent" row: returns its token.
static NSData *SZFNSaveIDRequest(SZFriendsStore *store, NSString *friendsID) {
    SZFriendsPersonRecord *row = [[SZFriendsPersonRecord alloc] init];
    row.conversationID = SZFriendsNewIdentifier();
    row.friendsID = friendsID;
    row.picture = [SZFriendsPicture placeholder];
    row.relation = SZFriendsRelationOutgoingRequest;
    row.requestAt = row.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:row error:NULL]);
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = row.conversationID;
    request.targetFriendsID = friendsID;
    request.requestToken = SZFNBytes(16);
    request.callbackSecret = SZFNBytes(32);
    request.createdAt = [NSDate date];
    request.expiresAt = [request.createdAt dateByAddingTimeInterval:86400];
    EXPECT([store saveIDRequest:request error:NULL]);
    return request.requestToken;
}

// Review (stranger sessions): with 64 strangers' sessions open the 65th used to be refused, so whoever opened 64
// first kept every later request and Add by ID out. Now the session idle longest makes room.
void SZFNTestStrangerCap(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"cap");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsPersonRecord *friend = SZFNSavePerson(services.store, SZFriendsRelationFriend);
    NSMutableArray<SZFriendsPeerLink *> *crowd = [NSMutableArray array];
    for (NSUInteger i = 0; i < SZFriendsStrangerSessionsMax; i++) {
        SZFriendsPeerLink *other = SZFNStrangerLink(nearby, SZFriendsHandshakeXX);
        // Each moved forward a little later than the one before; the second is the quietest of all.
        other.lastApplicationFrameAt = [NSDate dateWithTimeIntervalSinceNow:-100.0 + (double)i];
        [crowd addObject:other];
    }
    crowd[1].lastApplicationFrameAt = [NSDate dateWithTimeIntervalSinceNow:-500];
    EXPECT([nearby strangerLinkCount] == SZFriendsStrangerSessionsMax);
    SZFriendsPeerLink *newcomer = SZFNLink([[SZFNFakeChannel alloc] init]);
    EXPECT([nearby allowRemoteKey:nil pattern:SZFriendsHandshakeNN token:nil link:newcomer publicEntry:NO] &&
               newcomer.stranger,
           "the 65th stranger comes in");
    EXPECT(SZFNChannelOf(crowd[1]).closed && !crowd[1].stranger, "in place of the session idle longest");
    NSUInteger closed = 0;
    for (SZFriendsPeerLink *other in crowd) closed += SZFNChannelOf(other).closed ? 1 : 0;
    EXPECT(closed == 1, "and only that one: %lu closed", (unsigned long)closed);
    [nearby.links addObject:newcomer];
    EXPECT([nearby allowRemoteKey:SZFNBytes(32) pattern:SZFriendsHandshakeXX token:nil link:nil publicEntry:YES],
           "the next one too");
    EXPECT(SZFNChannelOf(crowd[0]).closed, "in place of the next quietest");
    SZFriendsPeerLink *friendLink = SZFNLink([[SZFNFakeChannel alloc] init]);
    EXPECT([nearby allowRemoteKey:friend.identityKey pattern:SZFriendsHandshakeIK token:nil link:friendLink
                      publicEntry:NO] && !friendLink.stranger,
           "friends never count and never wait");
    EXPECT(!SZFNChannelOf(crowd[2]).closed, "and close nobody");
    [nearby.links removeAllObjects];
    [services close];
}

// Review (idle limits): every frame used to restart a stranger's idle clock, so a PROFILE every 50 s, or a MESSAGE
// the helper drops, kept the session until its 24-hour maximum. Only frames that move a request forward count now.
void SZFNTestStrangerFrames(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"frames");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsPeerLink *link = SZFNStrangerLink(nearby, SZFriendsHandshakeXX);
    link.live = YES;
    NSDate *past = [NSDate dateWithTimeIntervalSinceNow:-30];
    SZFriendsFrame *profile = SZFNFrame(SZFriendsFrameTypeProfile, @{
        @(SZFriendsFieldName) : [@"Mallory" dataUsingEncoding:NSUTF8StringEncoding]});
    BOOL (^moves)(SZFriendsFrame *) = ^BOOL(SZFriendsFrame *frame) {
        link.lastApplicationFrameAt = past;
        [nearby link:link receivedFrame:frame];
        return [link.lastApplicationFrameAt compare:past] == NSOrderedDescending;
    };
    EXPECT(moves(profile), "the first PROFILE moves the request forward");
    EXPECT(!moves(profile), "the same PROFILE again does not");
    NSDictionary *message = @{@(SZFriendsFieldID) : SZFNBytes(16),
                              @(SZFriendsFieldText) : [@"hi" dataUsingEncoding:NSUTF8StringEncoding]};
    EXPECT(!moves(SZFNFrame(SZFriendsFrameTypeMessage, message)), "a message a stranger may not send");
    EXPECT(!moves(SZFNFrame(SZFriendsFrameTypeCancel, @{@(SZFriendsFieldID) : SZFNBytes(16)})));
    NSData *wire = SZFNBytes(16);
    EXPECT(!moves(SZFNFrame(SZFriendsFrameTypeAck, @{@(SZFriendsFieldID) : wire})), "an ACK for nothing");
    [link expectAckForID:SZFriendsLinkHex(wire) token:SZFriendsNewIdentifier()];
    EXPECT(moves(SZFNFrame(SZFriendsFrameTypeAck, @{@(SZFriendsFieldID) : wire})),
           "an ACK of something we sent");
    EXPECT(moves(SZFNFrame(SZFriendsFrameTypeRequest, @{@(SZFriendsFieldID) : SZFNBytes(16)})),
           "the first REQUEST");
    EXPECT(!moves(SZFNFrame(SZFriendsFrameTypeRequest, @{@(SZFriendsFieldID) : SZFNBytes(16)})),
           "but not a second");
    [nearby.links removeAllObjects];
    [services close];
}

// Review (idle limits): a stranger's session ends three minutes after going live however busy it is (shortened
// here), a friend's never; and a friend's quiet session is looked at once per idle period, where the old check ran
// every 50 ms once the session had been quiet for a minute.
void SZFNTestStrangerLifetime(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"lifetime");
    if (services == nil) return;
    SZFNCountingNearby *nearby = [[SZFNCountingNearby alloc] initWithServices:services adapters:@[]
                                                                        queue:dispatch_get_main_queue()];
    services.nearby = nearby;
    SZFriendsHelperTestHooks.strangerIdleTimeout = 0.3;
    SZFriendsHelperTestHooks.strangerSessionLife = 0.8;
    SZFriendsPeerLink *busy = SZFNStrangerLink(nearby, SZFriendsHandshakeXX);
    SZFriendsPeerLink *friendLink = SZFNStrangerLink(nearby, SZFriendsHandshakeIK);
    friendLink.stranger = NO;
    friendLink.conversationID = SZFNSavePerson(services.store, SZFriendsRelationFriend).conversationID;
    nearby.watched = friendLink;
    for (SZFriendsPeerLink *link in @[ busy, friendLink ]) {
        link.live = YES;
        link.liveAt = [NSDate date];
        [nearby armIdleCheckForLink:link];
    }
    // A frame that moves its request forward every 150 ms.
    for (int i = 1; i <= 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 150 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(),
                       ^{ [nearby noteApplicationFrameOnLink:busy]; });
    }
    SZFNSpin(0.6);
    EXPECT(!SZFNChannelOf(busy).closed, "a stranger who keeps moving forward is not idle");
    SZFNSpin(0.45);
    EXPECT(SZFNChannelOf(busy).closed, "but goes when the session's life is over");
    SZFNSpin(0.3);
    EXPECT(!SZFNChannelOf(friendLink).closed, "a friend's session has no limit");
    EXPECT(nearby.watchedChecks >= 2 && nearby.watchedChecks <= 6,
           "looked at once per idle period, not continuously: %lu checks in 1.35 s",
           (unsigned long)nearby.watchedChecks);
    SZFriendsHelperTestHooks.strangerIdleTimeout = 0;
    SZFriendsHelperTestHooks.strangerSessionLife = 0;
    [nearby.links removeAllObjects];
    [services close];
}

// Review (key policy): someone whose request we left unanswered could open IK to our hidden listener for as long as
// it waited, and so find our device in every window; removed people could not answer our Add by ID at all.
void SZFNTestPendingRequestKeys(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"pending");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsPersonRecord *recent = SZFNSavePerson(store, SZFriendsRelationIncomingRequest);
    // Wave-4 re-check (P4): a request by Friends ID never taught its sender our static key, so IK from them helps only
    // someone who had the key already, and each fresh key they asked from opened a new window.
    EXPECT(![nearby allowRemoteKey:recent.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO],
           "a request that came by Friends ID never opens IK, even at once");
    recent.requestFoundNearby = YES;
    EXPECT([store savePerson:recent error:NULL]);
    EXPECT([nearby allowRemoteKey:recent.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO],
           "within six hours of asking, a requester who found us nearby can still withdraw over IK");
    SZFriendsIdentity *asker = [SZFriendsIdentity identityWithSigningSeed:SZFNBytes(32) staticPrivateKey:SZFNBytes(32)];
    SZFriendsPersonRecord *old = [[SZFriendsPersonRecord alloc] init];
    old.conversationID = SZFriendsNewIdentifier();
    old.identityKey = asker.publicKey;
    old.staticKey = asker.staticPublicKey;
    old.picture = [SZFriendsPicture placeholder];
    old.relation = SZFriendsRelationIncomingRequest;
    old.requestFoundNearby = YES;
    old.requestAt = old.lastInteractionAt = [NSDate dateWithTimeIntervalSinceNow:-7 * 3600];
    EXPECT([store savePerson:old error:NULL]);
    EXPECT(![nearby allowRemoteKey:old.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO],
           "seven hours later their IK is refused like a stranger's");
    // Asking again by ID, under a new token, does not reopen it.
    SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
    channel.pattern = SZFriendsHandshakeNN;
    channel.handshakeHash = SZFNBytes(64);
    SZFriendsFrame *again = SZFriendsMakeRequestByIDFrame(asker, store.friendsID, SZFNBytes(16), SZFNBytes(32),
                                                          channel.handshakeHash);
    SZFriendsPeerLink *nn = SZFNLink(channel);
    [nearby.links addObject:nn];
    [nearby link:nn receivedRequestByID:again];
    EXPECT([store personWithIdentityKey:asker.publicKey].relation == SZFriendsRelationIncomingRequest);
    EXPECT(![nearby allowRemoteKey:old.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO],
           "a repeated request keeps the time the request began");

    // A removed person answers our Add by ID for their ID with its token, and only with it.
    NSData *token = SZFNSaveIDRequest(store, @"tulip-canyon");
    SZFriendsPersonRecord *removed = SZFNSavePerson(store, SZFriendsRelationRemoved);
    EXPECT(![nearby allowRemoteKey:removed.identityKey pattern:SZFriendsHandshakeIK token:token
                              link:SZFNLink([[SZFNFakeChannel alloc] init]) publicEntry:NO],
           "not while nothing says the ID asked for is theirs: the store would not take them back");
    removed.friendsID = @"tulip-canyon"; // the ID they last told us
    EXPECT([store savePerson:removed error:NULL]);
    SZFriendsPeerLink *answer = SZFNLink([[SZFNFakeChannel alloc] init]);
    EXPECT([nearby allowRemoteKey:removed.identityKey pattern:SZFriendsHandshakeIK token:token link:answer
                      publicEntry:NO] && answer.stranger,
           "with our token, as someone who is not a friend");
    EXPECT(![nearby allowRemoteKey:removed.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO]);
    EXPECT(![nearby allowRemoteKey:removed.identityKey pattern:SZFriendsHandshakeIK token:SZFNBytes(16) link:nil
                       publicEntry:NO]);
    SZFriendsPersonRecord *blocked = SZFNSavePerson(store, SZFriendsRelationBlocked);
    EXPECT(![nearby allowRemoteKey:blocked.identityKey pattern:SZFriendsHandshakeIK token:token link:nil
                       publicEntry:NO],
           "blocked people never, token or not");
    [nearby.links removeAllObjects];
    [services close];
}

// A request by ID that starts a new friendship gets a new comparison code: the requester's row starts without one
// even when it was theirs before (they removed us, or we declined), and a stale code on our side alone meant
// neither side ever showed a code. A repeat of a waiting request keeps the code it has.
void SZFNTestRequestCodes(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"codes");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsIdentity *asker = [SZFriendsIdentity identityWithSigningSeed:SZFNBytes(32) staticPrivateKey:SZFNBytes(32)];
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = SZFriendsNewIdentifier();
    person.identityKey = asker.publicKey;
    person.staticKey = asker.staticPublicKey;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = SZFriendsRelationRemoved;
    person.comparisonCode = @"123456";
    person.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:person error:NULL]);
    SZFriendsFrame *(^ask)(void) = ^SZFriendsFrame * {
        SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
        channel.pattern = SZFriendsHandshakeNN;
        channel.handshakeHash = SZFNBytes(64);
        SZFriendsPeerLink *link = SZFNLink(channel);
        [nearby.links addObject:link];
        SZFriendsFrame *frame = SZFriendsMakeRequestByIDFrame(asker, store.friendsID, SZFNBytes(16), SZFNBytes(32),
                                                              channel.handshakeHash);
        [nearby link:link receivedRequestByID:frame];
        return frame;
    };
    ask();
    SZFriendsPersonRecord *now = [store personWithIdentityKey:asker.publicKey];
    EXPECT(now.relation == SZFriendsRelationIncomingRequest && now.comparisonCode == nil,
           "a new request: the old code goes (%@)", now.comparisonCode);
    now.comparisonCode = @"654321";
    EXPECT([store savePerson:now error:NULL]);
    [nearby.byIDSenders removeAllObjects]; // past the hourly limit per sender
    ask();
    EXPECT([[store personWithIdentityKey:asker.publicKey].comparisonCode isEqual:@"654321"],
           "the same request again keeps its code");
    [nearby.links removeAllObjects];
    [services close];
}

// Review (key policy): unanswered requests never lapsed. Fourteen days after it began, a request nobody answered
// goes, at start and from the hourly timer; a newer one stays.
void SZFNTestRequestExpiry(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"expiry");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsPersonRecord *stale = SZFNSavePerson(store, SZFriendsRelationIncomingRequest);
    stale.requestAt = [NSDate dateWithTimeIntervalSinceNow:-15 * 86400];
    SZFriendsPersonRecord *fresh = SZFNSavePerson(store, SZFriendsRelationIncomingRequest);
    fresh.requestAt = [NSDate dateWithTimeIntervalSinceNow:-13 * 86400];
    // Saved again as requests that began then (a request starts when it is first stored as one).
    for (SZFriendsPersonRecord *person in @[ stale, fresh ]) {
        person.relation = SZFriendsRelationRemoved;
        EXPECT([store savePerson:person error:NULL]);
        person.relation = SZFriendsRelationIncomingRequest;
        EXPECT([store savePerson:person error:NULL]);
    }
    EXPECT([services expireIncomingRequests], "one lapsed");
    SZFriendsPersonRecord *lapsed = [store personWithConversationID:stale.conversationID];
    EXPECT(lapsed == nil || lapsed.relation == SZFriendsRelationRemoved, "the 15-day-old request is gone");
    EXPECT([store personWithConversationID:fresh.conversationID].relation == SZFriendsRelationIncomingRequest,
           "the 13-day-old one waits");
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    EXPECT(![nearby allowRemoteKey:stale.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO],
           "and its key is let in no more");
    EXPECT(![services expireIncomingRequests], "nothing more to lapse");
    [services close];
}
