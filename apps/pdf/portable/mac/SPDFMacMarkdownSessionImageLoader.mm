#import "SPDFMacMarkdownSessionImageLoader.h"

#import "SPDFMacMarkdownCache.h"

static const NSUInteger SPDFMacMarkdownImageMaximumBytes = 20 * 1024 * 1024;
static const NSTimeInterval SPDFMacMarkdownImageRequestTimeout = 20.0;
static const NSUInteger SPDFMacMarkdownImageMaximumConcurrentFetches = 4;

#pragma mark - Default NSURLSession fetcher

// One task's accumulation state; delegate callbacks arrive on the session's
// serial delegate queue.
@interface SPDFMacMarkdownImageFetchState : NSObject
@property(nonatomic) NSMutableData* buffer;
@property(nonatomic, copy) SPDFMacMarkdownImageFetchCompletion completion;
@property(nonatomic) BOOL rejected;
@end
@implementation SPDFMacMarkdownImageFetchState
@end

// Shared delegate-based transport enforcing the safety contract the header
// documents: https-only redirects, image/* content type, HTTP 200, and the
// 20 MB per-image cap checked while bytes stream in.
@interface SPDFMacMarkdownImageURLFetcher : NSObject <NSURLSessionDataDelegate>
+ (instancetype)sharedFetcher;
- (void)fetchURL:(NSURL*)URL completion:(SPDFMacMarkdownImageFetchCompletion)completion;
@end

@implementation SPDFMacMarkdownImageURLFetcher {
    NSURLSession* _session;
    NSMutableDictionary<NSNumber*, SPDFMacMarkdownImageFetchState*>* _states;
}

+ (instancetype)sharedFetcher {
    static SPDFMacMarkdownImageURLFetcher* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      shared = [SPDFMacMarkdownImageURLFetcher new];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.URLCredentialStorage = nil;
    configuration.URLCache = nil;
    configuration.timeoutIntervalForRequest = SPDFMacMarkdownImageRequestTimeout;
    configuration.timeoutIntervalForResource = 3 * SPDFMacMarkdownImageRequestTimeout;
    configuration.HTTPAdditionalHeaders = @{@"User-Agent": @"ShenzhenPDF Markdown Reader"};
    NSOperationQueue* delegateQueue = [NSOperationQueue new];
    delegateQueue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    _states = [NSMutableDictionary dictionary];
    return self;
}

- (void)fetchURL:(NSURL*)URL completion:(SPDFMacMarkdownImageFetchCompletion)completion {
    NSURLSessionDataTask* task = [_session dataTaskWithURL:URL];
    SPDFMacMarkdownImageFetchState* state = [SPDFMacMarkdownImageFetchState new];
    state.buffer = [NSMutableData data];
    state.completion = completion;
    [_session.delegateQueue addOperationWithBlock:^{
      self->_states[@(task.taskIdentifier)] = state;
      [task resume];
    }];
}

- (void)URLSession:(NSURLSession*)session
                          task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response
                    newRequest:(NSURLRequest*)request
             completionHandler:(void (^)(NSURLRequest*))completionHandler {
    (void)session;
    (void)task;
    (void)response;
    BOOL secure = [request.URL.scheme.lowercaseString isEqualToString:@"https"];
    completionHandler(secure ? request : nil);
}

- (void)URLSession:(NSURLSession*)session
              dataTask:(NSURLSessionDataTask*)dataTask
    didReceiveResponse:(NSURLResponse*)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    SPDFMacMarkdownImageFetchState* state = _states[@(dataTask.taskIdentifier)];
    NSHTTPURLResponse* HTTPResponse =
        [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse*)response : nil;
    BOOL image = [response.MIMEType.lowercaseString hasPrefix:@"image/"];
    BOOL sized = response.expectedContentLength == NSURLResponseUnknownLength ||
                 response.expectedContentLength <= (long long)SPDFMacMarkdownImageMaximumBytes;
    if (HTTPResponse.statusCode == 200 && image && sized) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    state.rejected = YES;
    completionHandler(NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession*)session
          dataTask:(NSURLSessionDataTask*)dataTask
    didReceiveData:(NSData*)data {
    (void)session;
    SPDFMacMarkdownImageFetchState* state = _states[@(dataTask.taskIdentifier)];
    if (!state || state.rejected) return;
    if (state.buffer.length + data.length > SPDFMacMarkdownImageMaximumBytes) {
        state.rejected = YES;
        [dataTask cancel];
        return;
    }
    [state.buffer appendData:data];
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
    (void)session;
    NSNumber* key = @(task.taskIdentifier);
    SPDFMacMarkdownImageFetchState* state = _states[key];
    [_states removeObjectForKey:key];
    if (!state.completion) return;
    NSData* data = !error && !state.rejected && state.buffer.length ? state.buffer : nil;
    state.completion(data);
}

@end

#pragma mark - Loader

@implementation SPDFMacMarkdownSessionImageLoader {
    NSURL* _cacheDirectory;
    NSMutableDictionary<NSString*, NSData*>* _loaded;
    NSMutableSet<NSString*>* _failed;
    // Every target currently being resolved (disk probe or network fetch).
    NSMutableSet<NSString*>* _outstanding;
    // Targets waiting for one of the 4 network slots, in request order.
    NSMutableArray<NSString*>* _queue;
    // Bumped by cancelQueuedRequests so disk probes already in flight cannot
    // enqueue a network fetch for a session that went inactive meanwhile.
    NSUInteger _queueGeneration;
    NSUInteger _activeFetches;
    BOOL _dirty;
    NSTimer* _updateTimer;
    dispatch_queue_t _diskQueue;
}

- (instancetype)init {
    return [self initWithCacheDirectory:nil];
}

- (instancetype)initWithCacheDirectory:(NSURL*)cacheDirectory {
    self = [super init];
    if (!self) return nil;
    _cacheDirectory = cacheDirectory ?: spdf_mac_markdown_image_cache_directory();
    _loaded = [NSMutableDictionary dictionary];
    _failed = [NSMutableSet set];
    _outstanding = [NSMutableSet set];
    _queue = [NSMutableArray array];
    _coalescingInterval = 0.3;
    _diskQueue = dispatch_queue_create("com.intuition.shenzhenpdf.markdown-images", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    [_updateTimer invalidate];
}

- (NSDictionary<NSString*, NSData*>*)loadedImageData {
    return [_loaded copy];
}
- (NSSet<NSString*>*)failedTargets {
    return [_failed copy];
}
- (NSUInteger)outstandingRequestCount {
    return _outstanding.count;
}

- (void)requestTargets:(NSArray<NSString*>*)targets {
    NSAssert(NSThread.isMainThread, @"Markdown image loading is main-thread confined");
    for (NSString* target in targets) {
        if (!target.length || _loaded[target] || [_failed containsObject:target] ||
            [_outstanding containsObject:target])
            continue;
        [_outstanding addObject:target];
        NSURL* directory = _cacheDirectory;
        NSUInteger queueGeneration = _queueGeneration;
        dispatch_async(_diskQueue, ^{
          NSData* cached = spdf_mac_markdown_image_cache_read(directory, target);
          dispatch_async(dispatch_get_main_queue(), ^{
            if (![self->_outstanding containsObject:target]) return;
            if (cached) {
                [self finishTarget:target withData:cached];
            } else if (queueGeneration != self->_queueGeneration) {
                [self->_outstanding removeObject:target];
            } else {
                [self->_queue addObject:target];
                [self pumpFetchQueue];
            }
          });
        });
    }
}

- (void)cancelQueuedRequests {
    NSAssert(NSThread.isMainThread, @"Markdown image loading is main-thread confined");
    ++_queueGeneration;
    for (NSString* target in _queue) [_outstanding removeObject:target];
    [_queue removeAllObjects];
}

- (void)pumpFetchQueue {
    while (_activeFetches < SPDFMacMarkdownImageMaximumConcurrentFetches && _queue.count) {
        NSString* target = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        NSURL* URL = [NSURL URLWithString:target];
        if (!URL) {
            [self finishTarget:target withData:nil];
            continue;
        }
        ++_activeFetches;
        ++_networkFetchCount;
        SPDFMacMarkdownImageFetcher fetcher = self.fetcher ?: ^(NSURL* fetchURL,
                                                                SPDFMacMarkdownImageFetchCompletion completion) {
          [SPDFMacMarkdownImageURLFetcher.sharedFetcher fetchURL:fetchURL completion:completion];
        };
        __weak SPDFMacMarkdownSessionImageLoader* weakSelf = self;
        fetcher(URL, ^(NSData* data) {
          dispatch_async(dispatch_get_main_queue(), ^{
            SPDFMacMarkdownSessionImageLoader* strongSelf = weakSelf;
            if (!strongSelf) return;
            --strongSelf->_activeFetches;
            [strongSelf finishTarget:target withData:data];
            [strongSelf pumpFetchQueue];
          });
        });
    }
}

// Records one settled target (nil data = permanent failure for this loader)
// and schedules the coalesced notification. Network successes are persisted
// to the LRU disk cache off the main thread.
- (void)finishTarget:(NSString*)target withData:(NSData*)data {
    if (![_outstanding containsObject:target]) return;
    [_outstanding removeObject:target];
    if (data.length && data.length <= SPDFMacMarkdownImageMaximumBytes) {
        _loaded[target] = data;
        NSURL* directory = _cacheDirectory;
        dispatch_async(_diskQueue, ^{
          if (!spdf_mac_markdown_image_cache_read(directory, target)) {
              spdf_mac_markdown_image_cache_write(directory, target, data);
              spdf_mac_markdown_image_cache_trim(directory, spdf_mac_markdown_image_cache_maximum_bytes());
          }
        });
    } else {
        [_failed addObject:target];
    }
    _dirty = YES;
    [self scheduleUpdateNotification];
}

// At most one notification per coalescing interval while work is landing; the
// final arrival of a batch notifies immediately (next main-queue turn, so
// several synchronous completions still collapse into one).
- (void)scheduleUpdateNotification {
    if (!_dirty) return;
    if (_outstanding.count == 0) {
        [_updateTimer invalidate];
        _updateTimer = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
          [self deliverUpdateNotification];
        });
        return;
    }
    if (_updateTimer) return;
    __weak SPDFMacMarkdownSessionImageLoader* weakSelf = self;
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(0.05, _coalescingInterval)
                                                   repeats:NO
                                                     block:^(NSTimer* timer) {
                                                       (void)timer;
                                                       SPDFMacMarkdownSessionImageLoader* strongSelf = weakSelf;
                                                       if (!strongSelf) return;
                                                       strongSelf->_updateTimer = nil;
                                                       [strongSelf deliverUpdateNotification];
                                                     }];
}

- (void)deliverUpdateNotification {
    if (!_dirty) return;
    _dirty = NO;
    if (self.imagesUpdatedHandler) self.imagesUpdatedHandler();
}

@end
