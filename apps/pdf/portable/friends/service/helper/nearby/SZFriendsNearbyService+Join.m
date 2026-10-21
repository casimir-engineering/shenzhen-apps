// Joining a profile in the helper (SZFriendsNearbyJoin.h): the intents' work, what the views show, and the messages
// both paths hand over (nearby: +JoinNearby, online: +JoinOnline).
//
// Nothing here approves anything by itself: a request becomes a row, and only approve_join draws a code. The new
// computer learns which profile it joined only from the device that proved it knows that code (SZFriendsJoin.h).

#import "service/helper/nearby/SZFriendsNearbyJoin.h"

#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/SZFriendsHelperTesting.h"

#import <objc/runtime.h>

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

const uint8_t SZFriendsJoinOpenPrefix = 'J';
const uint8_t SZFriendsJoinOpenRequest = 1;
const uint8_t SZFriendsJoinOpenCode = 2;
const NSTimeInterval SZFriendsJoinCodeWindow = 10;
const NSTimeInterval SZFriendsJoinOnlineRepeat = 1200;

static const void *kJoinStateKey = &kJoinStateKey;

// The welcome's profile part (-welcomeProfile): tag-length-value fields as sync's bodies encode them.
enum {
    SZFriendsJoinWelcomeProfileFrame = 1,
    SZFriendsJoinWelcomePresenceSecret = 2,
    SZFriendsJoinWelcomeDevicesSecret = 3,
};

@implementation SZFriendsJoinState

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    NSPointerFunctionsOptions identity = NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory;
    _attempts = [NSMapTable mapTableWithKeyOptions:identity valueOptions:NSPointerFunctionsStrongMemory];
    _approvals = [NSMapTable mapTableWithKeyOptions:identity valueOptions:NSPointerFunctionsStrongMemory];
    return self;
}

@end

@implementation SZFriendsNearbyService (Join)

- (SZFriendsJoinState *)joinState {
    SZFriendsJoinState *state = objc_getAssociatedObject(self, kJoinStateKey);
    if (state == nil) {
        state = [SZFriendsJoinState new];
        objc_setAssociatedObject(self, kJoinStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (nullable SZFriendsJoinApprover *)joinApprover {
    SZFriendsJoinState *state = self.joinState;
    if (state.approver == nil && self.services.identity != nil) {
        state.approver = [[SZFriendsJoinApprover alloc] initWithIdentity:self.services.identity];
    }
    return state.approver;
}

#pragma mark - What the views show

// Joining is offered to a computer whose Friends has nobody in it yet and holds no profile shared with another one.
- (BOOL)joinAvailable {
    SZFriendsStore *store = self.services.store;
    if (store == nil || self.services.identity == nil || store.peopleByLatestInteraction.count > 0) return NO;
    return store.ownDeviceChain.devices.count <= 1;
}

- (SZFriendsJoiningFacts *)joiningFacts {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoiningFacts *facts = [SZFriendsJoiningFacts new];
    facts.state = state.phase;
    facts.friendsID = state.joiner.friendsID ?: (state.phase != SZFriendsJoiningIdle ? self.services.store.friendsID
                                                                                     : nil);
    if (state.phase == SZFriendsJoiningIdle && ![self joinAvailable]) facts.state = SZFriendsJoiningUnavailable;
    // What carries the join now: a session with another of our computers once joined (the sync), else a nearby
    // session running the code; the best of them in the owner's order.
    BOOL joined = state.phase == SZFriendsJoiningJoined;
    SZFriendsRouteMethod route = SZFriendsRouteMethodNone;
    for (SZFriendsPeerLink *link in self.links) {
        BOOL carries = joined ? link.syncExchange != nil : link.purpose == SZFriendsLinkPurposeJoin;
        if (!carries || !link.live || link.closed || link.superseded) continue;
        if (route == SZFriendsRouteMethodNone || SZFriendsRouteIsBetter(link.raceRoute, route)) route = link.raceRoute;
    }
    facts.routeMethod = route;
    return facts;
}

- (NSArray<SZFriendsJoinRequestFacts *> *)joinRequestFacts {
    SZFriendsJoinApprover *approver = self.joinState.approver; // none made just to say there is nothing
    SZFriendsStore *store = self.services.store;
    if (approver == nil || store == nil) return @[];
    NSDate *now = [NSDate date];
    NSMutableArray<SZFriendsJoinRequestFacts *> *facts = [NSMutableArray array];
    for (SZFriendsJoinRequest *request in [approver openRequestsWithChain:store.ownDeviceChain now:now]) {
        SZFriendsJoinRequestFacts *row = [SZFriendsJoinRequestFacts new];
        row.joinID = SZFriendsLinkHex(request.requestID);
        row.deviceName = request.name;
        row.system = request.system;
        row.receivedAt = request.receivedAt;
        row.approved = request.state == SZFriendsJoinRequestApproved;
        row.code = request.code;
        row.codeExpiresAt = request.codeExpiresAt;
        [facts addObject:row];
    }
    [self scheduleJoinRefreshAt:[approver nextChangeAfter:now]];
    return facts;
}

// Rows change with no message when a code or a request expires: the snapshots are built again then.
- (void)scheduleJoinRefreshAt:(nullable NSDate *)when {
    static const void *key = &key;
    NSNumber *scheduled = objc_getAssociatedObject(self, key);
    if (when == nil || (scheduled != nil && scheduled.doubleValue <= when.timeIntervalSince1970)) return;
    objc_setAssociatedObject(self, key, @(when.timeIntervalSince1970), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak SZFriendsNearbyService *weakSelf = self;
    NSTimeInterval wait = MAX(0.05, when.timeIntervalSinceNow + 0.05);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        objc_setAssociatedObject(strongSelf, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [strongSelf changed];
    });
}

#pragma mark - Intents

- (NSString *)startJoiningFriendsID:(NSString *)friendsID {
    NSString *normalized = [self.services.codec normalizedID:friendsID];
    if (normalized == nil) return @"id_invalid";
    if ([normalized isEqualToString:self.services.store.friendsID]) return @"id_is_yours";
    if (![self joinAvailable]) return @"not_allowed";
    SZFriendsJoinState *state = self.joinState;
    [self endJoinLegs];
    state.joiner = [[SZFriendsJoiner alloc] initWithIdentity:self.services.identity friendsID:normalized
                                                        name:SZFriendsHelperDeviceName()
                                                      system:SZFriendsHelperDeviceSystem()
                                                   requestID:nil];
    state.phase = SZFriendsJoiningWaiting;
    state.code = nil;
    state.generation += 1;
    state.requestSentOnlineAt = nil;
    [self offerJoinOnline];
    [self scheduleReconsider];
    [self changed];
    return nil;
}

- (NSString *)tryJoinCode:(NSString *)code {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoiningState phase = state.phase;
    if (state.joiner == nil || (phase != SZFriendsJoiningWaiting && phase != SZFriendsJoiningWrongCode &&
                                phase != SZFriendsJoiningNotReached)) {
        return @"not_allowed";
    }
    NSString *digits = SZFriendsJoinNormalizedCode(code);
    if (digits == nil) return @"invalid_field";
    [self endJoinLegs];
    state.code = digits;
    state.phase = SZFriendsJoiningChecking;
    NSUInteger generation = ++state.generation;
    [self sendJoinCodeOnline];
    [self scheduleReconsider];
    // Nobody answered within the window: no device holding an approval was reachable.
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsJoinCodeWindow * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsJoinState *current = strongSelf.joinState;
        if (current.generation != generation || current.phase != SZFriendsJoiningChecking) return;
        current.phase = SZFriendsJoiningNotReached;
        [strongSelf endJoinLegs];
        [strongSelf changed];
    });
    [self changed];
    return nil;
}

- (void)cancelJoining {
    SZFriendsJoinState *state = self.joinState;
    [self endJoinLegs];
    state.joiner = nil;
    state.code = nil;
    state.generation += 1;
    if (state.phase != SZFriendsJoiningJoined) state.phase = SZFriendsJoiningIdle;
    [self changed];
}

- (NSString *)approveJoinID:(NSString *)joinID {
    NSData *requestID = SZFriendsLinkBytesFromHex(joinID);
    SZFriendsStore *store = self.services.store;
    // The code's run needs the root key, so an existing profile gets its genesis now if it has none yet (ADR 0012).
    SZFriendsIdentity *identity = self.services.identity;
    if (requestID == nil || [store ownDeviceChainCreatingGenesisWithIdentity:identity error:NULL] == nil) {
        return @"not_found";
    }
    if ([self.joinApprover approveRequestID:requestID now:[NSDate date]] == nil) return @"not_found";
    SZFriendsHelperLog(@"a join request was approved here; its code shows for 5 minutes");
    [self changed];
    return nil;
}

- (NSString *)denyJoinID:(NSString *)joinID {
    NSData *requestID = SZFriendsLinkBytesFromHex(joinID);
    if (requestID == nil || ![self.joinApprover denyRequestID:requestID now:[NSDate date]]) return @"not_found";
    [self changed];
    return nil;
}

- (void)forgetJoins {
    SZFriendsJoinState *state = self.joinState;
    [self endJoinLegs];
    [state.approver forgetEverything];
    state.approver = nil;
    state.joiner = nil;
    state.code = nil;
    state.phase = SZFriendsJoiningIdle;
    state.generation += 1;
    [state.approvals removeAllObjects];
}

// The new computer's sessions carrying a code end: a new request or code starts afresh.
- (void)endJoinLegs {
    SZFriendsJoinState *state = self.joinState;
    for (id pipe in state.attempts.keyEnumerator.allObjects) [pipe finish];
    [state.attempts removeAllObjects];
}

#pragma mark - Messages, from either path

- (void)pipe:(id<SZFriendsJoinPipe>)pipe receivedJoinMessage:(NSData *)message initiator:(BOOL)initiator {
    if (self.shutDown || self.resetting || self.services.store == nil || self.services.identity == nil) return;
    if (initiator) [self joiningPipe:pipe receivedMessage:message];
    else [self approvingPipe:pipe receivedMessage:message];
}

- (void)approvingPipe:(id<SZFriendsJoinPipe>)pipe receivedMessage:(NSData *)message {
    SZFriendsStore *store = self.services.store;
    SZFriendsJoinApprover *approver = self.joinApprover;
    SZFriendsDeviceChain *chain = store.ownDeviceChain;
    NSDate *now = [NSDate date];
    SZFriendsJoinEndReason ended = 0;
    switch (SZFriendsJoinMessageKindOf(message)) {
    case SZFriendsJoinMessageRequest: {
        SZFriendsJoinReceipt receipt = [approver receiveRequestMessage:message ownFriendsID:store.friendsID
                                                                 chain:chain now:now endedReason:&ended];
        // The same answer from every device, unless this one ended that very request: only its sender knows its id.
        if (receipt == SZFriendsJoinReceiptEnded) [pipe sendJoinMessages:@[ SZFriendsJoinEndedMessage(ended) ]];
        else [pipe sendReceived];
        [pipe finish];
        if (receipt == SZFriendsJoinReceiptAdded || receipt == SZFriendsJoinReceiptRefreshed) [self changed];
        return;
    }
    case SZFriendsJoinMessageCode: {
        SZFriendsJoinApproval *approval =
            chain ? [approver approvalForCodeMessage:message handshakeHash:pipe.handshakeHash rootKey:chain.rootKey
                                                 now:now ended:&ended]
                  : nil;
        if (approval != nil) {
            [self.joinState.approvals setObject:approval forKey:pipe];
            [pipe sendJoinMessages:@[ approval.replyMessage ]];
        } else {
            if (ended != 0) [pipe sendJoinMessages:@[ SZFriendsJoinEndedMessage(ended) ]];
            else [pipe sendReceived];
            [pipe finish];
        }
        [self changed];
        return;
    }
    case SZFriendsJoinMessageConfirm:
        [self approvingPipe:pipe confirmedWith:message chain:chain now:now];
        return;
    default:
        [pipe finish];
        return;
    }
}

- (void)approvingPipe:(id<SZFriendsJoinPipe>)pipe
        confirmedWith:(NSData *)message
                chain:(SZFriendsDeviceChain *)chain
                  now:(NSDate *)now {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoinApproval *approval = [state.approvals objectForKey:pipe];
    [state.approvals removeObjectForKey:pipe];
    NSData *profile = [self welcomeProfile];
    SZFriendsJoinWelcome *welcome =
        approval && chain && profile ? [self.joinApprover welcomeForConfirmMessage:message approval:approval
                                                                             chain:chain profile:profile
                                                                    friendsIDState:self.services.store.friendsIDState
                                                                               now:now]
                                     : nil;
    NSError *error = nil;
    if (welcome != nil &&
        [self.services.store mergeOwnDeviceChain:welcome.chain error:&error] != SZFriendsChainMergeRefused) {
        // Stored first: a welcome never goes out for a device this profile does not hold.
        [pipe sendJoinMessages:welcome.parts];
        [self.joinApprover finishRequestID:approval.requestID];
        SZFriendsHelperLog(@"a new computer joined this profile");
    } else if (welcome != nil) {
        SZFriendsHelperLog(@"could not store the chain for a joining computer: %ld", (long)error.code);
    }
    [pipe finish];
    [self changed];
}

// What the new computer receives besides the chain (opaque to SZFriendsJoin.h): the PROFILE our friends receive, the
// presence secret friends find us by and the secret our own devices find each other by, so it reaches friends and
// syncs with us at once, nearby or online, without waiting to meet one of us nearby first.
- (nullable NSData *)welcomeProfile {
    SZFriendsStore *store = self.services.store;
    NSData *frame = SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile
                                                                fields:[self profileFields]], NULL);
    if (store.ownPresenceSecret == nil) store.ownPresenceSecret = SZFriendsNewPresenceSecret();
    NSData *devicesSecret = [SZFriendsSyncEngine ownDevicesSecretInStore:store creating:YES];
    if (frame == nil || store.ownPresenceSecret.length != 32 || devicesSecret == nil) return nil;
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setData:frame forTag:SZFriendsJoinWelcomeProfileFrame];
    [fields setData:store.ownPresenceSecret forTag:SZFriendsJoinWelcomePresenceSecret];
    [fields setData:devicesSecret forTag:SZFriendsJoinWelcomeDevicesSecret];
    return fields.encodedData;
}

- (void)joiningPipe:(id<SZFriendsJoinPipe>)pipe receivedMessage:(NSData *)message {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoinAttempt *attempt = [state.attempts objectForKey:pipe];
    if (attempt == nil) {
        // A request's session: the only answer that says anything is that this very request ended.
        SZFriendsJoinEndReason reason = SZFriendsJoinEndReasonOf(message);
        if (reason != 0 && state.joiner != nil && state.phase != SZFriendsJoiningChecking) [self joinEnded:reason];
        [pipe finish];
        return;
    }
    SZFriendsJoinStep *step = [attempt receiveMessage:message];
    switch (step.kind) {
    case SZFriendsJoinStepSend:
        [pipe sendJoinMessages:@[ step.message ]];
        return;
    case SZFriendsJoinStepWait:
        return;
    case SZFriendsJoinStepJoined:
        [state.attempts removeObjectForKey:pipe];
        [pipe finish];
        [self completeJoinWithStep:step];
        return;
    case SZFriendsJoinStepWrongCode:
        [state.attempts removeObjectForKey:pipe];
        [pipe finish];
        if (state.phase == SZFriendsJoiningChecking) {
            state.phase = SZFriendsJoiningWrongCode;
            [self changed];
        }
        return;
    case SZFriendsJoinStepEnded:
        [state.attempts removeObjectForKey:pipe];
        [pipe finish];
        [self joinEnded:step.reason];
        return;
    case SZFriendsJoinStepFailed:
        [state.attempts removeObjectForKey:pipe];
        [pipe finish];
        return;
    }
}

- (void)joinEnded:(SZFriendsJoinEndReason)reason {
    SZFriendsJoinState *state = self.joinState;
    state.phase = reason == SZFriendsJoinEndDenied    ? SZFriendsJoiningDenied
                  : reason == SZFriendsJoinEndExpired ? SZFriendsJoiningExpired
                                                      : SZFriendsJoiningTooManyAttempts;
    state.generation += 1;
    [self endJoinLegs];
    [self changed];
}

- (void)completeJoinWithStep:(SZFriendsJoinStep *)step {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsStore *store = self.services.store;
    SZFriendsSyncFields *welcome = [SZFriendsSyncFields fieldsWithData:step.profile];
    NSData *frameData = [welcome dataForTag:SZFriendsJoinWelcomeProfileFrame];
    SZFriendsFrame *frame = frameData ? SZFriendsDecodeFrame(frameData, NULL) : nil;
    NSData *presence = [welcome dataForTag:SZFriendsJoinWelcomePresenceSecret];
    NSData *devicesSecret = [welcome dataForTag:SZFriendsJoinWelcomeDevicesSecret];
    SZFriendsPersonRecord *profile = [[SZFriendsPersonRecord alloc] init];
    if (frame.type == SZFriendsFrameTypeProfile) [self updatePerson:profile withProfile:frame.fields];
    // The profile must be the one whose ID the person typed: a device answering for another ID joins nothing.
    BOOL sameID = profile.friendsID != nil && [profile.friendsID isEqualToString:state.joiner.friendsID];
    NSError *error = nil;
    if (!sameID || presence.length != 32 || devicesSecret.length != 32 ||
        ![store adoptOwnDeviceChain:step.chain localDeviceKey:self.services.identity.publicKey error:&error]) {
        SZFriendsHelperLog(@"could not take the profile after joining: %@ %ld", sameID ? @"store" : @"another ID",
                           (long)error.code);
        state.phase = SZFriendsJoiningNotReached;
        [self changed];
        return;
    }
    // The profile's name, ID and picture, checked as any PROFILE is, then made this computer's own; and the secrets
    // our friends and our devices find this computer by from now on.
    store.profileName = profile.name;
    store.friendsID = profile.friendsID;
    store.profilePicture = profile.picture;
    store.friendsIDState = step.friendsIDState;
    store.ownPresenceSecret = presence;
    [SZFriendsSyncEngine adoptOwnDevicesSecret:devicesSecret inStore:store];
    // Checked in from now on for the person, after this computer's own ID from before is released (owed until a
    // host confirms it, across launches).
    [store setSyncState:@YES forKey:SZFriendsCheckInPreJoinReleaseKey error:NULL];
    [self.services.checkIn restartAfterJoining];
    state.phase = SZFriendsJoiningJoined;
    state.generation += 1;
    state.joiner = nil;
    state.code = nil;
    [self endJoinLegs];
    SZFriendsHelperLog(@"this computer joined a profile");
    [self profileChanged];
    [self changed];
}

- (void)beginCodeLegOnPipe:(id<SZFriendsJoinPipe>)pipe {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoinAttempt *attempt = state.phase == SZFriendsJoiningChecking && state.code != nil
                                        ? [state.joiner attemptWithCode:state.code handshakeHash:pipe.handshakeHash]
                                        : nil;
    if (attempt == nil) {
        [pipe finish];
        return;
    }
    [state.attempts setObject:attempt forKey:pipe];
    [pipe sendJoinMessages:@[ attempt.codeMessage ]];
}

- (void)pipeEnded:(id<SZFriendsJoinPipe>)pipe {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoinApproval *approval = [state.approvals objectForKey:pipe];
    if (approval != nil) {
        // The new computer went away without confirming: that code was wrong there, or it gave up.
        [state.approvals removeObjectForKey:pipe];
        [self.joinApprover abandonApproval:approval now:[NSDate date]];
        [self changed];
    }
    [state.attempts removeObjectForKey:pipe];
}

@end
