// The new computer's side of joining (SZFriendsJoin.h): its signed request, and one CPace run per session once the
// person typed the code, ending with a chain that holds this computer, from the device that showed the code.

#import "service/identity/SZFriendsJoinInternal.h"

#import <sodium.h>

#import "service/identity/SZFriendsCPace.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"

typedef NS_ENUM(NSInteger, SZFriendsJoinAttemptPhase) {
    SZFriendsJoinAttemptSentCode = 0, // waiting for Reply
    SZFriendsJoinAttemptConfirmed = 1, // waiting for the welcome's Parts
    SZFriendsJoinAttemptOver = 2,
};

@implementation SZFriendsJoinAttempt {
    SZFriendsIdentity *_device;
    SZFriendsCPace *_cpace;
    SZFriendsJoinAttemptPhase _phase;
    NSData *_isk;
    NSData *_rootKey;
    NSData *_approverKey;
    NSMutableDictionary<NSNumber *, NSData *> *_parts;
    NSUInteger _partCount;
}

- (instancetype)initWithDevice:(SZFriendsIdentity *)device
                     requestID:(NSData *)requestID
                          code:(NSString *)code
                 handshakeHash:(NSData *)handshakeHash {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    NSData *ci = SZFriendsJoinChannelIdentifier(requestID, device.publicKey, device.staticPublicKey);
    _cpace = [[SZFriendsCPace alloc] initWithPassword:[code dataUsingEncoding:NSUTF8StringEncoding]
                                    channelIdentifier:ci
                                            sessionID:handshakeHash
                                               scalar:nil];
    _codeMessage = SZFriendsJoinEncode(SZFriendsJoinMessageCode, @{
        @(SZFriendsJoinTagRequestID) : requestID,
        @(SZFriendsJoinTagShare) : _cpace.share ?: [NSData data],
    });
    _parts = [NSMutableDictionary dictionary];
    return _cpace != nil && _codeMessage != nil ? self : nil;
}

- (SZFriendsJoinStep *)over:(SZFriendsJoinStepKind)kind {
    _phase = SZFriendsJoinAttemptOver;
    _isk = nil;
    return [SZFriendsJoinStep stepWithKind:kind];
}

- (SZFriendsJoinStep *)receiveMessage:(NSData *)message {
    if (_phase == SZFriendsJoinAttemptOver) return [SZFriendsJoinStep stepWithKind:SZFriendsJoinStepFailed];
    SZFriendsJoinMessageKind kind = SZFriendsJoinMessageKindOf(message);
    if (kind == SZFriendsJoinMessageEnded) {
        _phase = SZFriendsJoinAttemptOver;
        return [SZFriendsJoinStep endedStep:SZFriendsJoinEndReasonOf(message)];
    }
    if (_phase == SZFriendsJoinAttemptSentCode && kind == SZFriendsJoinMessageReply) return [self receiveReply:message];
    if (_phase == SZFriendsJoinAttemptConfirmed && kind == SZFriendsJoinMessagePart) return [self receivePart:message];
    return [self over:SZFriendsJoinStepFailed];
}

- (SZFriendsJoinStep *)receiveReply:(NSData *)message {
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsJoinDecode(message, SZFriendsJoinMessageReply);
    if (fields == nil) return [self over:SZFriendsJoinStepFailed];
    NSData *approverKey = fields[@(SZFriendsJoinTagApproverKey)], *rootKey = fields[@(SZFriendsJoinTagRootKey)];
    if ([approverKey isEqualToData:_device.publicKey] || [rootKey isEqualToData:_device.publicKey]) {
        return [self over:SZFriendsJoinStepFailed];
    }
    // The root key is bound into ISK through ADb, so a Reply naming another root cannot carry a valid tag.
    NSData *isk = [_cpace iskAsInitiatorWithAD:_device.publicKey
                                     peerShare:fields[@(SZFriendsJoinTagShare)]
                                        peerAD:SZFriendsJoinApproverAD(approverKey, rootKey)];
    NSData *expected = isk ? SZFriendsJoinTag(isk, SZFriendsJoinResponderTagDomain, nil) : nil;
    if (!SZFriendsJoinTagsEqual(expected, fields[@(SZFriendsJoinTagTag)])) {
        return [self over:SZFriendsJoinStepWrongCode];
    }
    _isk = isk;
    _rootKey = rootKey;
    _approverKey = approverKey;
    // Only now, from the device that proved it knows the code, does this computer agree to join that root.
    NSData *consent = SZFriendsDeviceConsent(_device, rootKey);
    NSData *confirm = SZFriendsJoinEncode(SZFriendsJoinMessageConfirm, @{
        @(SZFriendsJoinTagConsent) : consent,
        @(SZFriendsJoinTagTag) : SZFriendsJoinTag(isk, SZFriendsJoinInitiatorTagDomain, consent),
    });
    if (confirm == nil) return [self over:SZFriendsJoinStepFailed];
    _phase = SZFriendsJoinAttemptConfirmed;
    return [SZFriendsJoinStep sendStep:confirm];
}

- (SZFriendsJoinStep *)receivePart:(NSData *)message {
    NSDictionary<NSNumber *, NSData *> *fields = SZFriendsJoinDecode(message, SZFriendsJoinMessagePart);
    uint8_t index = fields ? ((const uint8_t *)fields[@(SZFriendsJoinTagPartIndex)].bytes)[0] : 0;
    uint8_t count = fields ? ((const uint8_t *)fields[@(SZFriendsJoinTagPartCount)].bytes)[0] : 0;
    // Parts arrive in order on one session; anything else is not the welcome this run expects.
    if (fields == nil || (_partCount != 0 && count != _partCount) || index != _parts.count || index >= count) {
        return [self over:SZFriendsJoinStepFailed];
    }
    _partCount = count;
    _parts[@(index)] = fields[@(SZFriendsJoinTagPartData)];
    if (_parts.count < _partCount) return [SZFriendsJoinStep stepWithKind:SZFriendsJoinStepWait];
    NSMutableData *whole = [NSMutableData data];
    for (NSUInteger i = 0; i < _partCount; i++) [whole appendData:_parts[@(i)]];
    return [self receiveWelcome:whole];
}

- (SZFriendsJoinStep *)receiveWelcome:(NSData *)whole {
    NSMutableDictionary<NSNumber *, NSData *> *fields = [SZFriendsJoinDecode(whole, SZFriendsJoinMessageWelcome)
        mutableCopy];
    NSData *tag = fields[@(SZFriendsJoinTagTag)];
    if (tag == nil) return [self over:SZFriendsJoinStepFailed];
    // The tag covers the welcome as encoded with every other field, with a placeholder where the tag goes.
    fields[@(SZFriendsJoinTagTag)] = [NSMutableData dataWithLength:32];
    NSData *body = SZFriendsJoinEncode(SZFriendsJoinMessageWelcome, fields);
    if (!SZFriendsJoinTagsEqual(SZFriendsJoinTag(_isk, SZFriendsJoinWelcomeTagDomain, body), tag)) {
        return [self over:SZFriendsJoinStepFailed];
    }
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:fields[@(SZFriendsJoinTagChain)]
                                                      expectedRootKey:_rootKey
                                                                error:NULL];
    SZFriendsChainDevice *me = [chain deviceWithKey:_device.publicKey];
    BOOL holdsUs = me.state == SZFriendsChainDeviceAuthorized && [me.staticKey isEqualToData:_device.staticPublicKey];
    if (!holdsUs || ![chain authorizesDeviceKey:_approverKey]) return [self over:SZFriendsJoinStepFailed];
    _phase = SZFriendsJoinAttemptOver;
    _isk = nil;
    NSInteger state = ((const uint8_t *)fields[@(SZFriendsJoinTagIDState)].bytes)[0];
    return [SZFriendsJoinStep joinedStepWithChain:chain profile:fields[@(SZFriendsJoinTagProfile)] state:state];
}

@end

@implementation SZFriendsJoiner {
    SZFriendsIdentity *_device;
    NSString *_name;
    NSString *_system;
}

- (instancetype)initWithIdentity:(SZFriendsIdentity *)device
                       friendsID:(NSString *)friendsID
                            name:(NSString *)name
                          system:(NSString *)system
                       requestID:(NSData *)requestID {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _friendsID = [friendsID copy];
    _name = [name copy];
    _system = [system copy];
    if (requestID.length == 16) {
        _requestID = [requestID copy];
    } else {
        NSMutableData *fresh = [NSMutableData dataWithLength:16];
        randombytes_buf(fresh.mutableBytes, fresh.length);
        _requestID = fresh;
    }
    return self;
}

- (NSData *)requestMessageAtDate:(NSDate *)now {
    return SZFriendsJoinRequestMessage(_device, _requestID, _friendsID, _name, _system, now);
}

- (SZFriendsJoinAttempt *)attemptWithCode:(NSString *)code handshakeHash:(NSData *)handshakeHash {
    NSString *digits = SZFriendsJoinNormalizedCode(code);
    if (digits == nil || handshakeHash.length != 64) return nil;
    return [[SZFriendsJoinAttempt alloc] initWithDevice:_device requestID:_requestID code:digits
                                          handshakeHash:handshakeHash];
}

@end
