// friends-helper-check, the wave-4 re-check's helper findings: an Add by ID answer the host did not vouch for becomes
// a request the person accepts and gets no presence secret, keys of our own requests stop reaching the hidden listener
// once no answer can come, and one address may open only a few NN sessions a minute.

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/nearby/SZFriendsNearbyLimits.h"

// A responder's channel for an IK callback that presented our Add by ID token.
@interface SZFNCallbackChannel : SZFNFakeChannel
@property(nonatomic, copy) NSData *answerKey;
@property(nonatomic, copy) NSData *answerStaticKey;
@property(nonatomic, copy) NSData *presentedRequestToken;
@end

@implementation SZFNCallbackChannel
- (NSData *)remoteIdentityKey {
    return _answerKey;
}
- (NSData *)remoteStaticKey {
    return _answerStaticKey;
}
@end

static SZFriendsPeerLink *SZFNCallback(NSData *token) {
    SZFNCallbackChannel *channel = [[SZFNCallbackChannel alloc] init];
    channel.pattern = SZFriendsHandshakeIK;
    channel.answerKey = SZFNBytes(32);
    channel.answerStaticKey = SZFNBytes(32);
    channel.presentedRequestToken = token;
    channel.handshakeHash = SZFNBytes(64);
    return SZFNLink(channel);
}

static NSData *SZFNAskByID(SZFriendsStore *store, NSString *friendsID, NSDate *createdAt) {
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.targetFriendsID = friendsID;
    request.requestToken = SZFNBytes(16);
    request.callbackSecret = SZFNBytes(32);
    request.createdAt = createdAt;
    request.expiresAt = [createdAt dateByAddingTimeInterval:SZFriendsIDRequestLifetime];
    EXPECT([store startIDRequest:request error:NULL] != nil, "asked for %@", friendsID);
    return request.requestToken;
}

static BOOL SZFNQueuedPresenceSecret(SZFriendsHelperServices *services, NSString *conversationID) {
    for (SZFriendsOutboxEntry *entry in [services.outbox pendingEntriesForConversation:conversationID])
        if (entry.kind == SZFriendsOutboxKindPresenceSecret) return YES;
    return NO;
}

// The answer arrives on its callback and says ACCEPT.
static NSString *SZFNAnswerAccepts(SZFriendsNearbyService *nearby, SZFriendsPeerLink *link) {
    NSString *conversation = [nearby conversationForCallbackLink:link];
    link.conversationID = conversation;
    link.live = YES;
    link.tokenAdmitted = YES;
    [nearby.links addObject:link];
    SZFriendsFrame *accept = [SZFriendsFrame frameWithType:SZFriendsFrameTypeAccept
                                                    fields:@{@(SZFriendsFieldID) : SZFNBytes(16)}];
    [nearby link:link receivedFrame:accept];
    return conversation;
}

// Wave-4 re-check: an unattested answer's ACCEPT made a friend at once and queued our presence secret, so anyone who
// heard the broadcast could answer under the name of the person we meant and recognise us nearby from then on.
void SZFNTestUnconfirmedAcceptIsARequest(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"unconfirmed");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    NSData *token = SZFNAskByID(store, @"orchid-summit", [NSDate date]);
    SZFriendsPeerLink *bystander = SZFNCallback(token);
    NSString *row = SZFNAnswerAccepts(nearby, bystander);
    SZFriendsPersonRecord *person = row ? [store personWithConversationID:row] : nil;
    EXPECT(person.relation == SZFriendsRelationIncomingRequest && [person.unconfirmedAnswerID isEqual:@"orchid-summit"],
           "a request the person accepts, naming the ID we asked for: %ld %@", (long)person.relation,
           person.unconfirmedAnswerID);
    EXPECT(!SZFNQueuedPresenceSecret(services, row), "and no presence secret goes to them");
    EXPECT([((SZFNFakeChannel *)bystander.channel).sent.lastObject type] == SZFriendsFrameTypeAck,
           "their answer is acknowledged, so they stop sending it");
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:services now:[NSDate date]];
    EXPECT([[pass personWithConversationID:row].unconfirmedAnswerID isEqual:@"orchid-summit"],
           "the views are told what was asked for");
    EXPECT(![nearby allowRemoteKey:bystander.channel.remoteIdentityKey pattern:SZFriendsHandshakeIK token:nil link:nil
                       publicEntry:NO],
           "and they cannot find our listener later");

    // The holder the host vouches for: a friend at once, with our secret.
    NSData *second = SZFNAskByID(store, @"tulip-canyon", [NSDate date]);
    SZFriendsPeerLink *holder = SZFNCallback(second);
    NSString *conversation = [nearby conversationForCallbackLink:holder];
    holder.answerAttested = YES; // what +Attestation decides for a valid attestation (its own tests)
    holder.conversationID = conversation;
    holder.live = YES;
    holder.tokenAdmitted = YES;
    [nearby.links addObject:holder];
    [nearby link:holder receivedFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeAccept
                                                             fields:@{@(SZFriendsFieldID) : SZFNBytes(16)}]];
    EXPECT([store personWithConversationID:conversation].relation == SZFriendsRelationFriend &&
               SZFNQueuedPresenceSecret(services, conversation),
           "an attested ACCEPT is a friendship, and our secret goes");
    [nearby.links removeAllObjects];
    [services close];
}

// Someone saved as an outgoing request whose clock started `daysAgo`.
static SZFriendsPersonRecord *SZFNAskedNearby(SZFriendsStore *store, double daysAgo) {
    SZFriendsPersonRecord *person = SZFNSavePerson(store, SZFriendsRelationRemoved);
    person.relation = SZFriendsRelationOutgoingRequest;
    person.requestFoundNearby = YES;
    person.requestAt = [NSDate dateWithTimeIntervalSinceNow:-daysAgo * 86400];
    EXPECT([store savePerson:person error:NULL]);
    return person;
}

// Wave-4 re-check (P1): IK from an outgoing request's key had no time limit, so a bystander who answered our Add by
// ID once, then never accepted, could follow us for good.
void SZFNTestOutgoingRequestKeys(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"outgoing");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    BOOL (^admits)(SZFriendsPersonRecord *) = ^BOOL(SZFriendsPersonRecord *person) {
        return [nearby allowRemoteKey:person.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil
                          publicEntry:NO];
    };
    EXPECT(admits(SZFNAskedNearby(store, 2)), "a nearby request answered within its week");
    EXPECT(!admits(SZFNAskedNearby(store, 8)), "not after it");
    // Add by ID answers: one within its request's week, one whose request has expired.
    NSArray<NSNumber *> *ages = @[ @1, @8 ];
    NSMutableArray<SZFriendsPersonRecord *> *answers = [NSMutableArray array];
    for (NSNumber *age in ages) {
        NSDate *created = [NSDate dateWithTimeIntervalSinceNow:-age.doubleValue * 86400];
        NSData *token = SZFNAskByID(store, [NSString stringWithFormat:@"asked-%@", age], created);
        NSData *key = SZFNBytes(32);
        NSString *row = [store conversationForIDRequestAnswerWithToken:token identityKey:key staticKey:SZFNBytes(32)
                                                              attested:NO atDate:[created dateByAddingTimeInterval:60]
                                                                 error:NULL];
        SZFriendsPersonRecord *person = row ? [store personWithConversationID:row] : nil;
        EXPECT(person.relation == SZFriendsRelationOutgoingRequest, "answered %@ days ago", age);
        if (person) [answers addObject:person];
    }
    EXPECT(answers.count == 2 && admits(answers[0]), "an answer's key while its request lasts");
    EXPECT(answers.count == 2 && !admits(answers[1]), "not once the request expired");
    [services close];
}

// Wave-4 re-check: NN allowed 60 sessions a minute per listener and none per address, so one host could keep
// everyone else's Add by ID from reaching a device.
void SZFNTestNNPerAddress(NSString *scratch) {
    (void)scratch;
    SZFriendsAdmissionLimits *limits = SZFriendsNearbyAdmissionLimits();
    EXPECT(limits.nnPerMinutePerAddress == SZFriendsAdmissionNNPerAddressPerMinute &&
               SZFriendsAdmissionNNPerAddressPerMinute == 6 && limits.nnPerMinutePerListener == 60,
           "NN: %lu a minute per address, %lu per listener", (unsigned long)limits.nnPerMinutePerAddress,
           (unsigned long)limits.nnPerMinutePerListener);
}
