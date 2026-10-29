// Windowed CHUNK flow, PROGRESS and resume (SZFriendsSession.h § File chunks; ADR 0001 § Files, § Resume and route
// migration). Pure state machines: the helper reads file bytes, writes them to the store and sends the frames.
//
// Offsets and lengths are checked here against what this session agreed, never trusted from the peer: a CHUNK must
// continue exactly where the last one ended, stay inside the offered size and inside the window past the last
// PROGRESS, so a peer can neither make the recipient seek nor make it buffer more than the window.

#import "service/session/SZFriendsSession.h"

#import "service/session/SZFriendsFrameSchema.h"

static BOOL SZFriendsFlowFail(NSError **error, NSString *reason) {
    if (error) {
        *error = SZFriendsSessionMakeError(SZFriendsSessionErrorProtocol, reason);
    }
    return NO;
}

static BOOL SZFriendsFlowParametersValid(NSData *offerID, uint64_t size, uint64_t offset, NSUInteger chunkBytes,
                                         uint64_t window) {
    return offerID.length == 16 && offset <= size && chunkBytes > 0 && chunkBytes <= SZFriendsChunkBytesWiFi &&
           chunkBytes <= window;
}

// a + b without wrapping, for windows near the top of the 64-bit range.
static uint64_t SZFriendsSaturatingAdd(uint64_t a, uint64_t b) {
    return a > UINT64_MAX - b ? UINT64_MAX : a + b;
}

static SZFriendsFrame *SZFriendsProgressFrame(NSData *offerID, uint64_t offset) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeProgress
                                  fields:@{
                                      @(SZFriendsFieldID) : offerID,
                                      @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:offset
                                                                                            tag:SZFriendsFieldOffset],
                                  }];
}

@implementation SZFriendsChunkSender {
    NSUInteger _chunkBytes;
    uint64_t _window;
}

- (instancetype)initWithOfferID:(NSData *)offerID
                           size:(uint64_t)size
                   resumeOffset:(uint64_t)resumeOffset
                     chunkBytes:(NSUInteger)chunkBytes
                         window:(uint64_t)window {
    if (!SZFriendsFlowParametersValid(offerID, size, resumeOffset, chunkBytes, window)) {
        return nil;
    }
    if ((self = [super init])) {
        _offerID = [offerID copy];
        _size = size;
        _sentOffset = resumeOffset;
        _durableOffset = resumeOffset;
        _chunkBytes = chunkBytes;
        _window = window;
    }
    return self;
}

- (instancetype)initWithOfferID:(NSData *)offerID
                           size:(uint64_t)size
                   resumeOffset:(uint64_t)resumeOffset
                          route:(SZFriendsRouteMethod)route {
    return [self initWithOfferID:offerID
                            size:size
                    resumeOffset:resumeOffset
                      chunkBytes:SZFriendsChunkBytesForRoute(route)
                          window:SZFriendsSendWindowForRoute(route)];
}

- (BOOL)allSent {
    return _sentOffset == _size;
}

- (BOOL)acknowledged {
    return _durableOffset == _size;
}

// Full-size chunks only, except the file's last: a chunk that would cross the window waits for the next PROGRESS
// rather than going out short, so a slow PROGRESS cadence never turns into a stream of tiny frames.
- (BOOL)getNextChunkOffset:(uint64_t *)offset length:(NSUInteger *)length {
    if (_sentOffset >= _size) {
        return NO;
    }
    uint64_t remaining = _size - _sentOffset;
    NSUInteger next = remaining < _chunkBytes ? (NSUInteger)remaining : _chunkBytes;
    if (SZFriendsSaturatingAdd(_sentOffset, next) > SZFriendsSaturatingAdd(_durableOffset, _window)) {
        return NO;
    }
    *offset = _sentOffset;
    *length = next;
    return YES;
}

- (SZFriendsFrame *)chunkFrameWithData:(NSData *)data {
    uint64_t offset = 0;
    NSUInteger length = 0;
    if (![self getNextChunkOffset:&offset length:&length] || data.length != length) {
        return nil;
    }
    _sentOffset += length;
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeChunk
                                  fields:@{
                                      @(SZFriendsFieldID) : _offerID,
                                      @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:offset
                                                                                            tag:SZFriendsFieldOffset],
                                      @(SZFriendsFieldData) : data,
                                  }];
}

- (BOOL)handleProgressFrame:(SZFriendsFrame *)frame error:(NSError **)error {
    uint64_t offset = 0;
    if (frame.type != SZFriendsFrameTypeProgress || ![[frame dataForTag:SZFriendsFieldID] isEqualToData:_offerID] ||
        ![frame getUInt64:&offset forTag:SZFriendsFieldOffset]) {
        return SZFriendsFlowFail(error, @"PROGRESS for another transfer");
    }
    if (offset < _durableOffset) {
        return SZFriendsFlowFail(error, @"PROGRESS went backwards");
    }
    if (offset > _sentOffset) {
        return SZFriendsFlowFail(error, @"PROGRESS for bytes never sent");
    }
    _durableOffset = offset;
    return YES;
}

@end

@implementation SZFriendsChunkReceiver {
    uint64_t _size;
    uint64_t _startedOffset;
    NSUInteger _chunkBytes;
    uint64_t _window;
}

- (instancetype)initWithOfferID:(NSData *)offerID
                           size:(uint64_t)size
                 verifiedOffset:(uint64_t)verifiedOffset
                     chunkBytes:(NSUInteger)chunkBytes
                         window:(uint64_t)window {
    if (!SZFriendsFlowParametersValid(offerID, size, verifiedOffset, chunkBytes, window)) {
        return nil;
    }
    if ((self = [super init])) {
        _offerID = [offerID copy];
        _size = size;
        _receivedOffset = verifiedOffset;
        _reportedOffset = verifiedOffset;
        _startedOffset = verifiedOffset;
        _chunkBytes = chunkBytes;
        _window = window;
    }
    return self;
}

- (instancetype)initWithOfferID:(NSData *)offerID
                           size:(uint64_t)size
                 verifiedOffset:(uint64_t)verifiedOffset
                          route:(SZFriendsRouteMethod)route {
    return [self initWithOfferID:offerID
                            size:size
                  verifiedOffset:verifiedOffset
                      chunkBytes:SZFriendsChunkBytesForRoute(route)
                          window:SZFriendsSendWindowForRoute(route)];
}

- (BOOL)complete {
    return _receivedOffset == _size;
}

- (BOOL)arriving {
    return _receivedOffset > _startedOffset && !self.complete;
}

- (SZFriendsFrame *)resumeProgressFrame {
    return SZFriendsProgressFrame(_offerID, _reportedOffset);
}

- (NSData *)acceptChunkFrame:(SZFriendsFrame *)frame error:(NSError **)error {
    uint64_t offset = 0;
    NSData *data = [frame dataForTag:SZFriendsFieldData];
    if (frame.type != SZFriendsFrameTypeChunk || ![[frame dataForTag:SZFriendsFieldID] isEqualToData:_offerID] ||
        ![frame getUInt64:&offset forTag:SZFriendsFieldOffset] || data == nil) {
        SZFriendsFlowFail(error, @"CHUNK for another transfer");
        return nil;
    }
    if (offset != _receivedOffset) {
        SZFriendsFlowFail(error, @"CHUNK does not continue where the last one ended");
        return nil;
    }
    if (data.length > _chunkBytes || data.length > _size - _receivedOffset) {
        SZFriendsFlowFail(error, @"CHUNK larger than the route allows or past the offered size");
        return nil;
    }
    if (_receivedOffset + data.length > SZFriendsSaturatingAdd(_reportedOffset, _window)) {
        SZFriendsFlowFail(error, @"CHUNK beyond the window past the last PROGRESS");
        return nil;
    }
    _receivedOffset += data.length;
    return data;
}

- (SZFriendsFrame *)progressFrameForDurableOffset:(uint64_t)durableOffset {
    if (durableOffset < _reportedOffset || durableOffset > _receivedOffset) {
        return nil;
    }
    _reportedOffset = durableOffset;
    return SZFriendsProgressFrame(_offerID, durableOffset);
}

- (NSData *)acceptDoneFrame:(SZFriendsFrame *)frame error:(NSError **)error {
    NSData *digest = [frame dataForTag:SZFriendsFieldDigest];
    if (frame.type != SZFriendsFrameTypeDone || ![[frame dataForTag:SZFriendsFieldID] isEqualToData:_offerID] ||
        digest == nil) {
        SZFriendsFlowFail(error, @"DONE for another transfer");
        return nil;
    }
    if (!self.complete) {
        SZFriendsFlowFail(error, @"DONE before every byte arrived");
        return nil;
    }
    return digest;
}

@end

void SZFriendsTransferLiveness(NSArray<SZFriendsChunkSender *> *senders, NSArray<SZFriendsChunkReceiver *> *receivers,
                               BOOL *keepalive, BOOL *watch) {
    BOOL ping = NO, due = NO;
    for (SZFriendsChunkSender *sender in senders) {
        ping = YES;
        due |= sender.sentOffset > sender.durableOffset;
    }
    for (SZFriendsChunkReceiver *receiver in receivers) {
        ping = YES;
        due |= receiver.arriving;
    }
    *keepalive = ping;
    *watch = due;
}
