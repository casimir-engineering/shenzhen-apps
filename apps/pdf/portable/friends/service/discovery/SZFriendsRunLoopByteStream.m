// NSInputStream/NSOutputStream pairs (L2CAP channels) as an SZFriendsByteStream.
//
// L2CAP streams are run-loop streams with no dispatch-queue API, and the helper runs on dispatch queues, so every
// such stream is scheduled on one shared thread that only runs a run loop. All stream state below is touched on
// that thread; session callbacks hop to the queue given to -startWithQueue:.

#import "service/discovery/SZFriendsDiscoveryInternal.h"

enum { kReadBufferSize = 4096 }; // an enum, so the stack buffer below is a constant array
// After -close, queued writes (the session's CLOSE frame) get this long to drain before the streams close.
static const NSTimeInterval kDrainTimeout = 2;

static CFRunLoopRef StreamRunLoop(void) {
    static CFRunLoopRef runLoop;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            runLoop = CFRunLoopGetCurrent();
            CFRetain(runLoop);
            // A port keeps the run loop alive while no stream is scheduled.
            [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
            dispatch_semaphore_signal(ready);
            for (;;) {
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
                }
            }
        }];
        thread.name = @"Shenzhen Friends streams";
        thread.qualityOfService = NSQualityOfServiceUtility;
        [thread start];
        dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    });
    return runLoop;
}

static void OnStreamThread(dispatch_block_t block) {
    CFRunLoopRef runLoop = StreamRunLoop();
    CFRunLoopPerformBlock(runLoop, kCFRunLoopDefaultMode, block);
    CFRunLoopWakeUp(runLoop);
}

@interface SZFriendsRunLoopByteStream () <NSStreamDelegate>
@end

@implementation SZFriendsRunLoopByteStream {
    NSInputStream *_input;
    NSOutputStream *_output;
    id _owner;
    NSUInteger _preferredWriteSize;
    dispatch_queue_t _callbackQueue;
    NSMutableArray<NSData *> *_writes;
    NSMutableArray *_completions; // NSNull or a completion block, one per write
    NSUInteger _writtenOfFirst;
    BOOL _started, _finished, _closeRequested, _spaceSignalled, _outputEnded;
}

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)initWithInputStream:(NSInputStream *)input
                       outputStream:(NSOutputStream *)output
                              owner:(id)owner
                 preferredWriteSize:(NSUInteger)preferredWriteSize {
    if ((self = [super init])) {
        _input = input;
        _output = output;
        _owner = owner;
        _preferredWriteSize = preferredWriteSize;
        _writes = [NSMutableArray array];
        _completions = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    if (_finished || !_started) return;
    // Released without -close: the run loop still holds the streams (their delegate is weak), so unschedule them
    // there rather than leave a dead link open.
    NSArray<NSStream *> *streams = @[ _input, _output ];
    id owner = _owner;
    OnStreamThread(^{
        for (NSStream *stream in streams) {
            [stream close];
            [stream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        }
        (void)owner; // the channel goes last, after its streams
    });
}

- (NSUInteger)preferredWriteSize {
    return _preferredWriteSize;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    _callbackQueue = queue;
    OnStreamThread(^{
        if (self->_started || self->_finished) return;
        self->_started = YES;
        for (NSStream *stream in @[ self->_input, self->_output ]) {
            stream.delegate = self;
            [stream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            [stream open];
        }
    });
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    NSData *copy = [data copy];
    id done = completion ? [completion copy] : [NSNull null];
    OnStreamThread(^{
        if (self->_finished || self->_outputEnded) {
            [self complete:done error:SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"stream closed")];
            return;
        }
        [self->_writes addObject:copy];
        [self->_completions addObject:done];
        [self flush];
    });
}

- (void)close {
    OnStreamThread(^{
        if (self->_finished) return;
        self->_closeRequested = YES;
        if (!self->_writes.count || !self->_started) {
            [self finishWithError:nil notify:NO];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDrainTimeout * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                           OnStreamThread(^{
                               [self finishWithError:nil notify:NO];
                           });
                       });
    });
}

#pragma mark - On the stream thread

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    if (_finished) return;
    switch (event) {
    case NSStreamEventHasBytesAvailable:
        [self readAvailableAtEnd:NO];
        break;
    case NSStreamEventHasSpaceAvailable:
        // Signalled once per write; remembered, because it may arrive while nothing is queued.
        _spaceSignalled = YES;
        [self flush];
        break;
    case NSStreamEventEndEncountered:
        if (stream == _input) {
            // The end can be reported before the last bytes were read; deliver them first.
            [self readAvailableAtEnd:YES];
            [self finishWithError:nil notify:YES];
        } else {
            [self outputEnded];
        }
        break;
    case NSStreamEventErrorOccurred:
        [self finishWithError:stream.streamError
                                  ?: SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"stream error")
                       notify:YES];
        break;
    default:
        break;
    }
}

// At the end of the stream hasBytesAvailable can already say NO with bytes still buffered; reading cannot block
// then, so read until the stream itself reports the end.
- (void)readAvailableAtEnd:(BOOL)atEnd {
    uint8_t buffer[kReadBufferSize];
    while (!_finished && (atEnd || _input.hasBytesAvailable)) {
        NSInteger count = [_input read:buffer maxLength:sizeof buffer];
        if (count <= 0) break; // 0 is end of stream, reported as its own event
        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)count];
        dispatch_async(_callbackQueue, ^{
            if (self.onData) self.onData(data);
        });
    }
}

- (void)flush {
    while (_writes.count && (_spaceSignalled || _output.hasSpaceAvailable)) {
        _spaceSignalled = NO;
        NSData *first = _writes.firstObject;
        NSInteger count = [_output write:(const uint8_t *)first.bytes + _writtenOfFirst
                               maxLength:first.length - _writtenOfFirst];
        if (count < 0) {
            [self finishWithError:_output.streamError notify:YES];
            return;
        }
        if (count == 0) break;
        _writtenOfFirst += (NSUInteger)count;
        if (_writtenOfFirst < first.length) continue;
        _writtenOfFirst = 0;
        [_writes removeObjectAtIndex:0];
        id done = _completions.firstObject;
        [_completions removeObjectAtIndex:0];
        [self complete:done error:nil];
    }
    if (_closeRequested && !_writes.count) [self finishWithError:nil notify:NO];
}

// The peer stopped reading. What it sent before that may still be arriving, so keep reading until the input
// ends too, for at most the drain timeout.
- (void)outputEnded {
    if (_outputEnded) return;
    _outputEnded = YES;
    NSError *failure = SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"peer stopped reading");
    for (id done in _completions) [self complete:done error:failure];
    [_writes removeAllObjects];
    [_completions removeAllObjects];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDrainTimeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       OnStreamThread(^{
                           [self finishWithError:nil notify:YES];
                       });
                   });
}

- (void)complete:(id)done error:(NSError *)error {
    if (done == [NSNull null] || !_callbackQueue) return;
    void (^completion)(NSError *) = done;
    dispatch_async(_callbackQueue, ^{
        completion(error);
    });
}

// `notify`: the peer or the link ended it, so the session hears about it; a local close does not call back.
- (void)finishWithError:(NSError *)error notify:(BOOL)notify {
    if (_finished) return;
    _finished = YES;
    for (NSStream *stream in @[ _input, _output ]) {
        stream.delegate = nil;
        [stream close];
        [stream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    }
    NSError *failure = error ?: SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorCancelled, @"stream closed");
    for (id done in _completions) [self complete:done error:failure];
    [_writes removeAllObjects];
    [_completions removeAllObjects];
    _owner = nil; // releasing the L2CAP channel closes it
    if (notify && !_closeRequested && _callbackQueue) {
        dispatch_async(_callbackQueue, ^{
            if (self.onClose) self.onClose(error);
        });
    }
}

@end
