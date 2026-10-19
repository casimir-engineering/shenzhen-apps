// friends-helper-check: host attestations on Add by ID answers (ADR 0004, Review amendments, 9). The security re-check
// found that anyone who heard the broadcast passed as the ID's holder: each extra answering row took the ID the
// requester typed, and three throwaway keys used up every answer slot. Links here carry fake channels; the host list
// is signed in memory with a throwaway host key, and nothing is dialed.

#import "SZFriendsHelperNearbyTests.h"

#import <sodium.h>

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/SZFriendsHostCheckIn.h"

static NSString *SZFNAttB64(NSData *data) {
    NSString *text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

// A UTC day as hosts date attestations, `daysAgo` before now.
static NSString *SZFNAttDay(NSInteger daysAgo) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * (double)daysAgo]];
}

// The throwaway host "main-hk": its signing key, and a loopback list naming it that the helper's services verify.
@interface SZFNAttHost : NSObject
@property(nonatomic) NSData *secretKey;
@property(nonatomic) NSDictionary<NSString *, NSString *> *environment; // the two SZFRIENDS_TEST_HOST_* variables
@end

@implementation SZFNAttHost
@end

static SZFNAttHost *SZFNMakeAttHost(NSString *scratch) {
    unsigned char adminPublic[32], adminSecret[64], hostPublic[32], hostSecret[64];
    crypto_sign_keypair(adminPublic, adminSecret);
    crypto_sign_keypair(hostPublic, hostSecret);
    NSDictionary *payload = @{
        @"version" : @3, @"issued_at" : @"2026-10-12T00:00:00Z", @"new_id_words" : @2,
        @"hosts" : @[ @{@"id" : @"main-hk", @"role" : @"rendezvous", @"urls" : @[ @"ws://127.0.0.1:9/v1" ],
                        @"turn_uris" : @[], @"region" : @"Test", @"priority" : @1,
                        @"public_key" : SZFNAttB64([NSData dataWithBytes:hostPublic length:32])} ]
    };
    NSData *payloadBytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableData *signedBytes = [[@"SZFriends host list v1\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:payloadBytes];
    unsigned char signature[64];
    crypto_sign_detached(signature, NULL, signedBytes.bytes, signedBytes.length, adminSecret);
    NSDictionary *envelope = @{@"payload" : SZFNAttB64(payloadBytes),
                               @"sigs" : @[ @{@"key" : @"primary",
                                              @"sig" : SZFNAttB64([NSData dataWithBytes:signature length:64])} ]};
    NSString *adminKey = SZFNAttB64([NSData dataWithBytes:adminPublic length:32]);
    NSDictionary *pinned = @{@"keys" : @[ @{@"name" : @"primary", @"test" : @YES, @"public_key" : adminKey} ]};
    NSString *listPath = [scratch stringByAppendingPathComponent:@"attest-list.json"];
    NSString *keysPath = [scratch stringByAppendingPathComponent:@"attest-keys.json"];
    [[NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL] writeToFile:listPath atomically:YES];
    [[NSJSONSerialization dataWithJSONObject:pinned options:0 error:NULL] writeToFile:keysPath atomically:YES];
    SZFNAttHost *host = [[SZFNAttHost alloc] init];
    host.secretKey = [NSData dataWithBytes:hostSecret length:64];
    host.environment = @{@"SZFRIENDS_TEST_HOST_LIST" : listPath, @"SZFRIENDS_TEST_HOST_KEYS" : keysPath};
    return host;
}

// The wire form a host signs (HOST-PROTOCOL.md § ID attestations): Ed25519 over the domain and the u32be
// length-prefixed host id, Friends ID, identity key and day.
static NSData *SZFNAttest(SZFNAttHost *host, NSString *hostID, NSString *friendsID, NSData *key, NSString *day) {
    NSMutableData *message = [[@"SZFriends id attestation v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    for (id field in @[ hostID, friendsID, key, day ]) {
        NSData *bytes = [field isKindOfClass:[NSString class]] ? [field dataUsingEncoding:NSUTF8StringEncoding] : field;
        uint32_t length = CFSwapInt32HostToBig((uint32_t)bytes.length);
        [message appendBytes:&length length:sizeof length];
        [message appendData:bytes];
    }
    unsigned char signature[64];
    crypto_sign_detached(signature, NULL, message.bytes, message.length, host.secretKey.bytes);
    NSDictionary *wire = @{@"host_id" : hostID, @"friends_id" : friendsID, @"identity_key" : SZFNAttB64(key),
                           @"day" : day, @"sig" : SZFNAttB64([NSData dataWithBytes:signature length:64])};
    return [NSJSONSerialization dataWithJSONObject:wire options:0 error:NULL];
}

static SZFriendsHelperServices *SZFNOpenAttServices(NSString *scratch, NSString *name, SZFNAttHost *host) {
    NSString *state = [scratch stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSMutableDictionary *env = [@{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"file"} mutableCopy];
    [env addEntriesFromDictionary:host.environment];
    SZFriendsHelperServices *services = [[SZFriendsHelperServices alloc]
        initWithPaths:[[SZFriendsStatePaths alloc] initWithStateDirectory:state]
          environment:env
            resources:[SZFriendsHelperResources loadFromBundle:[NSBundle mainBundle]]];
    [services open];
    EXPECT(services.store != nil && services.hostListCache.currentList.entries.count == 1, "services with a list");
    return services.store != nil && services.hostListCache != nil ? services : nil;
}

// An IK callback's channel as a listener sees it once live: who answered, with which token and attestation.
@interface SZFNAnsweringChannel : SZFNFakeChannel
@property(nonatomic, copy) NSData *answerKey;
@property(nonatomic, copy) NSData *answerStaticKey;
@property(nonatomic, copy) NSData *presentedRequestToken;
@end

@implementation SZFNAnsweringChannel
- (NSData *)remoteIdentityKey {
    return _answerKey;
}
- (NSData *)remoteStaticKey {
    return _answerStaticKey;
}
@end

static SZFriendsPeerLink *SZFNAnswer(NSData *key, NSData *token, NSData *_Nullable attestation) {
    SZFNAnsweringChannel *channel = [[SZFNAnsweringChannel alloc] init];
    channel.pattern = SZFriendsHandshakeIK;
    channel.answerKey = key;
    channel.answerStaticKey = SZFNBytes(32);
    channel.presentedRequestToken = token;
    channel.remoteAttestation = attestation;
    return SZFNLink(channel);
}

// The pure judgement: only the attested holder is believed, someone else's attestation is refused, and everything
// honest that proves nothing about the ID asked for (stale, renamed, a host our list lacks) is an ordinary answer.
void SZFNTestAnswerAttestationVerdicts(NSString *scratch) {
    SZFNAttHost *host = SZFNMakeAttHost(scratch);
    SZFriendsHelperServices *services = SZFNOpenAttServices(scratch, @"verdicts", host);
    if (services == nil) return;
    SZFriendsHostList *list = services.hostListCache.currentList;
    NSData *holder = SZFNBytes(32), *other = SZFNBytes(32);
    NSDate *now = [NSDate date];
    NSData *good = SZFNAttest(host, @"main-hk", @"orchid-summit", holder, SZFNAttDay(0));
    SZFriendsHostAttestation *parsed = nil;
    EXPECT(SZFriendsJudgeAnswerAttestation(good, list, @"orchid-summit", holder, now, &parsed) ==
               SZFriendsAnswerAttested && [parsed.friendsID isEqual:@"orchid-summit"],
           "the holder's own, for the ID asked");
    EXPECT(SZFriendsJudgeAnswerAttestation(nil, list, @"orchid-summit", holder, now, &parsed) ==
               SZFriendsAnswerUnattested && parsed == nil,
           "none");
    EXPECT(SZFriendsJudgeAnswerAttestation(good, list, @"orchid-summit", other, now, &parsed) ==
               SZFriendsAnswerRefused && parsed == nil,
           "the holder's attestation shown by another key is refused");
    NSMutableDictionary *tampered = [[NSJSONSerialization JSONObjectWithData:good options:0 error:NULL] mutableCopy];
    tampered[@"identity_key"] = SZFNAttB64(other);
    NSData *rekeyed = [NSJSONSerialization dataWithJSONObject:tampered options:0 error:NULL];
    EXPECT(SZFriendsJudgeAnswerAttestation(rekeyed, list, @"orchid-summit", other, now, NULL) ==
               SZFriendsAnswerUnattested,
           "one rewritten to name the answering key does not verify, so it proves nothing");
    NSData *renamed = SZFNAttest(host, @"main-hk", @"maple-harbor", holder, SZFNAttDay(0));
    EXPECT(SZFriendsJudgeAnswerAttestation(renamed, list, @"orchid-summit", holder, now, NULL) ==
               SZFriendsAnswerUnattested,
           "this key's own for another ID: a holder renamed since; honest, but not the ID asked");
    NSData *stale = SZFNAttest(host, @"main-hk", @"orchid-summit", holder, SZFNAttDay(40));
    EXPECT(SZFriendsJudgeAnswerAttestation(stale, list, @"orchid-summit", holder, now, NULL) ==
               SZFriendsAnswerUnattested,
           "40 days old");
    NSData *elsewhere = SZFNAttest(host, @"replica-sg", @"orchid-summit", holder, SZFNAttDay(0));
    EXPECT(SZFriendsJudgeAnswerAttestation(elsewhere, list, @"orchid-summit", holder, now, NULL) ==
               SZFriendsAnswerUnattested,
           "a host our list does not name");
    EXPECT(SZFriendsJudgeAnswerAttestation(SZFNBytes(300), list, @"orchid-summit", holder, now, NULL) ==
               SZFriendsAnswerUnattested,
           "unreadable");
    EXPECT(SZFriendsJudgeAnswerAttestation(good, nil, @"orchid-summit", holder, now, NULL) == SZFriendsAnswerUnattested,
           "nothing to check it against");
    [services close];
}

// A test's check-in glue that holds one attestation and gives it, as the client does, only for the ID it names.
@interface SZFNAttCheckIn : SZFriendsHelperCheckIn
@property(nonatomic, nullable) SZFriendsHostAttestation *held;
@end

@implementation SZFNAttCheckIn
- (SZFriendsHostAttestation *)attestationForFriendsID:(NSString *)friendsID {
    return [self.held.friendsID isEqualToString:friendsID] ? self.held : nil;
}
@end

// A stream the channel is built on but never started.
@interface SZFNIdleStream : NSObject <SZFriendsByteStream>
@end

@implementation SZFNIdleStream
@synthesize onData = _onData, onClose = _onClose;
- (NSUInteger)preferredWriteSize {
    return 4096;
}
- (void)startWithQueue:(dispatch_queue_t)queue {
    (void)queue;
}
- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    (void)data;
    if (completion) completion(nil);
}
- (void)close {
}
@end

static SZFriendsDialPlan *SZFNCallbackPlan(NSData *_Nullable token, NSString *_Nullable conversationID) {
    SZFriendsSighting *sighting = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                                      route:SZFriendsRouteMethodLAN
                                                                 endpointID:@"requester"
                                                                presenceTag:SZFNBytes(SZFriendsPresenceTagLength)
                                                               callbackTags:@[]
                                                                   isPublic:NO
                                                                     seenAt:[NSDate date]];
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = SZFriendsHandshakeIK;
    options.route = SZFriendsRouteMethodLAN;
    options.remoteStaticKey = SZFNBytes(32);
    options.expectedIdentityKey = SZFNBytes(32);
    options.requestToken = token;
    SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting purpose:SZFriendsLinkPurposeFriend
                                                          options:options];
    plan.conversationID = conversationID;
    return plan;
}

// Holder: our IK callback after accepting an Add by ID carries our attestation for the ID we hold, and nothing else
// we dial does; after a rename the old ID's attestation is not shown.
void SZFNTestCallbackShowsAttestation(NSString *scratch) {
    SZFNAttHost *host = SZFNMakeAttHost(scratch);
    SZFriendsHelperServices *services = SZFNOpenAttServices(scratch, @"holder", host);
    if (services == nil) return;
    NSString *ours = services.store.friendsID;
    SZFNAttCheckIn *checkIn = [[SZFNAttCheckIn alloc] initWithServices:services setup:services.checkInSetup
                                                                 cache:services.hostListCache
                                                                 queue:dispatch_get_main_queue()];
    NSData *wire = SZFNAttest(host, @"main-hk", ours, services.identity.publicKey, SZFNAttDay(0));
    checkIn.held = [SZFriendsHostAttestation attestationFromData:wire];
    services.checkIn = checkIn;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    // The requester we accepted (a friend now, the callback carries our ACCEPT) and one we declined.
    NSString *accepted = SZFNSavePerson(services.store, SZFriendsRelationFriend).conversationID;
    NSString *declined = SZFNSavePerson(services.store, SZFriendsRelationRemoved).conversationID;
    SZFriendsPeerLink *callback = [nearby linkForInitiatorStream:[[SZFNIdleStream alloc] init]
                                                            plan:SZFNCallbackPlan(SZFNBytes(16), accepted)];
    EXPECT(checkIn.held != nil && [callback.channel.localAttestation isEqualToData:checkIn.held.encodedData],
           "the callback carrying our ACCEPT shows our attestation: %@", callback.channel.localAttestation);
    // Wave-4 re-check: a decline's callback handed the person we turned down our ID, our host and our last check-in.
    SZFriendsPeerLink *decline = [nearby linkForInitiatorStream:[[SZFNIdleStream alloc] init]
                                                           plan:SZFNCallbackPlan(SZFNBytes(16), declined)];
    EXPECT(decline.channel.localAttestation == nil, "the callback carrying our DECLINE shows nothing");
    SZFriendsPeerLink *friendDial = [nearby linkForInitiatorStream:[[SZFNIdleStream alloc] init]
                                                              plan:SZFNCallbackPlan(nil, accepted)];
    EXPECT(friendDial.channel.localAttestation == nil, "a friend's IK carries none");
    services.store.friendsID = @"maple-harbor";
    callback = [nearby linkForInitiatorStream:[[SZFNIdleStream alloc] init]
                                         plan:SZFNCallbackPlan(SZFNBytes(16), accepted)];
    EXPECT(callback.channel.localAttestation == nil, "renamed: the old ID's attestation is not ours to show");
    services.checkIn = nil;
    [services close];
}

// Requester: the policy and the callback's conversation, with the slots of one request and the facts the views get.
void SZFNTestAttestedAnswers(NSString *scratch) {
    SZFNAttHost *host = SZFNMakeAttHost(scratch);
    SZFriendsHelperServices *services = SZFNOpenAttServices(scratch, @"requester", host);
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.targetFriendsID = @"orchid-summit";
    request.requestToken = SZFNBytes(16);
    request.callbackSecret = SZFNBytes(32);
    request.createdAt = [NSDate date];
    request.expiresAt = [request.createdAt dateByAddingTimeInterval:86400];
    NSString *asked = [store startIDRequest:request error:NULL];
    EXPECT(asked != nil, "the Request sent row");
    NSData *token = request.requestToken, *holder = SZFNBytes(32);
    NSData *holderAttestation = SZFNAttest(host, @"main-hk", @"orchid-summit", holder, SZFNAttDay(1));

    // Someone showing the holder's attestation, while every slot is still free.
    SZFriendsPeerLink *copier = SZFNAnswer(SZFNBytes(32), token, holderAttestation);
    EXPECT(![nearby allowRemoteKey:copier.channel.remoteIdentityKey pattern:SZFriendsHandshakeIK token:token
                              link:copier publicEntry:NO],
           "a key showing the holder's attestation is refused before any reply");
    EXPECT([nearby conversationForCallbackLink:copier] == nil &&
               [store personWithIdentityKey:copier.channel.remoteIdentityKey] == nil &&
               [store idRequestWithToken:token].answeringKeyCount == 0,
           "and, live or not, it gets no row and no slot");

    // Two answers without an attestation: each its own row, and neither takes the ID we typed.
    NSMutableArray<NSString *> *strangers = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        SZFriendsPeerLink *answer = SZFNAnswer(SZFNBytes(32), token, nil);
        NSData *key = answer.channel.remoteIdentityKey;
        EXPECT([nearby allowRemoteKey:key pattern:SZFriendsHandshakeIK token:token link:answer publicEntry:NO]);
        NSString *conversation = [nearby conversationForCallbackLink:answer];
        SZFriendsPersonRecord *row = conversation ? [store personWithConversationID:conversation] : nil;
        EXPECT(row != nil && row.friendsID == nil && !row.friendsIDConfirmed,
               "answer %d: no Friends ID from our own typing (%@)", i + 1, row.friendsID);
        if (conversation) [strangers addObject:conversation];
    }
    EXPECT(strangers.count == 2 && ![strangers[0] isEqual:strangers[1]], "two people, never merged");
    SZFriendsPeerLink *third = SZFNAnswer(SZFNBytes(32), token, nil);
    EXPECT(![nearby allowRemoteKey:third.channel.remoteIdentityKey pattern:SZFriendsHandshakeIK token:token
                              link:third publicEntry:NO],
           "a third unattested key is refused: the last slot is the holder's");
    SZFriendsPersonRecord *removed = SZFNSavePerson(store, SZFriendsRelationRemoved);
    removed.friendsID = @"orchid-summit"; // they told us so once: only the slots stand in their way
    EXPECT([store savePerson:removed error:NULL]);
    EXPECT(![nearby allowRemoteKey:removed.identityKey pattern:SZFriendsHandshakeIK token:token
                              link:SZFNAnswer(removed.identityKey, token, nil) publicEntry:NO],
           "so is a removed person answering without one");
    // A removed person who told us another ID gets in only with the host's word for this one.
    SZFriendsPersonRecord *renamed = SZFNSavePerson(store, SZFriendsRelationRemoved);
    renamed.friendsID = @"tulip-canyon";
    EXPECT([store savePerson:renamed error:NULL]);
    NSData *renamedAttestation = SZFNAttest(host, @"main-hk", @"orchid-summit", renamed.identityKey, SZFNAttDay(0));
    EXPECT([nearby allowRemoteKey:renamed.identityKey pattern:SZFriendsHandshakeIK token:token
                             link:SZFNAnswer(renamed.identityKey, token, renamedAttestation) publicEntry:NO],
           "attested: the store takes their row back as our request");

    // The holder: let in for the last slot, its own row, its ID confirmed.
    SZFriendsPeerLink *holderLink = SZFNAnswer(holder, token, holderAttestation);
    EXPECT([nearby allowRemoteKey:holder pattern:SZFriendsHandshakeIK token:token link:holderLink publicEntry:NO],
           "the attested holder gets the slot kept for it");
    NSString *holderRow = [nearby conversationForCallbackLink:holderLink];
    SZFriendsPersonRecord *confirmed = holderRow ? [store personWithConversationID:holderRow] : nil;
    EXPECT(confirmed.friendsIDConfirmed && [confirmed.friendsID isEqual:@"orchid-summit"] &&
               [confirmed.friendsIDAttestationDay isEqual:SZFNAttDay(1)],
           "confirmed: %d %@ %@", confirmed.friendsIDConfirmed, confirmed.friendsID, confirmed.friendsIDAttestationDay);
    EXPECT(holderRow && ![strangers containsObject:holderRow], "apart from the unattested answers");
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:services now:[NSDate date]];
    EXPECT([pass personWithConversationID:holderRow].friendsIDConfirmed, "the views are told it is confirmed");
    EXPECT(![pass personWithConversationID:strangers.firstObject].friendsIDConfirmed, "and the others are not");

    // A known key calling back keeps the ID it told us: an unattested repeat clears nothing.
    SZFriendsPersonRecord *first = [store personWithConversationID:strangers.firstObject];
    first.friendsID = @"tulip-canyon";
    EXPECT([store savePerson:first error:NULL]);
    SZFriendsPeerLink *again = SZFNAnswer(first.identityKey, token, nil);
    EXPECT([[nearby conversationForCallbackLink:again] isEqual:strangers.firstObject] &&
               [[store personWithConversationID:strangers.firstObject].friendsID isEqual:@"tulip-canyon"],
           "the same key again gets its row, as it was");
    [services close];
}

// Reset Friends forgets the old identity's attestation even when no check-in client released it.
void SZFNTestResetForgetsAttestation(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"reset-attestation");
    if (services == nil) return;
    NSString *file = [services.paths.stateDirectory stringByAppendingPathComponent:@"host-attestation.json"];
    EXPECT([[@"{}" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
    EXPECT(services.checkIn == nil && [services resetFriendsWithError:NULL], "reset without a check-in client");
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:file], "the old attestation is gone");
    [services close];
}
