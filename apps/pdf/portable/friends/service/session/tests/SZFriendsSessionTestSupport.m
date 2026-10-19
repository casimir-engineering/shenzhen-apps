// Checks, hex, bounded waits and channel pairs for the session suite (SZFriendsSessionTestSupport.h).

#import "SZFriendsSessionTestSupport.h"

#import <sodium.h>

#import "service/session/SZFriendsSecureChannelInternal.h"

int SZFTestFailures = 0;

void SZFTestFail(const char *file, int line, const char *expression, NSString *detail) {
    SZFTestFailures++;
    const char *name = strrchr(file, '/') ? strrchr(file, '/') + 1 : file;
    fprintf(stderr, "FAIL %s:%d: %s %s\n", name, line, expression, detail.UTF8String);
}

NSData *SZFHex(NSString *hex) {
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    const char *chars = hex.UTF8String;
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        char pair[3] = {chars[i], chars[i + 1], 0};
        uint8_t byte = (uint8_t)strtoul(pair, NULL, 16);
        [data appendBytes:&byte length:1];
    }
    return data;
}

NSString *SZFHexString(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

NSData *SZFBytes(uint8_t value, NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    memset(data.mutableBytes, value, count);
    return data;
}

NSData *SZFRandomBytes(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

void SZFOnQueue(dispatch_queue_t queue, void (^block)(void)) {
    dispatch_sync(queue, block);
}

BOOL SZFWaitUntil(dispatch_queue_t queue, NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10.0)];
    while (YES) {
        __block BOOL done = NO;
        dispatch_sync(queue, ^{
            done = condition();
        });
        if (done) {
            return YES;
        }
        if ([deadline timeIntervalSinceNow] < 0) {
            return NO;
        }
        usleep(1000);
    }
}

#pragma mark - Options and frames

SZFriendsHandshakeOptions *SZFOptions(SZFriendsHandshakePattern pattern, SZFriendsIdentity *responder) {
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = pattern;
    options.route = SZFriendsRouteMethodLAN;
    if (pattern == SZFriendsHandshakeIK && responder) {
        options.remoteStaticKey = responder.staticPublicKey;
        options.expectedIdentityKey = responder.publicKey;
    }
    return options;
}

SZFriendsFrame *SZFMessageFrame(NSString *text) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeMessage
                                  fields:@{
                                      @(SZFriendsFieldID) : SZFRandomBytes(16),
                                      @(SZFriendsFieldSentAt) : [SZFriendsFrame fieldWithUInt64:1760251668000
                                                                                            tag:SZFriendsFieldSentAt],
                                      @(SZFriendsFieldText) : [text dataUsingEncoding:NSUTF8StringEncoding],
                                  }];
}

#pragma mark - Channel pairs

void (^SZFImmediateScheduler(void))(NSTimeInterval delay, dispatch_block_t block) {
    return ^(NSTimeInterval delay, dispatch_block_t block) {
        (void)delay;
        block();
    };
}

@implementation SZFChannelPair

+ (instancetype)pairWithOptions:(SZFriendsHandshakeOptions *)options
              initiatorIdentity:(SZFriendsIdentity *)initiatorIdentity
              responderIdentity:(SZFriendsIdentity *)responderIdentity
                  publicProfile:(NSDictionary<NSNumber *, NSData *> *)publicProfile
                         policy:(SZFriendsRemoteKeyPolicy)policy {
    SZFChannelPair *pair = [[SZFChannelPair alloc] init];
    pair->_queue = dispatch_queue_create("szfriends.session.tests", DISPATCH_QUEUE_SERIAL);
    NSArray<SZFMemoryStream *> *streams = [SZFMemoryStream pair];
    pair->_initiatorStream = streams[0];
    pair->_responderStream = streams[1];
    pair->_initiatorFrames = [NSMutableArray array];
    pair->_responderFrames = [NSMutableArray array];
    pair->_initiator = [[SZFriendsSecureChannel alloc] initAsInitiatorWithStream:streams[0]
                                                                         identity:initiatorIdentity
                                                                          options:options
                                                                            queue:pair->_queue];
    __weak SZFChannelPair *weakPair = pair;
    SZFriendsRemoteKeyPolicy recordingPolicy = ^BOOL(NSData *identityKey, SZFriendsHandshakePattern pattern,
                                                     NSData *token) {
        SZFChannelPair *strongPair = weakPair;
        strongPair.policyCalls++;
        strongPair.policyIdentityKey = identityKey;
        strongPair.policyToken = token;
        return policy ? policy(identityKey, pattern, token) : YES;
    };
    pair->_responder = [[SZFriendsSecureChannel alloc] initAsResponderWithStream:streams[1]
                                                                         identity:responderIdentity
                                                                    publicProfile:publicProfile
                                                                        keyPolicy:recordingPolicy
                                                                            queue:pair->_queue];
    [pair->_responder setScheduler:SZFImmediateScheduler()];
    // Its own cache, so a test that replays on purpose decides what this responder has seen.
    pair->_responder.replayCache = [[SZFriendsReplayCache alloc] init];
    pair.initiator.onEstablished = ^{
        weakPair.initiatorEstablished = YES;
    };
    pair.responder.onEstablished = ^{
        weakPair.responderEstablished = YES;
    };
    pair.initiator.onFrame = ^(SZFriendsFrame *frame) {
        [weakPair.initiatorFrames addObject:frame];
    };
    pair.responder.onFrame = ^(SZFriendsFrame *frame) {
        [weakPair.responderFrames addObject:frame];
    };
    pair.initiator.onClose = ^(NSError *error) {
        weakPair.initiatorClosed = YES;
        weakPair.initiatorError = error;
    };
    pair.responder.onClose = ^(NSError *error) {
        weakPair.responderClosed = YES;
        weakPair.responderError = error;
    };
    return pair;
}

- (void)start {
    SZFOnQueue(_queue, ^{
        [self.responder start];
        [self.initiator start];
    });
}

- (BOOL)waitUntilBothEstablished {
    return SZFWaitUntil(_queue, 5, ^BOOL {
        return self.initiatorEstablished && self.responderEstablished;
    });
}

- (BOOL)waitUntilBothClosed {
    return SZFWaitUntil(_queue, 5, ^BOOL {
        return self.initiatorClosed && self.responderClosed;
    });
}

@end
