// One client connection: non-blocking socket I/O, newline framing with the 8 MiB cap, and orderly close.
//
// Everything runs on the helper queue. Reads go through the client library's line reader, the same framing code
// the apps use, so both sides agree on what a frame is. Writes queue behind a write source, so a client that reads
// slowly delays only its own frames.

#import "service/helper/SZFriendsIPCPrivate.h"

#import <errno.h>
#import <unistd.h>

#import "client/szfriends_client.h"

const NSUInteger SZFriendsIPCMaxPendingOutput = 64u * 1024 * 1024;

// A goodbye that cannot be written within this long is abandoned; the client treats the close as a crash and
// reconnects, which is the right outcome anyway.
static const int64_t SZFriendsIPCCloseFlushNanoseconds = 2 * NSEC_PER_SEC;
static const size_t SZFriendsIPCReadChunk = 256 * 1024;

@implementation SZFriendsIPCConnection {
    int _fd;
    dispatch_queue_t _queue;
    __weak SZFriendsIPCServer *_server;
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
    BOOL _readSuspended;
    BOOL _writeSuspended;
    BOOL _closed;
    BOOL _notifiedServer;
    BOOL _draining;
    szfriends_line_reader *_reader;
    uint8_t *_readBuffer;
    NSMutableData *_output;
    NSUInteger _outputOffset;
}

- (instancetype)initWithDescriptor:(int)fd
                      connectionID:(NSString *)connectionID
                           peerPID:(pid_t)peerPID
                            server:(SZFriendsIPCServer *)server
                             queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _fd = fd;
        _connectionID = [connectionID copy];
        _peerPID = peerPID;
        _server = server;
        _queue = queue;
        _outstandingIDs = [NSMutableSet set];
        _output = [NSMutableData data];
        _reader = szfriends_line_reader_new(SZFRIENDS_MAX_FRAME_BYTES);
        // On the heap: dispatch worker threads have small stacks.
        _readBuffer = malloc(SZFriendsIPCReadChunk);
    }
    return self;
}

- (void)dealloc {
    szfriends_line_reader_free(_reader);
    free(_readBuffer);
}

- (void)start {
    __weak SZFriendsIPCConnection *weakSelf = self;
    int fd = _fd;
    // Shared by both cancel handlers: the descriptor is closed only after both sources stopped watching it, so a
    // reused number never receives events meant for this connection, and it is closed exactly once.
    __block int remainingSources = 2;
    dispatch_block_t cancelled = ^{
        if (--remainingSources == 0) close(fd);
    };
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_readSource, ^{ [weakSelf readAvailable]; });
    dispatch_source_set_cancel_handler(_readSource, cancelled);
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_writeSource, ^{ [weakSelf flushOutput]; });
    dispatch_source_set_cancel_handler(_writeSource, cancelled);
    _writeSuspended = YES; // created suspended: resumed only while output waits
    dispatch_resume(_readSource);
    if (_reader == NULL || _readBuffer == NULL) [self closeImmediately];
}

#pragma mark - Reading

- (void)readAvailable {
    if (_closed || _readSuspended) return;
    ssize_t count = read(_fd, _readBuffer, SZFriendsIPCReadChunk);
    if (count == 0) {
        [self closeImmediately];
        return;
    }
    if (count < 0) {
        if (errno != EAGAIN && errno != EINTR) [self closeImmediately];
        return;
    }
    if (_closing) return; // closing after a protocol error or goodbye: input no longer matters
    szfriends_status status = szfriends_line_reader_push(_reader, _readBuffer, (size_t)count);
    if (status == SZFRIENDS_ERR_FRAME_TOO_LARGE) {
        [_server connectionReceivedOversizedFrame:self];
        return;
    }
    if (status != SZFRIENDS_OK) {
        [self closeImmediately];
        return;
    }
    [self drainLines];
}

- (void)drainLines {
    if (_draining) return; // a reply sent while handling a line may resume reading re-entrantly
    _draining = YES;
    while (!_closed && !_closing && !_readSuspended) {
        const char *line = NULL;
        size_t length = 0;
        if (szfriends_line_reader_next(_reader, &line, &length) != SZFRIENDS_OK || line == NULL) break;
        // Copied: the reader's buffer is reused by the next call, and the server may keep the frame.
        [_server connection:self didReceiveLine:[NSData dataWithBytes:line length:length]];
    }
    _draining = NO;
}

- (void)pauseReading {
    if (_closed || _readSuspended) return;
    _readSuspended = YES;
    dispatch_suspend(_readSource);
}

- (void)resumeReading {
    if (_closed || !_readSuspended) return;
    _readSuspended = NO;
    dispatch_resume(_readSource);
    // Lines that arrived before the pause are already buffered; nothing new may come from the socket to
    // trigger the source, so drain them on the next turn.
    __weak SZFriendsIPCConnection *weakSelf = self;
    dispatch_async(_queue, ^{ [weakSelf drainLines]; });
}

#pragma mark - Writing

- (void)sendFrame:(NSDictionary<NSString *, id> *)frame {
    if (_closed || _closing) return;
    [self enqueueFrame:frame];
}

- (void)enqueueFrame:(NSDictionary<NSString *, id> *)frame {
    if (![NSJSONSerialization isValidJSONObject:frame]) {
        SZFriendsHelperLog(@"refusing to send a frame that is not JSON (type %@)", frame[@"type"]);
        return;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:frame
                                                   options:NSJSONWritingWithoutEscapingSlashes
                                                     error:&error];
    if (data == nil) {
        SZFriendsHelperLog(@"could not encode a %@ frame: %@", frame[@"type"], error.localizedDescription);
        return;
    }
    if (data.length > SZFRIENDS_MAX_FRAME_BYTES) {
        // A helper bug (snapshots are bounded by design); never send what every client must refuse.
        SZFriendsHelperLog(@"dropped a %@ frame of %lu bytes, over the frame cap", frame[@"type"],
                           (unsigned long)data.length);
        return;
    }
    if (_output.length - _outputOffset + data.length + 1 > SZFriendsIPCMaxPendingOutput) {
        SZFriendsHelperLog(@"closing %@: it stopped reading", self.connectionID);
        [self closeImmediately];
        return;
    }
    [_output appendData:data];
    [_output appendBytes:"\n" length:1];
    [self flushOutput];
}

- (void)flushOutput {
    if (_closed) return;
    while (_outputOffset < _output.length) {
        ssize_t written = write(_fd, (const uint8_t *)_output.bytes + _outputOffset, _output.length - _outputOffset);
        if (written > 0) {
            _outputOffset += (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && errno == EAGAIN) {
            if (_writeSuspended) {
                _writeSuspended = NO;
                dispatch_resume(_writeSource);
            }
            return;
        }
        [self closeImmediately]; // EPIPE, ECONNRESET: the client is gone
        return;
    }
    [_output setLength:0];
    _outputOffset = 0;
    if (!_writeSuspended) {
        _writeSuspended = YES;
        dispatch_suspend(_writeSource);
    }
    if (_closing) [self closeImmediately];
}

#pragma mark - Closing

- (void)closeWithGoodbyeReason:(nullable NSString *)reason {
    if (reason == nil) {
        [self closeImmediately];
        return;
    }
    [self sendGoodbyeWithReason:reason successor:nil error:nil];
}

- (void)sendGoodbyeWithReason:(NSString *)reason
                    successor:(nullable NSDictionary<NSString *, id> *)successor
                        error:(nullable NSDictionary<NSString *, id> *)error {
    if (_closed || _closing) return;
    [self enqueueFrame:@{
        @"type" : @"goodbye",
        @"reason" : reason,
        @"message" : [NSNull null],
        @"successor" : successor ?: [NSNull null],
        @"error" : error ?: [NSNull null],
    }];
    if (_closed) return;
    _closing = YES;
    if (_outputOffset >= _output.length) {
        [self closeImmediately];
        return;
    }
    __weak SZFriendsIPCConnection *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SZFriendsIPCCloseFlushNanoseconds), _queue,
                   ^{ [weakSelf closeImmediately]; });
}

- (void)closeImmediately {
    if (_closed) return;
    _closed = YES;
    _closing = YES;
    // A suspended source cannot be cancelled or released; resume first so its cancel handler runs.
    if (_readSource != nil) {
        if (_readSuspended) dispatch_resume(_readSource);
        dispatch_source_cancel(_readSource);
    }
    if (_writeSource != nil) {
        if (_writeSuspended) dispatch_resume(_writeSource);
        dispatch_source_cancel(_writeSource);
    }
    if (_readSource == nil && _writeSource == nil) close(_fd);
    _readSuspended = NO;
    _writeSuspended = NO;
    if (!_notifiedServer) {
        _notifiedServer = YES;
        [_server connectionDidClose:self];
    }
}

@end
