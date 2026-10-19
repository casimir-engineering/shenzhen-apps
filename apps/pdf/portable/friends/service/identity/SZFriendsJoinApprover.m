// The side of joining on the person's computers (SZFriendsJoin.h): requests become rows, at most three at once and six
// new ones an hour; Approve draws a code that lives 5 minutes and three attempts; a confirmed run signs the add link.
// Nothing is ever approved without the person's press, and nothing here is written anywhere. At three rows the newest
// request takes the place of the waiting row repeated least recently, without counting as a new row, so requests
// nobody wants cannot keep the person's own computer out; a row the person denied, or that another computer added
// meanwhile, gives its hour's slot back.

#import "service/identity/SZFriendsJoinInternal.h"

#import "service/identity/SZFriendsCPace.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"

static NSString *Hex(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

@interface SZFriendsJoinApproval ()
@property(nonatomic, readwrite, copy) NSData *requestID;
@property(nonatomic, readwrite, copy) NSData *replyMessage;
@property(nonatomic, copy, nullable) NSData *isk; // nil once used, right or wrong
@property(nonatomic, copy) NSData *rootKey;
@end

@implementation SZFriendsJoinApproval
@end

@implementation SZFriendsJoinWelcome
- (instancetype)initWithChain:(SZFriendsDeviceChain *)chain parts:(NSArray<NSData *> *)parts {
    self = [super init];
    if (self == nil) return nil;
    _chain = chain;
    _parts = [parts copy];
    return self;
}
@end

// Why a request no longer shows, kept as long as a request lives so its device hears the reason when it asks again.
@interface SZFriendsJoinEnding : NSObject
@property(nonatomic) SZFriendsJoinEndReason reason;
@property(nonatomic, copy) NSDate *until;
@end

@implementation SZFriendsJoinEnding
@end

@implementation SZFriendsJoinApprover {
    SZFriendsIdentity *_device;
    NSMutableDictionary<NSString *, SZFriendsJoinRequest *> *_requests;  // by request id
    NSMutableDictionary<NSString *, SZFriendsJoinEnding *> *_endings;    // by request id
    NSMutableDictionary<NSString *, NSDate *> *_deniedDevices;           // device key -> until
    NSMutableArray<NSDate *> *_newRows;                                  // when each row of the last hour came
    NSMutableDictionary<NSString *, NSDate *> *_slots;                   // request id -> its entry in _newRows
}

- (instancetype)initWithIdentity:(SZFriendsIdentity *)device {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    [self forgetEverything];
    return self;
}

- (void)forgetEverything {
    _requests = [NSMutableDictionary dictionary];
    _endings = [NSMutableDictionary dictionary];
    _deniedDevices = [NSMutableDictionary dictionary];
    _newRows = [NSMutableArray array];
    _slots = [NSMutableDictionary dictionary];
}

// A row the person dealt with (Deny) or that is not waiting for anyone any more (another computer added the device)
// does not count against the hour's new rows.
- (void)freeSlotOfRequest:(NSString *)key {
    NSDate *slot = _slots[key];
    [_slots removeObjectForKey:key];
    NSUInteger index = slot ? [_newRows indexOfObjectIdenticalTo:slot] : NSNotFound;
    if (index != NSNotFound) [_newRows removeObjectAtIndex:index];
}

- (void)end:(SZFriendsJoinRequest *)request reason:(SZFriendsJoinEndReason)reason now:(NSDate *)now {
    NSString *key = Hex(request.requestID);
    [_requests removeObjectForKey:key];
    SZFriendsJoinEnding *ending = [SZFriendsJoinEnding new];
    ending.reason = reason;
    ending.until = [now dateByAddingTimeInterval:SZFriendsJoinRequestLifetime];
    _endings[key] = ending;
}

// Waiting rows nobody repeated for a while, and codes past their 5 minutes, go; so do old endings and budgets.
- (void)pruneAtDate:(NSDate *)now {
    for (SZFriendsJoinRequest *request in _requests.allValues) {
        if (request.state == SZFriendsJoinRequestApproved) {
            if ([request.codeExpiresAt compare:now] != NSOrderedDescending) {
                [self end:request reason:SZFriendsJoinEndExpired now:now];
            }
        } else if ([now timeIntervalSinceDate:request.lastHeardAt] >= SZFriendsJoinRequestLifetime) {
            [_requests removeObjectForKey:Hex(request.requestID)];
        }
    }
    for (NSString *key in _endings.allKeys) {
        if ([_endings[key].until compare:now] != NSOrderedDescending) [_endings removeObjectForKey:key];
    }
    for (NSString *key in _deniedDevices.allKeys) {
        if ([_deniedDevices[key] compare:now] != NSOrderedDescending) [_deniedDevices removeObjectForKey:key];
    }
    NSIndexSet *old = [_newRows indexesOfObjectsPassingTest:^BOOL(NSDate *when, NSUInteger i, BOOL *stop) {
        (void)i;
        (void)stop;
        return [now timeIntervalSinceDate:when] >= 3600 || [when timeIntervalSinceDate:now] > 0;
    }];
    [_newRows removeObjectsAtIndexes:old];
}

- (SZFriendsJoinReceipt)receiveRequestMessage:(NSData *)message
                                 ownFriendsID:(NSString *)ownFriendsID
                                        chain:(SZFriendsDeviceChain *)chain
                                          now:(NSDate *)now
                                  endedReason:(SZFriendsJoinEndReason *)endedReason {
    if (endedReason) *endedReason = 0;
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsJoinVerifiedRequest(message);
    if (fields == nil || ownFriendsID.length == 0) return SZFriendsJoinReceiptIgnored;
    SZFriendsJoinRequest *incoming = [[SZFriendsJoinRequest alloc] initWithFields:fields receivedAt:now];
    if (![incoming.friendsID isEqualToString:ownFriendsID] ||
        fabs([incoming.sentAt timeIntervalSinceDate:now]) > SZFriendsJoinClockSkewMax) {
        return SZFriendsJoinReceiptIgnored;
    }
    // Our own key, a device the profile already holds, and a device it ever removed (never added again, ADR 0012).
    NSData *deviceKey = incoming.deviceKey;
    if ([deviceKey isEqualToData:_device.publicKey] || [chain authorizesDeviceKey:deviceKey] ||
        [chain revokesDeviceKey:deviceKey]) {
        return SZFriendsJoinReceiptIgnored;
    }
    [self pruneAtDate:now];
    NSString *key = Hex(incoming.requestID);
    SZFriendsJoinEndReason ended = _endings[key].reason;
    if (ended == 0 && _deniedDevices[Hex(deviceKey)] != nil) ended = SZFriendsJoinEndDenied;
    if (ended != 0) {
        if (endedReason) *endedReason = ended;
        return SZFriendsJoinReceiptEnded;
    }
    SZFriendsJoinRequest *known = _requests[key];
    if (known != nil) {
        // A copy refreshes the row; the same id with other keys is someone else's forgery and changes nothing.
        if (![known.deviceKey isEqualToData:deviceKey] || ![known.staticKey isEqualToData:incoming.staticKey]) {
            return SZFriendsJoinReceiptIgnored;
        }
        known.lastHeardAt = now;
        return SZFriendsJoinReceiptRefreshed;
    }
    for (SZFriendsJoinRequest *other in _requests.allValues) {
        if (![other.deviceKey isEqualToData:deviceKey]) continue;
        // The device started over: its new request takes its waiting row's place; an approval in progress stays.
        if (other.state == SZFriendsJoinRequestApproved) return SZFriendsJoinReceiptIgnored;
        [_requests removeObjectForKey:Hex(other.requestID)];
        _requests[key] = incoming;
        if (_slots[Hex(other.requestID)] != nil) _slots[key] = _slots[Hex(other.requestID)];
        [_slots removeObjectForKey:Hex(other.requestID)];
        return SZFriendsJoinReceiptAdded;
    }
    if (_requests.count >= SZFriendsJoinOpenRequestsMax) {
        // The newest shows: it takes the place of the row still waiting that was repeated least recently (an approval
        // stays), so a request its computer keeps repeating outlasts ones sent once. Taking a place adds no row, so it
        // spends nothing of the hour's new rows: requests nobody wants cannot use them up before the person's own.
        SZFriendsJoinRequest *stalest = nil;
        for (SZFriendsJoinRequest *other in _requests.allValues) {
            if (other.state != SZFriendsJoinRequestWaiting) continue;
            NSComparisonResult order = stalest ? [other.lastHeardAt compare:stalest.lastHeardAt] : NSOrderedAscending;
            if (order == NSOrderedAscending ||
                (order == NSOrderedSame && [other.receivedAt compare:stalest.receivedAt] == NSOrderedAscending)) {
                stalest = other;
            }
        }
        if (stalest == nil) return SZFriendsJoinReceiptLimited;
        [_requests removeObjectForKey:Hex(stalest.requestID)];
        NSDate *slot = _slots[Hex(stalest.requestID)];
        [_slots removeObjectForKey:Hex(stalest.requestID)];
        if (slot != nil) _slots[key] = slot; // the row's hour slot goes with its place
        _requests[key] = incoming;
        return SZFriendsJoinReceiptAdded;
    }
    if (_newRows.count >= SZFriendsJoinNewRequestsPerHour) return SZFriendsJoinReceiptLimited;
    _requests[key] = incoming;
    NSDate *slot = [now copy];
    [_newRows addObject:slot];
    _slots[key] = slot;
    return SZFriendsJoinReceiptAdded;
}

- (NSArray<SZFriendsJoinRequest *> *)openRequestsWithChain:(SZFriendsDeviceChain *)chain now:(NSDate *)now {
    [self pruneAtDate:now];
    // Another of the person's devices approved it and the chain carrying the new device reached us: nothing waits.
    for (SZFriendsJoinRequest *request in _requests.allValues) {
        if (![chain authorizesDeviceKey:request.deviceKey]) continue;
        [_requests removeObjectForKey:Hex(request.requestID)];
        [self freeSlotOfRequest:Hex(request.requestID)];
    }
    return [_requests.allValues sortedArrayUsingComparator:^NSComparisonResult(SZFriendsJoinRequest *a,
                                                                               SZFriendsJoinRequest *b) {
        NSComparisonResult order = [a.receivedAt compare:b.receivedAt];
        return order != NSOrderedSame ? order : [Hex(a.requestID) compare:Hex(b.requestID)];
    }];
}

- (NSDate *)nextChangeAfter:(NSDate *)now {
    NSDate *next = nil;
    for (SZFriendsJoinRequest *request in _requests.allValues) {
        NSDate *when = request.state == SZFriendsJoinRequestApproved
                           ? request.codeExpiresAt
                           : [request.lastHeardAt dateByAddingTimeInterval:SZFriendsJoinRequestLifetime];
        if ([when compare:now] == NSOrderedDescending && (next == nil || [when compare:next] == NSOrderedAscending)) {
            next = when;
        }
    }
    return next;
}

- (NSString *)approveRequestID:(NSData *)requestID now:(NSDate *)now {
    [self pruneAtDate:now];
    SZFriendsJoinRequest *request = requestID ? _requests[Hex(requestID)] : nil;
    // A second press (a double click, or two views) keeps the code already shown: a new one would void it.
    if (request.state == SZFriendsJoinRequestApproved) return request.code;
    if (request.state != SZFriendsJoinRequestWaiting) return nil;
    request.state = SZFriendsJoinRequestApproved;
    request.code = SZFriendsJoinNewCode();
    request.codeExpiresAt = [now dateByAddingTimeInterval:SZFriendsJoinCodeLifetime];
    request.attempts = 0;
    return request.code;
}

- (BOOL)denyRequestID:(NSData *)requestID now:(NSDate *)now {
    [self pruneAtDate:now];
    SZFriendsJoinRequest *request = requestID ? _requests[Hex(requestID)] : nil;
    if (request == nil) return NO;
    _deniedDevices[Hex(request.deviceKey)] = [now dateByAddingTimeInterval:SZFriendsJoinRequestLifetime];
    [self freeSlotOfRequest:Hex(request.requestID)];
    [self end:request reason:SZFriendsJoinEndDenied now:now];
    return YES;
}

- (SZFriendsJoinApproval *)approvalForCodeMessage:(NSData *)message
                                    handshakeHash:(NSData *)handshakeHash
                                          rootKey:(NSData *)rootKey
                                              now:(NSDate *)now
                                            ended:(SZFriendsJoinEndReason *)ended {
    *ended = 0;
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsJoinDecode(message, SZFriendsJoinMessageCode);
    if (fields == nil || handshakeHash.length != 64 || rootKey.length != 32) return nil;
    [self pruneAtDate:now];
    NSString *key = Hex(fields[@(SZFriendsJoinTagRequestID)]);
    *ended = _endings[key].reason;
    SZFriendsJoinRequest *request = _requests[key];
    if (*ended != 0 || request.state != SZFriendsJoinRequestApproved) return nil;
    if (request.attempts >= SZFriendsJoinAttemptsMax) {
        [self end:request reason:SZFriendsJoinEndTooManyAttempts now:now];
        *ended = SZFriendsJoinEndTooManyAttempts;
        return nil;
    }
    // Counted before anything is computed: whoever sends a Code gets one guess, whatever follows.
    request.attempts += 1;
    NSData *ci = SZFriendsJoinChannelIdentifier(request.requestID, request.deviceKey, request.staticKey);
    NSData *password = [request.code dataUsingEncoding:NSUTF8StringEncoding];
    SZFriendsCPace *cpace = [[SZFriendsCPace alloc] initWithPassword:password channelIdentifier:ci
                                                           sessionID:handshakeHash scalar:nil];
    NSData *isk = [cpace iskAsResponderWithAD:SZFriendsJoinApproverAD(_device.publicKey, rootKey)
                                    peerShare:fields[@(SZFriendsJoinTagShare)]
                                       peerAD:request.deviceKey];
    NSData *reply = isk ? SZFriendsJoinEncode(SZFriendsJoinMessageReply, @{
        @(SZFriendsJoinTagShare) : cpace.share,
        @(SZFriendsJoinTagApproverKey) : _device.publicKey,
        @(SZFriendsJoinTagRootKey) : rootKey,
        @(SZFriendsJoinTagTag) : SZFriendsJoinTag(isk, SZFriendsJoinResponderTagDomain, nil),
    })
                        : nil;
    if (reply == nil) {
        [self failedAttemptOf:request now:now];
        return nil;
    }
    SZFriendsJoinApproval *approval = [SZFriendsJoinApproval new];
    approval.requestID = request.requestID;
    approval.replyMessage = reply;
    approval.isk = isk;
    approval.rootKey = rootKey;
    return approval;
}

// The third failure ends the approval at once, so the row disappears rather than waiting for a fourth try.
- (void)failedAttemptOf:(SZFriendsJoinRequest *)request now:(NSDate *)now {
    if (request.attempts >= SZFriendsJoinAttemptsMax) {
        [self end:request reason:SZFriendsJoinEndTooManyAttempts now:now];
    }
}

- (SZFriendsJoinWelcome *)welcomeForConfirmMessage:(NSData *)message
                                          approval:(SZFriendsJoinApproval *)approval
                                             chain:(SZFriendsDeviceChain *)chain
                                           profile:(NSData *)profile
                                    friendsIDState:(NSInteger)friendsIDState
                                               now:(NSDate *)now {
    NSData *isk = approval.isk;
    approval.isk = nil; // one Confirm per run
    [self pruneAtDate:now];
    SZFriendsJoinRequest *request = _requests[Hex(approval.requestID)];
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsJoinDecode(message, SZFriendsJoinMessageConfirm);
    if (isk == nil || request.state != SZFriendsJoinRequestApproved) return nil;
    NSData *consent = fields[@(SZFriendsJoinTagConsent)];
    NSData *expected = consent ? SZFriendsJoinTag(isk, SZFriendsJoinInitiatorTagDomain, consent) : nil;
    if (!SZFriendsJoinTagsEqual(expected, fields[@(SZFriendsJoinTagTag)]) ||
        ![chain.rootKey isEqualToData:approval.rootKey] ||
        !SZFriendsVerifyDeviceConsent(consent, request.deviceKey, request.staticKey, approval.rootKey)) {
        [self failedAttemptOf:request now:now];
        return nil;
    }
    SZFriendsDeviceChain *added = [chain chainByAddingDeviceKey:request.deviceKey
                                                      staticKey:request.staticKey
                                                        consent:consent
                                                           name:request.name
                                                         system:request.system
                                                       signedBy:_device
                                                           date:now
                                                          error:NULL];
    NSArray<NSData *> *parts = added ? [self partsOfWelcomeWithChain:added profile:profile state:friendsIDState isk:isk]
                                     : nil;
    return parts ? [[SZFriendsJoinWelcome alloc] initWithChain:added parts:parts] : nil;
}

- (NSArray<NSData *> *)partsOfWelcomeWithChain:(SZFriendsDeviceChain *)chain
                                       profile:(NSData *)profile
                                         state:(NSInteger)state
                                           isk:(NSData *)isk {
    NSMutableDictionary<NSNumber *, NSData *> *fields = [@{
        @(SZFriendsJoinTagChain) : chain.encodedData,
        @(SZFriendsJoinTagProfile) : profile,
        @(SZFriendsJoinTagIDState) : SZFriendsJoinUInt8((uint8_t)MAX(0, MIN(255, state))),
        @(SZFriendsJoinTagTag) : [NSMutableData dataWithLength:32],
    } mutableCopy];
    NSData *body = SZFriendsJoinEncode(SZFriendsJoinMessageWelcome, fields);
    if (body == nil) return nil;
    fields[@(SZFriendsJoinTagTag)] = SZFriendsJoinTag(isk, SZFriendsJoinWelcomeTagDomain, body);
    NSData *whole = SZFriendsJoinEncode(SZFriendsJoinMessageWelcome, fields);
    NSUInteger count = (whole.length + SZFriendsJoinPartMax - 1) / SZFriendsJoinPartMax;
    if (whole == nil || count == 0 || count > 255) return nil;
    NSMutableArray<NSData *> *parts = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger start = i * SZFriendsJoinPartMax;
        NSRange range = NSMakeRange(start, MIN(SZFriendsJoinPartMax, whole.length - start));
        NSData *part = SZFriendsJoinEncode(SZFriendsJoinMessagePart, @{
            @(SZFriendsJoinTagPartIndex) : SZFriendsJoinUInt8((uint8_t)i),
            @(SZFriendsJoinTagPartCount) : SZFriendsJoinUInt8((uint8_t)count),
            @(SZFriendsJoinTagPartData) : [whole subdataWithRange:range],
        });
        if (part == nil) return nil;
        [parts addObject:part];
    }
    return parts;
}

- (void)abandonApproval:(SZFriendsJoinApproval *)approval now:(NSDate *)now {
    if (approval.isk == nil) return; // its Confirm was judged already
    approval.isk = nil;
    SZFriendsJoinRequest *request = _requests[Hex(approval.requestID)];
    if (request != nil) [self failedAttemptOf:request now:now];
}

- (void)finishRequestID:(NSData *)requestID {
    if (requestID != nil) [_requests removeObjectForKey:Hex(requestID)];
}

@end
