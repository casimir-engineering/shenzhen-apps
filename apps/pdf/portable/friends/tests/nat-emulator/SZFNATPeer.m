// One host of the punching matrix (SZFNATMatrix.m): the real online driver (SZFriendsOnlineDriver.h) with its real
// transport, order and NAT techniques, in loopback test mode, behind an emulated NAT. It links szfnat_shim.c, so with
// SZFNAT_INSIDE_PORT set every socket it opens goes through its NAT (szfnat.h).
//
// The two hosts of a pair are friends. Their signalling, which in production travels each helper's connection to the
// host (TCP to the server, which a NAT never stops), travels a socket pair on descriptor 3 instead: OPEN, MSG and
// CLOSE frames per sid, as the host forwards them. Relay credentials are made here as the host makes them (TURN REST,
// HMAC-SHA1 under coturn's shared secret). The NATs see everything else: STUN, checks, probes, TCP and the relay.
//
// Environment: SZFNAT_ROLE (offerer or answerer), SZFNAT_SEED (64 hex digits, the pair's), SZFNAT_STUN and
// SZFNAT_STUN2 (the host's two STUN ports on 127.0.0.1), SZFNAT_TURN_PORT and SZFNAT_TURN_SECRET (optional).
// Stdin: "reach" (the offerer starts its attempt). Stdout: one JSON object per line: ready, stream, data (the echo
// came back), relay (the order asked for it) and ended, each with the attempt's technique log so far.

#import <Foundation/Foundation.h>

#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <signal.h>
#include <unistd.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

static const int kSignalFD = 3;
enum { kFrameOpen = 1, kFrameMessage = 2, kFrameClose = 3 };

static void Emit(NSDictionary *event) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    fprintf(stdout, "%.*s\n", (int)json.length, (const char *)json.bytes);
    fflush(stdout);
}

static NSData *Derive(NSData *seed, NSString *label) {
    NSMutableData *input = [seed mutableCopy];
    [input appendData:[label dataUsingEncoding:NSUTF8StringEncoding]];
    NSMutableData *digest = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest.mutableBytes);
    return digest;
}

static NSData *FromHex(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        uint8_t byte = (uint8_t)strtoul([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, NULL, 16);
        [data appendBytes:&byte length:1];
    }
    return data;
}

static void WriteFrame(uint8_t type, uint32_t sid, NSData *payload) {
    uint8_t header[7] = {type, (uint8_t)(sid >> 24), (uint8_t)(sid >> 16), (uint8_t)(sid >> 8), (uint8_t)sid,
                         (uint8_t)(payload.length >> 8), (uint8_t)payload.length};
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:sizeof header];
    if (payload) [frame appendData:payload];
    for (NSUInteger sent = 0; sent < frame.length;) {
        ssize_t n = write(kSignalFD, (const uint8_t *)frame.bytes + sent, frame.length - sent);
        if (n <= 0) return;
        sent += (NSUInteger)n;
    }
}

@interface SZFNATChannel : NSObject <SZFriendsOnlineSignalChannel>
@property(nonatomic) uint32_t sid;
@property(nonatomic) BOOL spoke, closed, farEnded;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@end

@implementation SZFNATChannel
@synthesize onPayload = _onPayload;
@synthesize onEnd = _onEnd;

- (BOOL)ended {
    return _closed || _farEnded;
}

- (BOOL)sendPayload:(NSData *)payload {
    if (self.ended || payload.length == 0 || payload.length > SZFriendsOnlineSignalPayloadMax) return NO;
    _spoke = YES;
    WriteFrame(kFrameMessage, _sid, payload);
    return YES;
}

// As the host does: an end that never spoke leaves nothing behind for the other to notice.
- (void)close {
    if (_closed) return;
    _closed = YES;
    if (_spoke && !_farEnded) WriteFrame(kFrameClose, _sid, nil);
}

- (void)requestRelayCredentials:(void (^)(id<SZFriendsOnlineRelayCredentials>, NSError *))completion {
    NSString *port = _environment[@"SZFNAT_TURN_PORT"], *secret = _environment[@"SZFNAT_TURN_SECRET"];
    SZFriendsOnlineRelayCredentialsValue *value = nil;
    if (port.length > 0 && secret.length > 0) {
        NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:300];
        NSString *username = [NSString stringWithFormat:@"%.0f:szfnat%u", expires.timeIntervalSince1970, _sid];
        uint8_t mac[CC_SHA1_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA1, secret.UTF8String, strlen(secret.UTF8String), username.UTF8String,
               strlen(username.UTF8String), mac);
        value = [SZFriendsOnlineRelayCredentialsValue new];
        value.turnURI = [NSString stringWithFormat:@"turn:127.0.0.1:%@?transport=udp", port];
        value.username = username;
        value.credential = [[NSData dataWithBytes:mac length:sizeof mac] base64EncodedStringWithOptions:0];
        value.expires = expires;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(value, value ? nil : [NSError errorWithDomain:@"SZFNAT" code:1 userInfo:nil]);
    });
}
@end

@interface SZFNATPeer : NSObject <SZFriendsOnlineDriverDelegate>
@end

@implementation SZFNATPeer {
    NSDictionary<NSString *, NSString *> *_environment;
    SZFriendsOnlineDriver *_driver;
    SZFriendsOnlineFriend *_friend;
    NSMutableDictionary<NSNumber *, SZFNATChannel *> *_channels;
    NSMutableData *_inbound;
    uint32_t _nextSid;
    NSDate *_reachedAt;
    SZFriendsOnlineAttempt *_attempt;
    id<SZFriendsByteStream> _stream;
    NSData *_ping;
    NSMutableData *_echo;
    BOOL _reported, _relayReported;
    dispatch_source_t _signalSource, _inputSource, _watch;
}

- (instancetype)initWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment {
    if ((self = [super init])) {
        _environment = environment;
        _channels = [NSMutableDictionary dictionary];
        _inbound = [NSMutableData data];
        _echo = [NSMutableData data];
    }
    return self;
}

- (BOOL)start {
    BOOL offerer = [_environment[@"SZFNAT_ROLE"] isEqualToString:@"offerer"];
    NSData *seed = FromHex(_environment[@"SZFNAT_SEED"] ?: @"");
    if (seed.length != 32) return NO;
    NSString *me = offerer ? @"offerer" : @"answerer", *them = offerer ? @"answerer" : @"offerer";
    SZFriendsIdentity *own =
        [SZFriendsIdentity identityWithSigningSeed:Derive(seed, [me stringByAppendingString:@" sign"])
                                  staticPrivateKey:Derive(seed, [me stringByAppendingString:@" dh"])];
    SZFriendsIdentity *other =
        [SZFriendsIdentity identityWithSigningSeed:Derive(seed, [them stringByAppendingString:@" sign"])
                                  staticPrivateKey:Derive(seed, [them stringByAppendingString:@" dh"])];
    _friend = [SZFriendsOnlineFriend new];
    _friend.identityKey = other.publicKey;
    _friend.staticKey = other.staticPublicKey;
    _friend.presenceSecret = Derive(seed, [them stringByAppendingString:@" presence"]);
    _nextSid = offerer ? 1 : 2; // each side numbers the sids it opens, odd or even
    SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
    _driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:own queue:dispatch_get_main_queue()];
    _driver.delegate = self;
    __weak SZFNATPeer *weakSelf = self;
    _driver.testOpener = ^(NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        (void)rdvKey;
        [weakSelf openWithPayload:payload completion:completion];
    };
    SZFriendsOnlineContext *context = _driver.onlineContext;
    context.stunPrimary = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1"
                                                            port:(uint16_t)_environment[@"SZFNAT_STUN"].intValue];
    context.stunSecondary = [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1"
                                                              port:(uint16_t)_environment[@"SZFNAT_STUN2"].intValue];
    [self listen];
    // A helper that has been online on this network knows its class already: measure it before the attempt.
    [context measureNATClass];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    [self whenClassKnownBy:deadline];
    return YES;
}

- (void)whenClassKnownBy:(NSDate *)deadline {
    SZFriendsOnlineContext *context = _driver.onlineContext;
    if (context.natClass == SZFriendsNATClassUnknown && deadline.timeIntervalSinceNow > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self whenClassKnownBy:deadline];
        });
        return;
    }
    Emit(@{@"event" : @"ready", @"class" : @(context.natClass), @"step" : @(context.natStep)});
}

#pragma mark - Signalling over descriptor 3

- (void)openWithPayload:(NSData *)payload completion:(void (^)(id<SZFriendsOnlineSignalChannel>))completion {
    SZFNATChannel *channel = [self channelWithSid:_nextSid];
    _nextSid += 2;
    channel.spoke = YES;
    completion(channel);
    WriteFrame(kFrameOpen, channel.sid, payload);
}

- (SZFNATChannel *)channelWithSid:(uint32_t)sid {
    SZFNATChannel *channel = [SZFNATChannel new];
    channel.sid = sid;
    channel.environment = _environment;
    _channels[@(sid)] = channel;
    return channel;
}

- (void)listen {
    _signalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, kSignalFD, 0, dispatch_get_main_queue());
    __weak SZFNATPeer *weakSelf = self;
    dispatch_source_set_event_handler(_signalSource, ^{
        [weakSelf readSignalling];
    });
    dispatch_resume(_signalSource);
    _inputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_inputSource, ^{
        [weakSelf readCommand];
    });
    dispatch_resume(_inputSource);
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_watch, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watch, ^{
        [weakSelf watchAttempt];
    });
    dispatch_resume(_watch);
}

- (void)readSignalling {
    uint8_t buffer[8192];
    ssize_t got = read(kSignalFD, buffer, sizeof buffer);
    if (got <= 0) {
        dispatch_source_cancel(_signalSource);
        return;
    }
    [_inbound appendBytes:buffer length:(NSUInteger)got];
    while (_inbound.length >= 7) {
        const uint8_t *bytes = _inbound.bytes;
        NSUInteger length = ((NSUInteger)bytes[5] << 8) | bytes[6];
        if (_inbound.length < 7 + length) break;
        uint32_t sid = ((uint32_t)bytes[1] << 24) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 8) | bytes[4];
        uint8_t type = bytes[0];
        NSData *payload = [_inbound subdataWithRange:NSMakeRange(7, length)];
        [_inbound replaceBytesInRange:NSMakeRange(0, 7 + length) withBytes:NULL length:0];
        [self frame:type sid:sid payload:payload];
    }
}

- (void)frame:(uint8_t)type sid:(uint32_t)sid payload:(NSData *)payload {
    SZFNATChannel *channel = _channels[@(sid)];
    if (type == kFrameOpen && channel == nil) {
        [_driver receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:[self channelWithSid:sid] payload:payload];
    } else if (type == kFrameMessage && channel != nil && !channel.ended) {
        if (channel.onPayload) channel.onPayload(payload);
    } else if (type == kFrameClose && channel != nil && !channel.ended) {
        channel.farEnded = YES;
        if (channel.onEnd) channel.onEnd();
    }
}

- (void)readCommand {
    char buffer[256];
    ssize_t got = read(STDIN_FILENO, buffer, sizeof buffer - 1);
    if (got <= 0) {
        [_driver stop];
        exit(0);
    }
    buffer[got] = 0;
    if (strstr(buffer, "reach") != NULL) {
        _reachedAt = [NSDate date];
        [_driver reachFriend:_friend.identityKey];
    }
}

#pragma mark - What happened

static NSDictionary *LogFields(SZFriendsTechniqueLogEntry *entry) {
    return @{@"technique" : @(entry.firstTechnique), @"tried" : @(entry.techniquesTried),
             @"seconds" : @(entry.secondsToFirstStream), @"relay_requested" : @(entry.relayRequested),
             @"local_class" : @(entry.localNATClass), @"remote_class" : @(entry.remoteNATClass),
             @"end" : @(entry.endReason)};
}

- (void)watchAttempt {
    if (_attempt == nil) _attempt = _driver.attempts.firstObject;
    if (_attempt != nil && !_relayReported && _attempt.order.logEntry.relayRequested) {
        _relayReported = YES;
        NSMutableDictionary *event = [LogFields(_attempt.order.logEntry) mutableCopy];
        event[@"event"] = @"relay";
        event[@"elapsed"] = @(_reachedAt ? -_reachedAt.timeIntervalSinceNow : -1);
        Emit(event);
    }
    if (_attempt == nil || _reported || !_attempt.ended) return;
    _reported = YES;
    NSMutableDictionary *event = [LogFields(_attempt.order.logEntry) mutableCopy];
    event[@"event"] = @"ended";
    Emit(event);
}

- (void)onlineDriverDidBecomeAvailable:(SZFriendsOnlineDriver *)driver {
    (void)driver;
}

- (SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver friendWithIdentityKey:(NSData *)identityKey {
    (void)driver;
    return [identityKey isEqualToData:_friend.identityKey] ? _friend : nil;
}

- (SZFriendsRouteMethod)onlineDriver:(SZFriendsOnlineDriver *)driver nearbyRouteForFriend:(NSData *)identityKey {
    (void)driver;
    (void)identityKey;
    return SZFriendsRouteMethodNone;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
       didOpenStream:(id<SZFriendsByteStream>)stream
               route:(SZFriendsRouteMethod)route
           initiator:(BOOL)initiator
              friend:(NSData *)identityKey {
    (void)driver;
    (void)identityKey;
    if (_attempt == nil) _attempt = _driver.attempts.firstObject;
    NSMutableDictionary *event = [LogFields(_attempt.order.logEntry) mutableCopy];
    event[@"event"] = @"stream";
    event[@"route"] = route == SZFriendsRouteMethodRelay ? @"relay" : @"internet";
    event[@"initiator"] = @(initiator);
    event[@"elapsed"] = @(_reachedAt ? -_reachedAt.timeIntervalSinceNow : -1);
    Emit(event);
    if (_stream != nil) return; // the first stream carries the check
    _stream = stream;
    __weak SZFNATPeer *weakSelf = self;
    stream.onData = ^(NSData *data) {
        [weakSelf streamData:data initiator:initiator];
    };
    stream.onClose = ^(NSError *error) {
        (void)error;
    };
    [stream startWithQueue:dispatch_get_main_queue()];
    if (initiator) {
        uint8_t bytes[16];
        arc4random_buf(bytes, sizeof bytes);
        _ping = [NSData dataWithBytes:bytes length:sizeof bytes];
        [stream writeData:_ping completion:nil];
    }
}

// The initiator's 16 bytes cross both NATs and come back: the path carries data, not just a handshake.
- (void)streamData:(NSData *)data initiator:(BOOL)initiator {
    if (!initiator) {
        [_stream writeData:data completion:nil];
        return;
    }
    [_echo appendData:data];
    if (_ping != nil && _echo.length >= _ping.length) {
        // By now the order has recorded which technique carried the stream.
        NSMutableDictionary *event = [LogFields(_attempt.order.logEntry) mutableCopy];
        event[@"event"] = @"data";
        event[@"ok"] = @([[_echo subdataWithRange:NSMakeRange(0, _ping.length)] isEqual:_ping]);
        Emit(event);
        _ping = nil;
    }
}

@end

int main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        static SZFNATPeer *peer;
        peer = [[SZFNATPeer alloc] initWithEnvironment:[NSProcessInfo processInfo].environment];
        if (![peer start]) {
            fprintf(stderr, "szfnat-peer: SZFNAT_SEED must be 64 hex digits\n");
            return 2;
        }
    }
    dispatch_main();
}
