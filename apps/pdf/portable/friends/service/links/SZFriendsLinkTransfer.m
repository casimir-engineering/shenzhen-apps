// A download link's file over its data channel (SZFriendsLinksInternal.h): the sender's records and the opener's side
// of them, as the link pages read and write them (receiver.js). The opener grants credit in chunks; the sender never
// runs ahead of it, so neither side holds more than the window in memory, whatever the file's size. A download whose
// connection drops carries on over a new one (new nonces, so a new content key) from the first chunk the opener has
// not written: the opener's start says "from", and the sender hashes the bytes before it again before sending on.

#import "service/links/SZFriendsLinksInternal.h"

#include <fcntl.h>
#include <unistd.h>

#import <sodium.h>

static const uint64_t SZFriendsLinkCreditWindow = 64; // what the opener grants ahead of what it has written

static const uint64_t SZFriendsLinkCreditStep = 16;   // and how often it grants more

static NSData *SZFriendsLinkJSON(NSDictionary *object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

static NSDictionary *SZFriendsLinkObject(NSData *data) {
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

@implementation SZFriendsLinkUpload {
    id<SZFriendsByteStream> _stream;
    SZFriendsDownloadLinkRecord *_link;
    SZFriendsLinkMetadata *_metadata;
    NSData *_key;
    dispatch_queue_t _queue;
    int _fd;
    uint64_t _credit, _next, _controls;
    crypto_hash_sha256_state _hash;
    BOOL _started, _writing, _sentFinal, _finished, _hashing;
}

- (instancetype)initWithStream:(id<SZFriendsByteStream>)stream
                          link:(SZFriendsDownloadLinkRecord *)link
                      metadata:(SZFriendsLinkMetadata *)metadata
                    contentKey:(NSData *)contentKey
                         queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _startTimeout = 15 * 60;
        _stream = stream;
        _link = link;
        _metadata = metadata;
        _key = contentKey;
        _queue = queue;
        _fd = -1;
        crypto_hash_sha256_init(&_hash);
    }
    return self;
}

- (void)dealloc {
    if (_fd >= 0) close(_fd);
}

- (void)start {
    NSString *path = SZFriendsLinkServedPath(_link);
    _fd = path ? open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC) : -1;
    __weak SZFriendsLinkUpload *weakSelf = self;
    _stream.onData = ^(NSData *data) { [weakSelf control:data]; };
    _stream.onClose = ^(NSError *error) {
        (void)error;
        [weakSelf finish:NO];
    };
    [_stream startWithQueue:_queue];
    NSData *plain = [_metadata recordPlaintext];
    if (_fd < 0 || plain == nil) {
        [self endWithReason:SZFriendsLinkEndChanged];
        return;
    }
    [self write:SZFriendsLinkSealRecord(_key, SZFriendsLinkRecordMetadata, 0, plain)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_startTimeout * NSEC_PER_SEC)), _queue, ^{
        SZFriendsLinkUpload *upload = weakSelf;
        if (upload != nil && !upload->_started) [upload finish:NO];
    });
}

- (void)control:(NSData *)record {
    if (_finished) return;
    NSDictionary *message = SZFriendsLinkObject(
        SZFriendsLinkOpenRecord(_key, @[ @(SZFriendsLinkRecordControl) ], _controls, record, NULL));
    if (message == nil) {
        [self finish:NO]; // anything else from the opener breaks the exchange
        return;
    }
    _controls += 1;
    NSString *type = message[@"t"];
    id upto = message[@"upto"];
    if (([type isEqual:@"start"] || [type isEqual:@"credit"]) && [upto isKindOfClass:[NSNumber class]]) {
        if ([type isEqual:@"start"] && !_started && message[@"from"] != nil && ![self resumeFrom:message[@"from"]]) {
            [self finish:NO];
            return;
        }
        // Never more than the window the opener could possibly have asked for, whatever it says.
        _credit = MAX(_credit, MIN([upto unsignedLongLongValue], _next + SZFriendsLinkCreditMax));
        _started = YES;
        [self pump];
    } else if ([type isEqual:@"done"]) {
        [self finish:[message[@"ok"] isEqual:@YES] && _sentFinal];
    } else if ([type isEqual:@"cancel"]) {
        [self finish:NO];
    }
}

// A start that carries on from chunk `from`: the bytes before it are hashed again, off the queue, so the final
// chunk still goes only when everything the opener holds is the file the link was made for. NO for a chunk the
// file does not have.
- (BOOL)resumeFrom:(id)from {
    uint64_t chunks = MAX(1, (_link.size + SZFriendsLinkChunkBytes - 1) / SZFriendsLinkChunkBytes);
    double value = [from isKindOfClass:[NSNumber class]] ? [from doubleValue] : -1;
    if (value < 0 || value != floor(value) || value >= (double)chunks) return NO;
    uint64_t first = (uint64_t)value;
    if (first == 0) return YES;
    _next = first;
    _hashing = YES;
    int fd = _fd;
    uint64_t length = first * SZFriendsLinkChunkBytes;
    __block crypto_hash_sha256_state state;
    crypto_hash_sha256_init(&state);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableData *buffer = [NSMutableData dataWithLength:1 << 20];
        BOOL ok = fd >= 0;
        for (uint64_t at = 0; ok && at < length;) {
            size_t want = (size_t)MIN((uint64_t)buffer.length, length - at);
            ssize_t got = pread(fd, buffer.mutableBytes, want, (off_t)at);
            ok = got == (ssize_t)want;
            if (ok) crypto_hash_sha256_update(&state, buffer.bytes, want);
            at += want;
        }
        dispatch_async(self->_queue, ^{
            self->_hash = state;
            self->_hashing = NO;
            if (!ok) [self endWithReason:SZFriendsLinkEndChanged];
            else [self pump];
        });
    });
    return YES;
}

- (void)write:(NSData *)record {
    if (record == nil || _finished) return;
    _writing = YES;
    __weak SZFriendsLinkUpload *weakSelf = self;
    [_stream writeData:record completion:^(NSError *error) {
        SZFriendsLinkUpload *upload = weakSelf;
        if (upload == nil) return;
        upload->_writing = NO;
        if (error != nil) [upload finish:NO];
        else [upload pump];
    }];
}

- (void)pump {
    if (_finished || _writing || _hashing || !_started || _sentFinal || _next >= _credit) return;
    uint64_t offset = _next * SZFriendsLinkChunkBytes;
    uint64_t left = _link.size > offset ? _link.size - offset : 0;
    BOOL final = left <= SZFriendsLinkChunkBytes;
    NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)MIN(left, SZFriendsLinkChunkBytes)];
    ssize_t got = bytes.length ? pread(_fd, bytes.mutableBytes, bytes.length, (off_t)offset) : 0;
    if (got != (ssize_t)bytes.length) {
        [self endWithReason:SZFriendsLinkEndChanged]; // shorter than when the link was made
        return;
    }
    crypto_hash_sha256_update(&_hash, bytes.bytes, bytes.length);
    if (final) {
        NSMutableData *digest = [NSMutableData dataWithLength:32];
        crypto_hash_sha256_final(&_hash, digest.mutableBytes);
        // The last bytes go only when everything sent is the file the link was made for.
        if (![digest isEqualToData:_link.sha256]) {
            [self endWithReason:SZFriendsLinkEndChanged];
            return;
        }
        _sentFinal = YES;
    }
    SZFriendsLinkRecordType type = final ? SZFriendsLinkRecordFinal : SZFriendsLinkRecordChunk;
    [self write:SZFriendsLinkSealRecord(_key, type, _next, bytes)];
    _next += 1;
}

- (void)endWithReason:(NSString *)reason {
    NSData *record = SZFriendsLinkSealRecord(_key, SZFriendsLinkRecordEnd, 0, SZFriendsLinkJSON(@{@"reason" : reason}));
    __weak SZFriendsLinkUpload *weakSelf = self;
    [_stream writeData:record completion:^(NSError *error) {
        (void)error;
        [weakSelf finish:NO];
    }];
    _sentFinal = YES; // nothing more goes
}

- (void)finish:(BOOL)downloaded {
    if (_finished) return;
    _finished = YES;
    void (^onFinish)(BOOL) = self.onFinish;
    self.onFinish = nil;
    if (onFinish) onFinish(downloaded);
}

- (void)close {
    [self finish:NO];
    _stream.onData = nil;
    _stream.onClose = nil;
    [_stream close];
}

@end

@implementation SZFriendsLinkDownload {
    id<SZFriendsByteStream> _stream;
    NSData *_key;
    id<SZFriendsLinkSink> _sink;
    dispatch_queue_t _queue;
    SZFriendsLinkMetadata *_metadata;
    uint64_t _next, _received, _controls;
    crypto_hash_sha256_state _hash;
    NSUInteger _stallGeneration;
    BOOL _finished, _resuming, _metadataHere, _started;
}

- (instancetype)initWithStream:(id<SZFriendsByteStream>)stream
                    contentKey:(NSData *)contentKey
                          sink:(id<SZFriendsLinkSink>)sink
                         queue:(dispatch_queue_t)queue
                  resumingFrom:(SZFriendsLinkDownload *)previous {
    if ((self = [super init])) {
        _stream = stream;
        _key = contentKey;
        _sink = sink;
        _queue = queue;
        _stallTimeout = 30;
        crypto_hash_sha256_init(&_hash);
        if (previous != nil) {
            _resuming = YES;
            _metadata = previous->_metadata;
            _next = previous->_next;
            _received = previous->_received;
            _hash = previous->_hash;
        }
    }
    return self;
}

- (uint64_t)nextChunk {
    return _next;
}

// Nothing for stallTimeout once the file was asked for counts as a dropped connection.
- (void)armStall {
    NSUInteger generation = ++_stallGeneration;
    __weak SZFriendsLinkDownload *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_stallTimeout * NSEC_PER_SEC)), _queue, ^{
        SZFriendsLinkDownload *download = weakSelf;
        if (download == nil || download->_finished || download->_stallGeneration != generation) return;
        download->_lost = YES;
        download->_stream.onClose = nil;
        [download->_stream close];
        [download finish:SZFriendsLinkOutcomeFailed];
    });
}

- (void)start {
    __weak SZFriendsLinkDownload *weakSelf = self;
    _stream.onData = ^(NSData *data) { [weakSelf record:data]; };
    _stream.onClose = ^(NSError *error) {
        (void)error;
        SZFriendsLinkDownload *download = weakSelf;
        if (download == nil) return;
        download->_lost = download->_started && !download->_finished;
        [download finish:SZFriendsLinkOutcomeFailed];
    };
    [_stream startWithQueue:_queue];
}

- (void)control:(NSDictionary *)message {
    NSData *record = SZFriendsLinkSealRecord(_key, SZFriendsLinkRecordControl, _controls++, SZFriendsLinkJSON(message));
    [_stream writeData:record completion:^(NSError *error) { (void)error; }];
}

- (void)record:(NSData *)record {
    if (_finished) return;
    if (record.length > 0 && ((const uint8_t *)record.bytes)[0] == SZFriendsLinkRecordEnd) {
        NSDictionary *end = SZFriendsLinkObject(
            SZFriendsLinkOpenRecord(_key, @[ @(SZFriendsLinkRecordEnd) ], 0, record, NULL));
        BOOL changed = [end[@"reason"] isEqual:SZFriendsLinkEndChanged];
        [self finish:end == nil ? SZFriendsLinkOutcomeFailed
                                : changed ? SZFriendsLinkOutcomeChanged : SZFriendsLinkOutcomeEnded];
        return;
    }
    if (!_metadataHere) {
        NSData *plain = SZFriendsLinkOpenRecord(_key, @[ @(SZFriendsLinkRecordMetadata) ], 0, record, NULL);
        SZFriendsLinkMetadata *metadata = plain ? [SZFriendsLinkMetadata metadataFromRecordPlaintext:plain] : nil;
        _metadataHere = YES;
        if (_resuming) {
            // Carrying on: the same file, or nothing.
            if (metadata.size != _metadata.size || ![metadata.sha256 isEqualToData:_metadata.sha256]) {
                [self finish:SZFriendsLinkOutcomeFailed];
                return;
            }
            [self control:@{@"t" : @"start", @"from" : @(_next), @"upto" : @(_next + SZFriendsLinkCreditWindow)}];
        } else {
            _metadata = metadata;
            if (_metadata == nil || ![_sink linkDidReceiveMetadata:_metadata]) {
                [self finish:SZFriendsLinkOutcomeFailed];
                return;
            }
            [self control:@{@"t" : @"start", @"upto" : @(SZFriendsLinkCreditWindow)}];
        }
        _started = YES;
        [self armStall];
        return;
    }
    SZFriendsLinkRecordType type = 0;
    NSData *plain = SZFriendsLinkOpenRecord(_key, @[ @(SZFriendsLinkRecordChunk), @(SZFriendsLinkRecordFinal) ], _next,
                                            record, &type);
    BOOL final = type == SZFriendsLinkRecordFinal;
    uint64_t size = _metadata.size, offset = _received;
    if (plain == nil || plain.length > SZFriendsLinkChunkBytes ||
        (!final && (plain.length != SZFriendsLinkChunkBytes || _received + plain.length >= size)) ||
        (final && _received + plain.length != size)) {
        [self finish:SZFriendsLinkOutcomeFailed];
        return;
    }
    _received += plain.length;
    _next += 1;
    crypto_hash_sha256_update(&_hash, plain.bytes, plain.length);
    [self armStall];
    if (final) {
        NSMutableData *digest = [NSMutableData dataWithLength:32];
        crypto_hash_sha256_final(&_hash, digest.mutableBytes);
        BOOL intact = [digest isEqualToData:_metadata.sha256];
        if (!intact || ![_sink linkDidReceiveBytes:plain atOffset:offset] || ![_sink linkDidFinish]) {
            [self finish:SZFriendsLinkOutcomeFailed];
            return;
        }
        [self control:@{@"t" : @"done", @"ok" : @YES}];
        [self finish:SZFriendsLinkOutcomeDone];
        return;
    }
    if (![_sink linkDidReceiveBytes:plain atOffset:offset]) {
        [self control:@{@"t" : @"cancel"}];
        [self finish:SZFriendsLinkOutcomeFailed];
        return;
    }
    if (_next % SZFriendsLinkCreditStep == 0) {
        [self control:@{@"t" : @"credit", @"upto" : @(_next + SZFriendsLinkCreditWindow)}];
    }
}

- (void)finish:(SZFriendsLinkOutcome)outcome {
    if (_finished) return;
    _finished = YES;
    _stallGeneration += 1;
    if (outcome != SZFriendsLinkOutcomeDone && !_lost) [_sink linkDidStop:outcome];
    void (^onFinish)(SZFriendsLinkOutcome) = self.onFinish;
    self.onFinish = nil;
    if (onFinish) onFinish(outcome);
}

- (void)close {
    [self finish:SZFriendsLinkOutcomeFailed];
    _stream.onData = nil;
    _stream.onClose = nil;
    // A moment for the last control record (done, cancel) to leave before the connection goes.
    id<SZFriendsByteStream> stream = _stream;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), _queue, ^{ [stream close]; });
}

@end
