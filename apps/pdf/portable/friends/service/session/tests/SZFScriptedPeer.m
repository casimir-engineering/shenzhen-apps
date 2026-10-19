// A raw Noise endpoint for tests (SZFScriptedPeer.h).

#import "SZFScriptedPeer.h"

#import <sodium.h>

#import "service/session/SZFriendsHandshakePayload.h"
#import "service/session/SZFriendsSecureChannelInternal.h"

NSData *SZFPeerPayload(SZFriendsIdentity *certificateOwner, NSInteger routeClass, NSData *token) {
    SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload localPayload];
    payload.certificate = certificateOwner.staticCertificate;
    if (routeClass >= 0) {
        payload.hasRouteClass = YES;
        payload.routeClass = (uint8_t)routeClass;
    }
    payload.requestToken = token;
    return [payload encodedDataWithError:NULL];
}

NSData *SZFPlaintext(uint8_t type, NSDictionary<NSNumber *, NSData *> *fields) {
    NSMutableData *data = [NSMutableData dataWithBytes:&type length:1];
    for (NSNumber *tag in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *value = fields[tag];
        uint8_t header[3] = {tag.unsignedCharValue, (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [data appendBytes:header length:3];
        [data appendData:value];
    }
    return data;
}

@implementation SZFScriptedPeer {
    SZFMemoryStream *_stream;
    dispatch_queue_t _queue;
    SZFriendsIdentity *_identity;
    NSDictionary<NSNumber *, NSData *> *_payloads;
    szfriends_handshake_state _handshake;
    szfriends_cipher_state _send, _receive;
    NSMutableData *_buffer;
    BOOL _awaitingPreamble;
}

- (instancetype)initWithStream:(SZFMemoryStream *)stream
                         queue:(dispatch_queue_t)queue
                      identity:(SZFriendsIdentity *)identity {
    if ((self = [super init])) {
        _stream = stream;
        _queue = queue;
        _identity = identity;
        _buffer = [NSMutableData data];
        _plaintexts = [NSMutableArray array];
        _handshakePayloads = [NSMutableArray array];
        _followRekeys = YES;
        __weak SZFScriptedPeer *weakSelf = self;
        stream.onData = ^(NSData *data) {
            [weakSelf receive:data];
        };
        stream.onClose = ^(NSError *error) {
            (void)error;
            SZFScriptedPeer *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_closed = YES;
            }
        };
        [stream startWithQueue:queue];
    }
    return self;
}

- (void)dealloc {
    szfriends_handshake_clear(&_handshake);
}

- (BOOL)initHandshake:(szfriends_noise_pattern)pattern initiator:(BOOL)initiator remoteStatic:(NSData *)remoteStatic {
    uint8_t preamble[4] = {'S', 'Z', SZFriendsSessionMajor, (uint8_t)pattern};
    NSMutableData *prologue = [NSMutableData dataWithBytes:SZFriendsPrologueLabel length:sizeof SZFriendsPrologueLabel];
    [prologue appendBytes:preamble length:4];
    NSData *staticPrivate = pattern == SZFRIENDS_NOISE_NN ? nil : [_identity staticPrivateKey];
    return szfriends_handshake_init(&_handshake, pattern, initiator, prologue.bytes, prologue.length,
                                    staticPrivate.bytes, remoteStatic.bytes) == SZFRIENDS_NOISE_OK;
}

- (NSData *)nextHandshakeMessage {
    NSData *payload = _payloads[@(_handshake.step)] ?: [NSData data];
    uint8_t buffer[SZFRIENDS_NOISE_MAX_MESSAGE + 2];
    size_t written = 0;
    if (szfriends_handshake_write(&_handshake, payload.bytes, payload.length, buffer + 2, sizeof buffer - 2,
                                  &written) != SZFRIENDS_NOISE_OK) {
        _failed = YES;
        return nil;
    }
    buffer[0] = (uint8_t)(written >> 8);
    buffer[1] = (uint8_t)written;
    return [NSData dataWithBytes:buffer length:2 + written];
}

- (void)finishIfDone {
    if (!szfriends_handshake_is_finished(&_handshake)) {
        return;
    }
    uint8_t hash[64];
    szfriends_handshake_hash(&_handshake, hash);
    _handshakeHash = [NSData dataWithBytes:hash length:64];
    szfriends_handshake_split(&_handshake, &_send, &_receive);
    _handshakeDone = YES;
}

- (void)initiatePattern:(szfriends_noise_pattern)pattern
           remoteStatic:(NSData *)remoteStatic
               payloads:(NSDictionary<NSNumber *, NSData *> *)payloads {
    _payloads = [payloads copy];
    if (![self initHandshake:pattern initiator:YES remoteStatic:remoteStatic]) {
        _failed = YES;
        return;
    }
    uint8_t preamble[4] = {'S', 'Z', SZFriendsSessionMajor, (uint8_t)pattern};
    NSMutableData *output = [NSMutableData dataWithBytes:preamble length:4];
    NSData *message = [self nextHandshakeMessage];
    if (message) {
        [output appendData:message];
        [_stream writeData:output completion:nil];
    }
}

- (void)respondWithPayloads:(NSDictionary<NSNumber *, NSData *> *)payloads {
    _payloads = [payloads copy];
    _awaitingPreamble = YES;
}

- (void)receive:(NSData *)data {
    [_buffer appendData:data];
    while (!_failed) {
        const uint8_t *bytes = _buffer.bytes;
        if (_awaitingPreamble) {
            if (_buffer.length < 4) {
                return;
            }
            _awaitingPreamble = NO;
            if (![self initHandshake:(szfriends_noise_pattern)bytes[3] initiator:NO remoteStatic:nil]) {
                _failed = YES;
                return;
            }
            [_buffer replaceBytesInRange:NSMakeRange(0, 4) withBytes:NULL length:0];
            continue;
        }
        if (_buffer.length < 2) {
            return;
        }
        NSUInteger length = ((NSUInteger)bytes[0] << 8) | bytes[1];
        if (_buffer.length < 2 + length) {
            return;
        }
        NSData *message = [_buffer subdataWithRange:NSMakeRange(2, length)];
        [_buffer replaceBytesInRange:NSMakeRange(0, 2 + length) withBytes:NULL length:0];
        [self handleMessage:message];
    }
}

- (void)handleMessage:(NSData *)message {
    uint8_t plain[SZFRIENDS_NOISE_MAX_MESSAGE];
    size_t length = 0;
    if (!_handshakeDone) {
        if (szfriends_handshake_read(&_handshake, message.bytes, message.length, plain, sizeof plain, &length) !=
            SZFRIENDS_NOISE_OK) {
            _failed = YES;
            return;
        }
        [_handshakePayloads addObject:[NSData dataWithBytes:plain length:length]];
        if (szfriends_handshake_is_write_turn(&_handshake)) {
            NSData *reply = [self nextHandshakeMessage];
            if (reply) {
                [_stream writeData:reply completion:nil];
            }
        }
        [self finishIfDone];
        return;
    }
    if (szfriends_cipher_decrypt(&_receive, NULL, 0, message.bytes, message.length, plain, sizeof plain, &length) !=
        SZFRIENDS_NOISE_OK) {
        _failed = YES;
        return;
    }
    NSData *plaintext = [NSData dataWithBytes:plain length:length];
    [_plaintexts addObject:plaintext];
    if (_followRekeys && length == 1 && plain[0] == SZFriendsFrameTypeRekey) {
        szfriends_cipher_rekey(&_receive);
    }
    if (_onPlaintext) {
        _onPlaintext(plaintext);
    }
}

- (NSData *)sealPlaintext:(NSData *)plaintext {
    uint8_t buffer[SZFRIENDS_NOISE_MAX_MESSAGE + 2];
    size_t written = 0;
    if (szfriends_cipher_encrypt(&_send, NULL, 0, plaintext.bytes, plaintext.length, buffer + 2, sizeof buffer - 2,
                                 &written) != SZFRIENDS_NOISE_OK) {
        _failed = YES;
        return nil;
    }
    buffer[0] = (uint8_t)(written >> 8);
    buffer[1] = (uint8_t)written;
    return [NSData dataWithBytes:buffer length:2 + written];
}

- (void)sendPlaintext:(NSData *)plaintext {
    NSData *sealed = [self sealPlaintext:plaintext];
    if (sealed) {
        [_stream writeData:sealed completion:nil];
    }
}

- (void)sendFrame:(SZFriendsFrame *)frame {
    [self sendPlaintext:SZFriendsEncodeFrame(frame, NULL)];
}

- (void)sendRaw:(NSData *)bytes {
    [_stream writeData:bytes completion:nil];
}

@end
