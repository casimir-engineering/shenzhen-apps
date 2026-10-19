// Whole openings of a download link over loopback, with the real transport and an in-memory sid in place of the host:
// the sender is the helper's link service, the opener the browser stand-in (SZFriendsLinkOpening). Gating, refusals,
// and a file arriving in an app's received files.

#import "SZFLinksTestSupport.h"

#import "service/identity/SZFriendsIdentity.h"

@implementation SZFLSenderWorld
@end

SZFriendsIdentity *SZFLNewIdentity(void) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFLRandom(32) staticPrivateKey:SZFLRandom(32)];
}

SZFLSenderWorld *SZFLSender(NSString *label) {
    SZFLSenderWorld *world = [SZFLSenderWorld new];
    world.directory = SZFLTemporaryDirectory(label);
    world.store = [SZFriendsStore storeInDirectory:world.directory error:NULL];
    world.store.friendsID = @"brave-otter";
    world.transfers = [[SZFriendsTransfers alloc] initWithStore:world.store stateDirectory:world.directory];
    world.identity = SZFLNewIdentity();
    world.transport = [[SZFLCountingTransport alloc] initWithTransport:SZFLLoopbackTransport()];
    world.service = [[SZFriendsLinkService alloc] initWithStore:world.store transfers:world.transfers
                                                       identity:world.identity stateDirectory:world.directory
                                                          queue:dispatch_get_main_queue()];
    world.service.linkOrigin = ^NSString * { return @"https://friends.example"; };
    world.service.profileName = ^NSString * { return @"Mei"; };
    SZFLCountingTransport *transport = world.transport;
    world.service.environment = ^SZFriendsLinkEnvironment * { return SZFLEnvironment(transport); };
    return world;
}

// make_download_link's work: the payload of a new link to `bytes`.
SZFriendsDownloadLinkPayload *SZFLMakeLink(SZFLSenderWorld *world, NSData *bytes, NSString **path) {
    NSString *file = [world.directory stringByAppendingPathComponent:@"Site photos.pdf"];
    [bytes writeToFile:file atomically:NO];
    if (path) *path = file;
    __block SZFriendsDownloadLinkRecord *made = nil;
    __block BOOL done = NO;
    [world.service makeDownloadLinkForPath:file displayName:nil revisionSHA256:nil revisionSize:nil expiresDays:7
                                completion:^(SZFriendsDownloadLinkRecord *link, NSString *url, NSError *error) {
                                    (void)error;
                                    made = link;
                                    done = YES;
                                    SZFL_CHECK([url hasPrefix:@"https://friends.example/d#"], @"url %@", url);
                                }];
    SZFL_CHECK(SZFLWaitUntil(10, ^BOOL { return done; }) && made != nil, @"the link is made");
    SZFriendsDownloadLinkPayload *payload = [SZFriendsDownloadLinkPayload new];
    payload.linkID = made.linkID;
    payload.secret = made.secret;
    return payload;
}

// Opens `payload` toward `world`'s service, the way the host would hand the hello over; returns the outcome.
static SZFriendsLinkOutcome Open(SZFLSenderWorld *world, NSData *linkID, NSData *secret, id<SZFriendsLinkSink> sink,
                                 uint8_t *attempt) {
    SZFriendsLinkEnvironment *environment = SZFLEnvironment(SZFLLoopbackTransport());
    SZFriendsLinkOpening *opening = [[SZFriendsLinkOpening alloc] initWithLinkID:linkID secret:secret
                                                                     environment:environment sink:sink];
    __block NSInteger outcome = -1;
    SZFriendsLinkService *service = world.service;
    [opening startWithOpen:^(NSData *hello, void (^done)(id, BOOL)) {
        NSArray<SZFLChannel *> *pair = [SZFLChannel pair];
        // An open nobody answers stays silent, as the host's sid does.
        [service receiveOpenOfLinkID:linkID channel:pair[1] payload:hello];
        done(pair[0], YES);
    }
        completion:^(SZFriendsLinkOutcome result) { outcome = result; }];
    SZFL_CHECK(SZFLWaitUntil(10, ^BOOL { return outcome >= 0; }), @"the opening ends");
    if (attempt) *attempt = opening.attempt;
    SZFLSpin(1.5); // the connection goes a moment after the last record
    return outcome;
}

static void TestAGuestDownloadsDirectly(void) {
    SZFLSenderWorld *world = SZFLSender(@"direct");
    NSData *bytes = SZFLRandom(6 * 1024 * 1024 + 4321); // past the opener's first credit window
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(world, bytes, NULL);
    SZFLSink *sink = [SZFLSink new];
    uint8_t attempt = 0;
    SZFriendsLinkOutcome outcome = Open(world, payload.linkID, payload.secret, sink, &attempt);
    SZFL_CHECK(outcome == SZFriendsLinkOutcomeDone && attempt == 1, @"outcome %ld attempt %d", (long)outcome, attempt);
    SZFL_CHECK([sink.bytes isEqualToData:bytes] && sink.finished, @"%lu bytes", (unsigned long)sink.bytes.length);
    SZFL_CHECK([sink.metadata.name isEqualToString:@"Site photos.pdf"] && [sink.metadata.senderName isEqual:@"Mei"] &&
                   [sink.metadata.mediaType isEqualToString:@"application/pdf"],
               @"metadata %@ %@", sink.metadata.name, sink.metadata.mediaType);
    SZFL_CHECK([world.store downloadLinkWithID:payload.linkID].downloads == 1, @"one download counted");
    SZFL_CHECK(world.service.servingCount == 0, @"nothing left being served");
    SZFriendsLinkOutcome again = Open(world, payload.linkID, payload.secret, [SZFLSink new], NULL);
    SZFL_CHECK(again == SZFriendsLinkOutcomeDone && [world.store downloadLinkWithID:payload.linkID].downloads == 2,
               @"a link works as often as it is opened while it lasts");
}

static void TestNoSecretNoConnection(void) {
    SZFLSenderWorld *world = SZFLSender(@"secret");
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(world, SZFLRandom(1000), NULL);
    SZFLSink *sink = [SZFLSink new];
    SZFriendsLinkOutcome outcome = Open(world, payload.linkID, SZFLRandom(32), sink, NULL);
    SZFL_CHECK(outcome == SZFriendsLinkOutcomeUnavailable && sink.metadata == nil, @"outcome %ld", (long)outcome);
    SZFL_CHECK(world.transport.opened == 0, @"the sender made no connection for a wrong secret");
}

// A hello replayed by someone who saw it, followed by a proof made without the secret: no answer, no connection.
static void TestAWrongProofGetsNothing(void) {
    SZFLSenderWorld *world = SZFLSender(@"proof");
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(world, SZFLRandom(1000), NULL);
    SZFriendsLinkKeys *keys = [[SZFriendsLinkKeys alloc] initWithLinkID:payload.linkID secret:payload.secret];
    NSData *nonce = SZFLRandom(16);
    NSData *hello = [keys sealMessage:@{@"t" : @"hello", @"v" : @1, @"n" : SZFriendsLinkBase64URLEncode(nonce)}
                                 from:SZFriendsLinkSideOpener];
    NSArray<SZFLChannel *> *pair = [SZFLChannel pair];
    __block NSDictionary *challenge = nil;
    __block NSUInteger later = 0;
    pair[0].onPayload = ^(NSData *data) {
        if (challenge == nil) challenge = [keys openPayload:data from:SZFriendsLinkSideSender];
        else later += 1;
    };
    SZFL_CHECK([world.service receiveOpenOfLinkID:payload.linkID channel:pair[1] payload:hello], @"the hello opens");
    SZFL_CHECK(SZFLWaitUntil(5, ^BOOL { return challenge != nil; }), @"a challenge");
    [keys setOpenerNonce:nonce senderNonce:SZFriendsLinkBase64URLDecode(challenge[@"n"])];
    [pair[0] sendPayload:[keys sealMessage:@{@"t" : @"proof", @"mac" : SZFriendsLinkBase64URLEncode(SZFLRandom(32))}
                                      from:SZFriendsLinkSideOpener]];
    [pair[0] sendPayload:[keys sealMessage:@{@"t" : @"offer", @"a" : @1, @"relay" : @NO, @"sdp" : @"v=0"}
                                      from:SZFriendsLinkSideOpener]];
    SZFLSpin(1);
    SZFL_CHECK(world.transport.opened == 0 && later == 0 && world.service.servingCount == 0,
               @"opened %lu, said %lu more", (unsigned long)world.transport.opened, (unsigned long)later);
}

static void TestRevokedAndExpiredLinksAreRefused(void) {
    SZFLSenderWorld *world = SZFLSender(@"revoked");
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(world, SZFLRandom(1000), NULL);
    SZFL_CHECK([world.service revokeLinkID:payload.linkID error:NULL], @"revoked");
    SZFL_CHECK(Open(world, payload.linkID, payload.secret, [SZFLSink new], NULL) == SZFriendsLinkOutcomeUnavailable,
               @"a revoked link opens nothing");
    SZFriendsDownloadLinkPayload *later = SZFLMakeLink(world, SZFLRandom(1000), NULL);
    SZFriendsDownloadLinkRecord *record = [world.store removeDownloadLink:later.linkID error:NULL];
    record.expiresAt = [NSDate dateWithTimeIntervalSinceNow:-60];
    [world.store saveDownloadLink:record error:NULL];
    SZFL_CHECK(Open(world, later.linkID, later.secret, [SZFLSink new], NULL) == SZFriendsLinkOutcomeEnded,
               @"an expired link it still remembers says so");
    [world.service expireLinks];
    SZFL_CHECK([world.store downloadLinkWithID:later.linkID] == nil, @"and it goes at the next expiry pass");
    SZFL_CHECK(world.transport.opened == 0, @"no connection for either");
}

static void TestAChangedOriginalIsRefusedBeforeAnyByte(void) {
    SZFLSenderWorld *world = SZFLSender(@"changed");
    SZFriendsLinkClonesRefused = YES;
    NSString *path = nil;
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(world, SZFLRandom(50000), &path);
    SZFriendsLinkClonesRefused = NO;
    SZFL_CHECK([world.store downloadLinkWithID:payload.linkID].sourcePath != nil, @"no clone");
    [SZFLRandom(60000) writeToFile:path atomically:NO];
    SZFLSink *sink = [SZFLSink new];
    SZFriendsLinkOutcome outcome = Open(world, payload.linkID, payload.secret, sink, NULL);
    SZFL_CHECK(outcome == SZFriendsLinkOutcomeChanged && sink.bytes.length == 0 && sink.metadata == nil,
               @"outcome %ld", (long)outcome);
    SZFL_CHECK(world.transport.opened == 0, @"refused before any connection");
}

static void TestAnAppReceivesIntoTheSendersConversation(void) {
    SZFLSenderWorld *sender = SZFLSender(@"app-sender");
    NSData *bytes = SZFLRandom(150000);
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(sender, bytes, NULL);
    NSString *mine = SZFLTemporaryDirectory(@"app-opener");
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:mine error:NULL];
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:mine];
    SZFriendsLinkReceiver *receiver = [[SZFriendsLinkReceiver alloc] initWithStore:store transfers:transfers
                                                                       ownIdentity:SZFLNewIdentity().publicKey
                                                                            linkID:payload.linkID];
    SZFriendsLinkOutcome outcome = Open(sender, payload.linkID, payload.secret, receiver, NULL);
    SZFL_CHECK(outcome == SZFriendsLinkOutcomeDone && receiver.conversationID != nil, @"outcome %ld", (long)outcome);
    SZFriendsPersonRecord *person = [store personWithIdentityKey:sender.identity.publicKey];
    SZFL_CHECK(person.relation == SZFriendsRelationRemoved && [person.friendsID isEqualToString:@"brave-otter"] &&
                   [[store linkContactConversationIDs] containsObject:person.conversationID],
               @"the sender gets a row of their own: %@", person.friendsID);
    SZFriendsTransferRecord *transfer = [transfers transfersInConversation:person.conversationID].firstObject;
    SZFL_CHECK(transfer.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:transfer.receivedPath] isEqualToData:bytes],
               @"received through the transfer code: %@", transfer.receivedPath);
    NSArray<SZFriendsItemRecord *> *items = [store itemsInConversation:person.conversationID beforeItemID:nil limit:10
                                                            hasEarlier:NULL];
    SZFL_CHECK([items.lastObject.eventKind isEqualToString:@"received_through_link"] &&
                   [items.lastObject.eventArguments[@"file"] isEqualToString:@"Site photos.pdf"],
               @"the history says it came through a link");
    // Someone blocked here sends nothing through a link either.
    person.relation = SZFriendsRelationBlocked;
    [store savePerson:person error:NULL];
    SZFriendsLinkReceiver *again = [[SZFriendsLinkReceiver alloc] initWithStore:store transfers:transfers
                                                                    ownIdentity:SZFLNewIdentity().publicKey
                                                                         linkID:payload.linkID];
    SZFL_CHECK(Open(sender, payload.linkID, payload.secret, again, NULL) == SZFriendsLinkOutcomeFailed,
               @"refused for a blocked sender");
}

void SZFLRunExchangeTests(void) {
    TestAGuestDownloadsDirectly();
    TestNoSecretNoConnection();
    TestAWrongProofGetsNothing();
    TestRevokedAndExpiredLinksAreRefused();
    TestAChangedOriginalIsRefusedBeforeAnyByte();
}

void SZFLRunReceiveTests(void) {
    TestAnAppReceivesIntoTheSendersConversation();
}
