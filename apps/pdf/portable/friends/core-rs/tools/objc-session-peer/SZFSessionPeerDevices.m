// The Objective-C interop peer's devices, with the helper's own classes as its nearby service drives them
// (service/helper/nearby/SZFriendsNearbyService+Join.m, +Sync.m): SZFriendsJoiner and SZFriendsJoinApprover over NN
// with JOIN frames, and between own devices CHAIN first, then SZFriendsSyncExchange over SYNC frames on IK. The same
// commands and events as the Rust peer (crates/szfriends-interop/src/devices.rs).

#import "SZFSessionPeer.h"

#import "avatars/SZFriendsAvatars.h"
#import "service/discovery/SZFriendsDiscovery.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsJoin.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

// The welcome's profile part, as the helper encodes it (+Join.m).
enum { SZFWelcomeProfileFrame = 1, SZFWelcomePresenceSecret = 2, SZFWelcomeDevicesSecret = 3 };

@interface SZFPeerDevices : NSObject
@property(nonatomic) SZFriendsSyncEngine *engine;
@property(nonatomic) SZFriendsJoinApprover *approver;
@property(nonatomic, nullable) SZFriendsJoiner *joiner;
@property(nonatomic) NSMutableDictionary<NSNumber *, id> *dials; // session -> @YES (request) or the code
@property(nonatomic) NSMutableDictionary<NSNumber *, SZFriendsJoinAttempt *> *attempts;
@property(nonatomic) NSMutableDictionary<NSNumber *, SZFriendsJoinApproval *> *approvals;
@property(nonatomic) NSMutableDictionary<NSNumber *, SZFriendsSyncExchange *> *exchanges;
@end

@implementation SZFPeerDevices
@end

static SZFriendsFrame *SZFJoinFrame(NSData *message) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeJoin fields:@{@(SZFriendsFieldJoin) : message}];
}

@implementation SZFPeer (Devices)

- (SZFPeerDevices *)deviceState {
    if (self.devices != nil) return self.devices;
    SZFPeerDevices *state = [SZFPeerDevices new];
    NSString *received = [self.home stringByAppendingPathComponent:@"received"];
    state.engine = [[SZFriendsSyncEngine alloc] initWithStore:self.store identity:self.identity
                                            receivedDirectory:received];
    __weak SZFPeer *weakSelf = self;
    state.engine.onNewEvents = ^{ [weakSelf pumpExchanges]; };
    state.engine.onChange = ^(NSSet<NSString *> *conversations) {
        (void)conversations;
        [weakSelf emit:@{@"event" : @"sync_changed"}];
    };
    state.approver = [[SZFriendsJoinApprover alloc] initWithIdentity:self.identity];
    state.dials = [NSMutableDictionary dictionary];
    state.attempts = [NSMutableDictionary dictionary];
    state.approvals = [NSMutableDictionary dictionary];
    state.exchanges = [NSMutableDictionary dictionary];
    self.devices = state;
    return state;
}

- (nullable NSData *)ownRoot {
    return [self.store rootKeyForDeviceKey:self.identity.publicKey];
}

- (BOOL)isOwnDeviceKey:(NSData *)key {
    NSData *root = [self ownRoot];
    return key.length == 32 && root != nil && ![key isEqualToData:self.identity.publicKey] &&
           [[self.store rootKeyForDeviceKey:key] isEqualToData:root];
}

- (nullable SZFriendsPersonRecord *)personNamed:(id)hex {
    NSData *key = SZFBytes(hex);
    return key.length == 32 ? [self.store personWithIdentityKey:key] : nil;
}

- (void)pumpExchanges {
    for (SZFriendsSyncExchange *exchange in [self deviceState].exchanges.allValues) [exchange pump];
}

- (nullable NSDictionary *)deviceCommand:(NSDictionary *)command {
    NSString *name = command[@"cmd"];
    SZFPeerDevices *state = [self deviceState];
    SZFriendsStore *store = self.store;
    NSDate *now = [NSDate date];
    if ([name isEqualToString:@"set_profile"]) {
        store.profileName = command[@"name"];
        store.friendsID = command[@"friends_id"];
        if (store.ownPresenceSecret == nil) store.ownPresenceSecret = SZFriendsNewPresenceSecret();
        return @{};
    }
    if ([name isEqualToString:@"device_genesis"]) {
        SZFriendsDeviceChain *chain = [SZFriendsDeviceChain genesisChainWithIdentity:self.identity
                                                                                name:command[@"name"]
                                                                              system:command[@"system"]
                                                                                date:now error:NULL];
        if (![store adoptOwnDeviceChain:chain localDeviceKey:self.identity.publicKey error:NULL]) {
            return @{@"error" : @"no genesis"};
        }
        return @{@"root" : SZFHex(chain.rootKey)};
    }
    if ([name isEqualToString:@"join_start"]) {
        state.joiner = [[SZFriendsJoiner alloc] initWithIdentity:self.identity friendsID:command[@"friends_id"]
                                                            name:command[@"name"] system:command[@"system"]
                                                       requestID:nil];
        return @{@"request_id" : SZFHex(state.joiner.requestID)};
    }
    if ([name isEqualToString:@"join_send_request"] || [name isEqualToString:@"join_code"]) {
        NSDictionary *reply = [self dialWithCommand:@{@"port" : command[@"port"], @"pattern" : @"NN"}];
        state.dials[reply[@"session"]] = command[@"code"] ?: @YES;
        return reply;
    }
    if ([name isEqualToString:@"join_approve"]) {
        [store ownDeviceChainCreatingGenesisWithIdentity:self.identity error:NULL];
        NSString *code = [state.approver approveRequestID:SZFBytes(command[@"request_id"]) now:now];
        return code ? @{@"code" : code} : @{@"error" : @"no such request"};
    }
    if ([name isEqualToString:@"sync_dial"]) {
        NSData *device = SZFBytes(command[@"device_key"]), *root = [self ownRoot];
        NSData *staticKey = root ? [store staticKeyForDeviceKey:device ofRootKey:root] : nil;
        if (staticKey == nil) return @{@"error" : @"not one of our devices"};
        return [self dialWithCommand:@{@"port" : command[@"port"], @"pattern" : @"IK",
                                       @"remote_static" : SZFHex(staticKey), @"expected_identity" : SZFHex(device)}];
    }
    if ([name isEqualToString:@"add_message"]) {
        SZFriendsPersonRecord *person = [self personNamed:command[@"identity_key"]];
        if (person == nil) return @{@"error" : @"no such person"};
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.itemID = command[@"id"];
        item.conversationID = person.conversationID;
        item.kind = SZFriendsItemKindMessage;
        item.direction = [command[@"direction"] isEqual:@"out"] ? SZFriendsDirectionOutgoing
                                                                : SZFriendsDirectionIncoming;
        NSNumber *at = command[@"at"];
        item.sentAt = item.receivedAt = at ? [NSDate dateWithTimeIntervalSince1970:at.doubleValue] : now;
        item.text = command[@"text"];
        item.outboxState = -1;
        return @{@"inserted" : @([store insertItem:item error:NULL])};
    }
    if ([name isEqualToString:@"erase_history"]) {
        SZFriendsPersonRecord *person = [self personNamed:command[@"identity_key"]];
        BOOL ok = person && [state.engine deleteHistoryInConversation:person.conversationID error:NULL];
        return @{@"ok" : @(ok)};
    }
    if ([name isEqualToString:@"revoke_device"]) {
        NSData *device = SZFBytes(command[@"device_key"]);
        SZFriendsDeviceChain *revoked = [store.ownDeviceChain chainByRevokingDeviceKey:device signedBy:self.identity
                                                                                  date:now error:NULL];
        if (revoked == nil || [store mergeOwnDeviceChain:revoked error:NULL] == SZFriendsChainMergeRefused) {
            return @{@"error" : @"not revoked"};
        }
        BOOL recorded = [state.engine recordRevocationOfDeviceKey:device error:NULL];
        for (NSNumber *sessionID in state.exchanges) {
            [self.sessions[sessionID].channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                                                               fields:@{@(SZFriendsFieldChain) :
                                                                                            revoked.encodedData}]];
        }
        [self pumpExchanges];
        return @{@"recorded" : @(recorded)};
    }
    if ([name isEqualToString:@"capture"]) {
        NSUInteger count = [state.engine captureLocalChanges];
        [self pumpExchanges];
        return @{@"captured" : @(count)};
    }
    if ([name isEqualToString:@"device_state"]) return [self deviceStateReport];
    return nil;
}

- (NSDictionary *)deviceStateReport {
    SZFriendsDeviceChain *chain = self.store.ownDeviceChain;
    NSMutableArray *devices = [NSMutableArray array];
    for (SZFriendsChainDevice *device in chain.devices) {
        [devices addObject:@{@"key" : SZFHex(device.deviceKey), @"state" : @(device.state), @"name" : device.name}];
    }
    NSMutableArray *people = [NSMutableArray array];
    for (SZFriendsPersonRecord *person in self.store.peopleByLatestInteraction) {
        NSMutableArray<SZFriendsItemRecord *> *items = [[self.store itemsInConversation:person.conversationID
                                                                           beforeItemID:nil limit:1000
                                                                             hasEarlier:NULL] mutableCopy];
        [items sortUsingComparator:^NSComparisonResult(SZFriendsItemRecord *a, SZFriendsItemRecord *b) {
            NSComparisonResult order = [a.receivedAt compare:b.receivedAt];
            return order != NSOrderedSame ? order : [a.itemID compare:b.itemID];
        }];
        NSMutableArray *texts = [NSMutableArray array];
        for (SZFriendsItemRecord *item in items) {
            if (item.kind == SZFriendsItemKindMessage && item.text) [texts addObject:item.text];
        }
        [people addObject:@{@"identity_key" : person.identityKey ? SZFHex(person.identityKey) : [NSNull null],
                            @"name" : person.name ?: [NSNull null], @"relation" : @(person.relation),
                            @"messages" : texts}];
    }
    return @{@"root" : chain ? SZFHex(chain.rootKey) : [NSNull null],
             @"removed" : @([chain revokesDeviceKey:self.identity.publicKey]), @"devices" : devices,
             @"people" : people, @"profile_name" : self.store.profileName ?: [NSNull null]};
}

#pragma mark - Sessions

- (void)devicesEstablished:(SZFPeerSession *)session {
    SZFPeerDevices *state = [self deviceState];
    NSNumber *key = @(session.sessionID);
    id dial = state.dials[key];
    SZFriendsSecureChannel *channel = session.channel;
    if (dial != nil) {
        [state.dials removeObjectForKey:key];
        if ([dial isKindOfClass:[NSString class]]) {
            SZFriendsJoinAttempt *attempt = [state.joiner attemptWithCode:dial handshakeHash:channel.handshakeHash];
            if (attempt == nil) return [channel closeWithReason:SZFriendsCloseReasonNormal];
            state.attempts[key] = attempt;
            [channel sendFrame:SZFJoinFrame(attempt.codeMessage)];
        } else {
            NSData *request = [state.joiner requestMessageAtDate:[NSDate date]];
            if (request == nil) return [channel closeWithReason:SZFriendsCloseReasonNormal];
            [channel sendFrame:SZFJoinFrame(request)];
        }
        return;
    }
    if (channel.pattern != SZFriendsHandshakeIK || ![self isOwnDeviceKey:channel.remoteIdentityKey]) return;
    NSData *chain = self.store.ownDeviceChain.encodedData;
    if (chain) {
        [channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                                  fields:@{@(SZFriendsFieldChain) : chain}]];
    }
    __weak SZFriendsSecureChannel *weakChannel = channel;
    SZFriendsSyncExchange *exchange = [[SZFriendsSyncExchange alloc]
        initWithEngine:state.engine
               peerKey:channel.remoteIdentityKey
                  send:^(NSData *message) {
                      [weakChannel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeSync
                                                                    fields:@{@(SZFriendsFieldSync) : message}]];
                  }];
    state.exchanges[key] = exchange;
    [state.engine captureLocalChanges];
    [exchange start];
    [self emit:@{@"event" : @"sync_started", @"session" : key}];
}

- (void)devicesClosed:(SZFPeerSession *)session {
    SZFPeerDevices *state = [self deviceState];
    NSNumber *key = @(session.sessionID);
    [state.dials removeObjectForKey:key];
    [state.attempts removeObjectForKey:key];
    SZFriendsJoinApproval *approval = state.approvals[key];
    if (approval) [state.approver abandonApproval:approval now:[NSDate date]];
    [state.approvals removeObjectForKey:key];
    [state.exchanges[key] stop];
    [state.exchanges removeObjectForKey:key];
}

- (BOOL)devicesSession:(SZFPeerSession *)session frame:(SZFriendsFrame *)frame {
    SZFPeerDevices *state = [self deviceState];
    NSNumber *key = @(session.sessionID);
    SZFriendsSecureChannel *channel = session.channel;
    if (frame.type == SZFriendsFrameTypeJoin) {
        NSData *message = [frame dataForTag:SZFriendsFieldJoin];
        if (channel.isInitiator) [self joiningSession:session message:message];
        else [self approvingSession:session message:message];
        return YES;
    }
    SZFriendsSyncExchange *exchange = state.exchanges[key];
    if (exchange == nil) return NO;
    if (frame.type == SZFriendsFrameTypeChain) {
        NSData *root = [self ownRoot] ?: self.store.ownDeviceChain.rootKey;
        SZFriendsDeviceChain *chain = root ? [SZFriendsDeviceChain chainWithData:[frame dataForTag:SZFriendsFieldChain]
                                                                 expectedRootKey:root error:NULL]
                                           : nil;
        if (chain == nil || [self.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeRefused) {
            [channel closeWithReason:SZFriendsCloseReasonProtocolError];
            return YES;
        }
        [self checkRemovedOnSession:session];
        return YES;
    }
    if (frame.type == SZFriendsFrameTypeSync) {
        NSError *error = nil;
        BOOL ok = [exchange receiveMessage:[frame dataForTag:SZFriendsFieldSync] error:&error];
        [self checkRemovedOnSession:session];
        if (!ok) {
            BOOL left = error.code == SZFriendsSyncErrorInactive;
            [self emit:@{@"event" : @"sync_error", @"session" : key, @"error" : error.localizedDescription ?: @""}];
            [channel closeWithReason:left ? SZFriendsCloseReasonNormal : SZFriendsCloseReasonProtocolError];
        }
        return YES;
    }
    return NO;
}

- (void)checkRemovedOnSession:(SZFPeerSession *)session {
    BOOL removed = [self.store.ownDeviceChain revokesDeviceKey:self.identity.publicKey];
    if (removed) [self emit:@{@"event" : @"removed"}];
    if (removed || ![self isOwnDeviceKey:session.channel.remoteIdentityKey]) {
        [session.channel closeWithReason:SZFriendsCloseReasonNormal];
    }
}

#pragma mark - Joining

- (void)approvingSession:(SZFPeerSession *)session message:(NSData *)message {
    SZFPeerDevices *state = [self deviceState];
    SZFriendsStore *store = self.store;
    SZFriendsSecureChannel *channel = session.channel;
    NSNumber *key = @(session.sessionID);
    SZFriendsDeviceChain *chain = store.ownDeviceChain;
    NSDate *now = [NSDate date];
    SZFriendsJoinEndReason ended = 0;
    switch (SZFriendsJoinMessageKindOf(message)) {
    case SZFriendsJoinMessageRequest: {
        SZFriendsJoinReceipt receipt = [state.approver receiveRequestMessage:message ownFriendsID:store.friendsID
                                                                       chain:chain now:now endedReason:&ended];
        if (receipt == SZFriendsJoinReceiptEnded) [channel sendFrame:SZFJoinFrame(SZFriendsJoinEndedMessage(ended))];
        if (receipt == SZFriendsJoinReceiptAdded || receipt == SZFriendsJoinReceiptRefreshed) {
            for (SZFriendsJoinRequest *row in [state.approver openRequestsWithChain:chain now:now]) {
                [self emit:@{@"event" : @"join_request", @"request_id" : SZFHex(row.requestID), @"name" : row.name,
                             @"system" : row.system}];
            }
        }
        [channel closeWithReason:SZFriendsCloseReasonNormal];
        return;
    }
    case SZFriendsJoinMessageCode: {
        SZFriendsJoinApproval *approval =
            chain ? [state.approver approvalForCodeMessage:message handshakeHash:channel.handshakeHash
                                                    rootKey:chain.rootKey now:now ended:&ended]
                  : nil;
        if (approval != nil) {
            state.approvals[key] = approval;
            [channel sendFrame:SZFJoinFrame(approval.replyMessage)];
            return;
        }
        if (ended != 0) [channel sendFrame:SZFJoinFrame(SZFriendsJoinEndedMessage(ended))];
        [channel closeWithReason:SZFriendsCloseReasonNormal];
        return;
    }
    case SZFriendsJoinMessageConfirm: {
        SZFriendsJoinApproval *approval = state.approvals[key];
        [state.approvals removeObjectForKey:key];
        NSData *profile = [self welcomeProfile];
        SZFriendsJoinWelcome *welcome =
            approval && chain && profile ? [state.approver welcomeForConfirmMessage:message approval:approval
                                                                              chain:chain profile:profile
                                                                     friendsIDState:store.friendsIDState now:now]
                                         : nil;
        if (welcome == nil || [store mergeOwnDeviceChain:welcome.chain error:NULL] == SZFriendsChainMergeRefused) {
            [channel closeWithReason:SZFriendsCloseReasonNormal];
            return;
        }
        for (NSData *part in welcome.parts) [channel sendFrame:SZFJoinFrame(part)];
        [state.approver finishRequestID:approval.requestID];
        [self emit:@{@"event" : @"join_approved"}];
        return;
    }
    default:
        [channel closeWithReason:SZFriendsCloseReasonNormal];
    }
}

- (nullable NSData *)welcomeProfile {
    SZFriendsStore *store = self.store;
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    if (store.profileName) fields[@(SZFriendsFieldName)] = [store.profileName dataUsingEncoding:NSUTF8StringEncoding];
    if (store.friendsID) fields[@(SZFriendsFieldFriendsID)] = [store.friendsID dataUsingEncoding:NSUTF8StringEncoding];
    NSData *frame = SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeProfile fields:fields], NULL);
    NSData *devicesSecret = [SZFriendsSyncEngine ownDevicesSecretInStore:store creating:YES];
    if (frame == nil || store.ownPresenceSecret.length != 32 || devicesSecret == nil) return nil;
    SZFriendsSyncFields *welcome = [[SZFriendsSyncFields alloc] init];
    [welcome setData:frame forTag:SZFWelcomeProfileFrame];
    [welcome setData:store.ownPresenceSecret forTag:SZFWelcomePresenceSecret];
    [welcome setData:devicesSecret forTag:SZFWelcomeDevicesSecret];
    return welcome.encodedData;
}

- (void)joiningSession:(SZFPeerSession *)session message:(NSData *)message {
    SZFPeerDevices *state = [self deviceState];
    NSNumber *key = @(session.sessionID);
    SZFriendsSecureChannel *channel = session.channel;
    SZFriendsJoinAttempt *attempt = state.attempts[key];
    if (attempt == nil) {
        SZFriendsJoinEndReason reason = SZFriendsJoinEndReasonOf(message);
        if (reason != 0) [self emit:@{@"event" : @"join_ended", @"reason" : @(reason)}];
        [channel closeWithReason:SZFriendsCloseReasonNormal];
        return;
    }
    SZFriendsJoinStep *step = [attempt receiveMessage:message];
    if (step.kind == SZFriendsJoinStepSend) {
        [channel sendFrame:SZFJoinFrame(step.message)];
        return;
    }
    if (step.kind == SZFriendsJoinStepWait) return;
    [state.attempts removeObjectForKey:key];
    if (step.kind == SZFriendsJoinStepJoined) {
        BOOL joined = [self completeJoinWithStep:step];
        [self emit:@{@"event" : joined ? @"joined" : @"join_failed", @"root" : SZFHex(step.chain.rootKey)}];
    } else {
        [self emit:@{@"event" : @"join_failed", @"step" : @(step.kind)}];
    }
    [channel closeWithReason:SZFriendsCloseReasonNormal];
}

- (BOOL)completeJoinWithStep:(SZFriendsJoinStep *)step {
    SZFPeerDevices *state = [self deviceState];
    SZFriendsStore *store = self.store;
    SZFriendsSyncFields *welcome = [SZFriendsSyncFields fieldsWithData:step.profile];
    NSData *frameData = [welcome dataForTag:SZFWelcomeProfileFrame];
    SZFriendsFrame *frame = frameData ? SZFriendsDecodeFrame(frameData, NULL) : nil;
    NSData *presence = [welcome dataForTag:SZFWelcomePresenceSecret];
    NSData *devicesSecret = [welcome dataForTag:SZFWelcomeDevicesSecret];
    NSString *friendsID = frame.type == SZFriendsFrameTypeProfile ? [frame stringForTag:SZFriendsFieldFriendsID] : nil;
    BOOL sameID = friendsID != nil && [friendsID isEqualToString:state.joiner.friendsID];
    if (!sameID || presence.length != 32 || devicesSecret.length != 32 ||
        ![store adoptOwnDeviceChain:step.chain localDeviceKey:self.identity.publicKey error:NULL]) {
        return NO;
    }
    store.profileName = [frame stringForTag:SZFriendsFieldName];
    store.friendsID = friendsID;
    store.friendsIDState = step.friendsIDState;
    store.ownPresenceSecret = presence;
    [SZFriendsSyncEngine adoptOwnDevicesSecret:devicesSecret inStore:store];
    state.joiner = nil;
    return YES;
}

@end
