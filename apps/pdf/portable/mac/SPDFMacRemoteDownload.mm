// One linked document downloading into the file the reader opens (SPDFMacRemoteDownload.h).

#import "SPDFMacRemoteDownloadPrivate.h"

#include "spdf_link.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

@implementation SPDFMacRemoteRequest
@end

// What the core's want callback holds: never freed (one per download), so a worker thread that read the callback just
// before the download let go still finds a valid object, whose weak reference is then nil.
@interface SPDFMacRemoteWantBox : NSObject
@property(atomic, weak) SPDFMacRemoteDownload* download;
@end
@implementation SPDFMacRemoteWantBox
@end

static void SPDFMacRemoteWant(void* user, int64_t offset) {
    [((__bridge SPDFMacRemoteWantBox*)user).download queueWantAt:offset];
}

BOOL SPDFMacRemoteAddressAllowed(NSURL* url) {
    spdf_link link;
    NSString* text = [@"szpdf:" stringByAppendingString:url.absoluteString ?: @""];
    return spdf_link_parse(text.UTF8String, &link) == SPDF_LINK_OK;
}

@implementation SPDFMacRemoteDownload

- (instancetype)initWithURL:(NSURL*)url path:(NSString*)path {
    if ((self = [super init])) {
        _url = [url copy];
        _path = [path copy];
        _fetchURL = _url;
        _fd = -1;
        _length = -1;
        _qLength = -1;
        _queue = dispatch_queue_create("com.intuition.shenzhenpdf.remote-download", DISPATCH_QUEUE_SERIAL);
        _requests = [NSMutableArray array];
        _wants = [NSMutableArray array];
        _prefetch = [NSMutableArray array];
        _progressive = [path.pathExtension.lowercaseString isEqualToString:@"pdf"];
    }
    return self;
}

- (void)dealloc {
    if (_source) spdf_progressive_unregister(_source);
    if (_fd >= 0) close(_fd);
}

+ (NSString*)sidecarForPath:(NSString*)path {
    return [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:kSidecarName];
}

+ (BOOL)fileIsPartial:(NSString*)path {
    return [NSFileManager.defaultManager fileExistsAtPath:[self sidecarForPath:path]];
}

+ (NSURL*)sourceURLOfPartialFile:(NSString*)path {
    NSString* text = [NSString stringWithContentsOfFile:[self sidecarForPath:path] encoding:NSUTF8StringEncoding
                                                  error:nil];
    NSString* first = [text componentsSeparatedByString:@"\n"].firstObject;
    NSURL* url = first.length ? [NSURL URLWithString:first] : nil;
    return url && SPDFMacRemoteAddressAllowed(url) ? url : nil;
}

#pragma mark - Starting and stopping

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_started) return;
        self->_started = YES;
        [NSFileManager.defaultManager createDirectoryAtPath:self->_path.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        // A download this file stopped part way carries on: the sidecar names the address and what arrived.
        NSString* sidecar = [NSString stringWithContentsOfFile:[SPDFMacRemoteDownload sidecarForPath:self->_path]
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        NSRange newline = [sidecar rangeOfString:@"\n"];
        if (newline.location != NSNotFound &&
            [[sidecar substringToIndex:newline.location] isEqualToString:self->_url.absoluteString])
            self->_resumeRanges = [sidecar substringFromIndex:NSMaxRange(newline)];

        NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPMaximumConnectionsPerHost = (NSInteger)kMaxRequests + 1;
        configuration.timeoutIntervalForRequest = 30;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.URLCache = nil;
        NSOperationQueue* delegateQueue = [NSOperationQueue new];
        delegateQueue.underlyingQueue = self->_queue;
        delegateQueue.maxConcurrentOperationCount = 1;
        self->_session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];

        // A PDF's first request asks for the file's start as a range: the answer says whether ranges work and how
        // long the file is, and a server without ranges simply starts sending the whole file. Any other document
        // comes in one stream from the start, which is the order its reader needs it in.
        if (self->_progressive) [self requestFrom:0 to:kFirstRequestBytes fill:NO].probe = YES;
        else [self restartAsOneStream];
    });
}

- (void)prefetchOffsets:(NSArray<NSNumber*>*)offsets {
    NSArray<NSNumber*>* sorted = [offsets sortedArrayUsingSelector:@selector(compare:)];
    dispatch_async(_queue, ^{
        if (self->_done || !self->_ranged) return;
        [self->_prefetch setArray:sorted];
        [self pump];
    });
}

- (void)detach {
    dispatch_sync(_queue, ^{
        if (!self->_done) [self finishWithFailure:SPDFMacRemoteDownloadFailureNetwork notify:NO];
        if (self->_source) spdf_progressive_unregister(self->_source);
        self->_source = NULL;
    });
}

- (void)cancel {
    dispatch_async(_queue, ^{
        if (self->_done) return;
        [self finishWithFailure:SPDFMacRemoteDownloadFailureNetwork notify:NO];
    });
}

#pragma mark - Requests

- (SPDFMacRemoteRequest*)requestFrom:(int64_t)start to:(int64_t)end fill:(BOOL)fill {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:_fetchURL];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, end - 1] forHTTPHeaderField:@"Range"];
    // Offsets are the file's own bytes: a compressed transfer would number them differently.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (_validator.length) [request setValue:_validator forHTTPHeaderField:@"If-Range"];
    SPDFMacRemoteRequest* record = [SPDFMacRemoteRequest new];
    record.start = record.next = start;
    record.end = end;
    record.fill = fill;
    record.task = [_session dataTaskWithRequest:request];
    record.task.priority = fill ? NSURLSessionTaskPriorityLow : NSURLSessionTaskPriorityHigh;
    [_requests addObject:record];
    [record.task resume];
    return record;
}

- (SPDFMacRemoteRequest*)recordForTask:(NSURLSessionTask*)task {
    for (SPDFMacRemoteRequest* record in _requests)
        if (record.task == task) return record;
    return nil;
}

// The end of the bytes from `start` that are neither in the file nor on their way, capped at `limit`.
- (int64_t)uncoveredEndFrom:(int64_t)start limit:(int64_t)limit {
    int64_t end = MIN(limit, spdf_progressive_missing_end(_source, start));
    for (SPDFMacRemoteRequest* record in _requests)
        if (record.next > start && record.next < end) end = record.next;
    return end;
}

- (BOOL)coveredByRequest:(int64_t)offset {
    for (SPDFMacRemoteRequest* record in _requests)
        if (!record.withdrawn && record.next <= offset && offset < record.end) return YES;
    return NO;
}

- (void)queueWantAt:(int64_t)offset {
    dispatch_async(_queue, ^{
        if (self->_done || !self->_ranged || !self->_source) return;
        if (spdf_progressive_has(self->_source, offset, 1) || [self coveredByRequest:offset]) return;
        [self->_wants removeObject:@(offset)];
        [self->_wants addObject:@(offset)];
        if (self->_wants.count > kMaxWants) [self->_wants removeObjectAtIndex:0];
        // A page is waiting on these bytes: the fill gives way so they get the bandwidth (what it already wrote
        // stays, and it picks up from there later).
        for (SPDFMacRemoteRequest* record in [self->_requests copy]) {
            if (!record.fill || record.withdrawn) continue;
            record.withdrawn = YES;
            [record.task cancel];
        }
        [self pump];
    });
}

- (void)pump {
    if (_done || !_ranged || !_source) return;
    while (_requests.count < kMaxRequests) {
        int64_t start = -1, end = -1;
        BOOL fill = NO;
        while (_wants.count && start < 0) {
            int64_t offset = _wants.lastObject.longLongValue;
            [_wants removeLastObject];
            if (spdf_progressive_has(_source, offset, 1) || [self coveredByRequest:offset]) continue;
            start = offset;
            end = [self uncoveredEndFrom:start limit:MIN(_qLength, start + kWantBytes)];
        }
        // Page objects asked for ahead: each a few kilobytes, the ones close together in one request.
        while (start < 0 && _prefetch.count) {
            int64_t offset = _prefetch.firstObject.longLongValue;
            [_prefetch removeObjectAtIndex:0];
            if (spdf_progressive_has(_source, offset, kPrefetchBytes) || [self coveredByRequest:offset]) continue;
            start = spdf_progressive_next_missing(_source, offset);
            int64_t last = offset + kPrefetchBytes;
            while (_prefetch.count && _prefetch.firstObject.longLongValue < last + kPrefetchBytes &&
                   _prefetch.firstObject.longLongValue + kPrefetchBytes - start <= kWantBytes) {
                last = _prefetch.firstObject.longLongValue + kPrefetchBytes;
                [_prefetch removeObjectAtIndex:0];
            }
            end = [self uncoveredEndFrom:start limit:MIN(_qLength, last)];
            if (end <= start) start = -1;
        }
        if (start < 0) {
            // The fill runs only while nothing a page waits on is in flight: on a slow link two requests share the
            // bandwidth, and the page's must have all of it.
            NSUInteger fills = 0, others = 0;
            for (SPDFMacRemoteRequest* record in _requests) {
                if (record.withdrawn) continue;
                if (record.fill) ++fills;
                else ++others;
            }
            if (others || fills >= kMaxFillRequests || !_checkedStart) break;
            int64_t cursor = 0;
            while (cursor < _qLength) {
                int64_t missing = spdf_progressive_next_missing(_source, cursor);
                if (missing >= _qLength) break;
                SPDFMacRemoteRequest* covering = nil;
                for (SPDFMacRemoteRequest* record in _requests)
                    if (!record.withdrawn && record.next <= missing && missing < record.end) covering = record;
                if (!covering) {
                    start = missing;
                    break;
                }
                cursor = covering.end;
            }
            if (start < 0) break;
            end = [self uncoveredEndFrom:start limit:MIN(_qLength, start + kFillBytes)];
            fill = YES;
        }
        if (end <= start) break;
        [self requestFrom:start to:end fill:fill];
    }
    if (spdf_progressive_received(_source) >= _qLength && !_requests.count)
        [self finishWithFailure:SPDFMacRemoteDownloadFailureNone notify:YES];
}

#pragma mark - The file

- (BOOL)prepareFileWithLength:(int64_t)length resumeRanges:(NSString*)ranges {
    struct stat st;
    BOOL resume = ranges.length && spdf_progressive_ranges_text_length(ranges.UTF8String) == length &&
                  stat(_path.fileSystemRepresentation, &st) == 0 && st.st_size == length;
    _fd = open(_path.fileSystemRepresentation, O_RDWR | O_CREAT | (resume ? 0 : O_TRUNC) | O_CLOEXEC, 0644);
    if (_fd < 0 || ftruncate(_fd, length) != 0 || fstat(_fd, &st) != 0) return NO;
    _pinned = st.st_mtimespec;
    _source = spdf_progressive_register(_path.fileSystemRepresentation, length, SPDFMacRemoteWant,
                                        (__bridge void*)[self wantBox]);
    if (!_source) return NO;
    if (resume) spdf_progressive_add_ranges_text(_source, ranges.UTF8String);
    [self writeSidecar];
    return YES;
}

- (SPDFMacRemoteWantBox*)wantBox {
    if (!_box) {
        _box = [SPDFMacRemoteWantBox new];
        _box.download = self;
        CFBridgingRetain(_box); // see SPDFMacRemoteWantBox
    }
    return _box;
}

- (BOOL)writeBytes:(NSData*)data at:(int64_t)offset {
    __block BOOL ok = YES;
    [data enumerateByteRangesUsingBlock:^(const void* bytes, NSRange range, BOOL* stop) {
        const char* p = (const char*)bytes;
        size_t left = range.length;
        off_t at = offset + (off_t)range.location;
        while (left > 0) {
            ssize_t wrote = pwrite(self->_fd, p, left, at);
            if (wrote <= 0) {
                ok = NO;
                *stop = YES;
                return;
            }
            p += wrote;
            left -= (size_t)wrote;
            at += wrote;
        }
    }];
    // A PDF's modification date stays where it was while bytes arrive: the reader's file watcher compares it, and a
    // document reloading on every write would never settle (the download redraws its pages itself). A streamed
    // Markdown or text file is left to the watcher, which rereads it in place.
    if (_source) {
        struct timespec times[2] = {{0, UTIME_OMIT}, _pinned};
        futimens(_fd, times);
    }
    return ok;
}

- (void)writeSidecar {
    char* ranges = _source ? spdf_progressive_ranges_text(_source) : strdup("");
    if (!ranges) return;
    NSString* text = [NSString stringWithFormat:@"%@\n%s", _url.absoluteString, ranges];
    free(ranges);
    [text writeToFile:[SPDFMacRemoteDownload sidecarForPath:_path] atomically:YES encoding:NSUTF8StringEncoding
                error:nil];
    _lastSidecar = CFAbsoluteTimeGetCurrent();
}

// The start of the file: a PDF says so in its first kilobyte, and a linearized one says so right after.
- (BOOL)checkStartIfArrived {
    if (_checkedStart || !_source) return YES;
    int64_t needed = MIN(_qLength, (int64_t)1024);
    if (!spdf_progressive_has(_source, 0, needed)) return YES;
    _checkedStart = YES;
    char head[1025] = {0};
    if (pread(_fd, head, (size_t)needed, 0) != needed) return NO;
    BOOL pdf = NO, linearized = NO;
    for (int64_t i = 0; i + 5 <= needed; ++i) {
        if (!pdf && memcmp(head + i, "%PDF-", 5) == 0) pdf = YES;
        if (i + 11 <= needed && memcmp(head + i, "/Linearized", 11) == 0) linearized = YES;
    }
    if (!pdf) return NO;
    // Not linearized: nothing opens before the trailer and cross-reference table at the end, so they come next.
    if (!linearized && _ranged && _qLength > kFirstRequestBytes) {
        int64_t tail = MAX(kFirstRequestBytes, _qLength - kTailBytes);
        int64_t end = [self uncoveredEndFrom:tail limit:_qLength];
        if (end > tail) [self requestFrom:tail to:end fill:NO];
    }
    return YES;
}

@end
