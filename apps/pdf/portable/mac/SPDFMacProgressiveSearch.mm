#import "SPDFMacProgressiveSearch.h"

#include <atomic>
#include <os/lock.h>

@implementation SPDFMacSearchPageResult
- (instancetype)initWithPageIndex:(NSUInteger)pageIndex payload:(id)payload {
    self = [super init];
    if (self) {
        _pageIndex = pageIndex;
        _payload = payload;
    }
    return self;
}
@end

@implementation SPDFMacProgressiveSearch {
    NSUInteger _workerCount;
    std::atomic<NSUInteger> _nextPosition;
    std::atomic<bool> _cancelled;
    os_unfair_lock _lock;
    NSMutableArray<SPDFMacSearchPageResult*>* _pending;  // guarded by _lock
    NSString* _error;                                    // guarded by _lock
    BOOL _flushScheduled;                                // guarded by _lock
    CFTimeInterval _lastFlush;                           // main thread
    void (^_results)(NSArray<SPDFMacSearchPageResult*>*);
    void (^_completion)(NSString*);
}

+ (NSUInteger)workerCountForPageCount:(NSUInteger)pageCount {
    NSUInteger processors = MAX((NSUInteger)1, NSProcessInfo.processInfo.activeProcessorCount);
    return MAX((NSUInteger)1, MIN(MIN(processors, (NSUInteger)4), pageCount / 8));
}

- (instancetype)initWithPageCount:(NSUInteger)pageCount firstPage:(NSUInteger)firstPage workerCount:(NSUInteger)workerCount {
    self = [super init];
    if (!self) return nil;
    _pageCount = pageCount;
    _firstPage = pageCount ? MIN(firstPage, pageCount - 1) : 0;
    _workerCount = MAX((NSUInteger)1, MIN(workerCount, MAX(pageCount, (NSUInteger)1)));
    _nextPosition = 0;
    _cancelled = false;
    _lock = OS_UNFAIR_LOCK_INIT;
    _pending = [NSMutableArray array];
    return self;
}

- (BOOL)isCancelled {
    return _cancelled.load();
}

- (void)cancel {
    _cancelled = true;
    _results = nil;
    _completion = nil;
}

- (void)startWithContext:(id (^)(NSString**))makeContext
              searchPage:(id (^)(id, NSUInteger, NSString**))searchPage
            closeContext:(void (^)(id))closeContext
                 results:(void (^)(NSArray<SPDFMacSearchPageResult*>*))results
              completion:(void (^)(NSString*))completion {
    NSAssert(NSThread.isMainThread, @"Searches start on the main thread");
    _results = [results copy];
    _completion = [completion copy];
    NSUInteger pageCount = _pageCount, firstPage = _firstPage, workers = _workerCount;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_async(_startQueue ?: queue, ^{
      dispatch_apply(workers, queue, ^(size_t worker) {
        (void)worker;
        if (self->_cancelled) return;
        NSString* error = nil;
        id context = nil;
        @autoreleasepool {
            context = makeContext(&error);
        }
        if (error) {
            [self stopWithError:error];
            return;
        }
        while (!self->_cancelled) {
            NSUInteger position = self->_nextPosition.fetch_add(1);
            if (position >= pageCount) break;
            NSUInteger page = (firstPage + position) % pageCount;
            @autoreleasepool {
                NSString* pageError = nil;
                id payload = searchPage(context, page, &pageError);
                if (pageError) {
                    [self stopWithError:pageError];
                    break;
                }
                if (self->_cancelled) break;
                [self deliver:[[SPDFMacSearchPageResult alloc] initWithPageIndex:page payload:payload]];
            }
        }
        if (closeContext) closeContext(context);
      });
      dispatch_async(dispatch_get_main_queue(), ^{
        [self finish];
      });
    });
}

- (void)stopWithError:(NSString*)error {
    os_unfair_lock_lock(&_lock);
    if (!_error) _error = [error copy];
    os_unfair_lock_unlock(&_lock);
    // Later pages stop; pages already searched are still delivered.
    _nextPosition = _pageCount;
}

- (void)deliver:(SPDFMacSearchPageResult*)result {
    os_unfair_lock_lock(&_lock);
    [_pending addObject:result];
    BOOL schedule = !_flushScheduled;
    _flushScheduled = YES;
    os_unfair_lock_unlock(&_lock);
    if (!schedule) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      CFTimeInterval wait = self->_lastFlush + 0.1 - CFAbsoluteTimeGetCurrent();
      if (wait <= 0) {
          [self flush];
          return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self flush];
      });
    });
}

- (void)flush {
    os_unfair_lock_lock(&_lock);
    NSArray<SPDFMacSearchPageResult*>* batch = [_pending copy];
    [_pending removeAllObjects];
    _flushScheduled = NO;
    os_unfair_lock_unlock(&_lock);
    _lastFlush = CFAbsoluteTimeGetCurrent();
    if (!batch.count || _finished || _cancelled) return;
    _pagesSearched += batch.count;
    void (^results)(NSArray<SPDFMacSearchPageResult*>*) = _results;
    if (results) results(batch);
}

- (void)finish {
    if (_cancelled) return;
    [self flush];
    if (_cancelled) return;  // a results handler may cancel
    _finished = YES;
    os_unfair_lock_lock(&_lock);
    NSString* error = _error;
    os_unfair_lock_unlock(&_lock);
    void (^completion)(NSString*) = _completion;
    _results = nil;
    _completion = nil;
    if (completion) completion(error);
}

@end
