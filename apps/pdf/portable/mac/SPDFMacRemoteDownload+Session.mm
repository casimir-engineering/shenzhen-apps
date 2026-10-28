// SPDFMacRemoteDownload's URL session answers, telling the reader, and finishing (SPDFMacRemoteDownload.h).

#import "SPDFMacRemoteDownloadPrivate.h"

#include "spdf_link.h"

#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <fcntl.h>

@implementation SPDFMacRemoteDownload (Session)

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession*)session
                          task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response
                    newRequest:(NSURLRequest*)request
             completionHandler:(void (^)(NSURLRequest* _Nullable))completionHandler {
    (void)session, (void)task, (void)response;
    // A redirect may only lead where a link itself could: https, or http on this computer.
    completionHandler(SPDFMacRemoteAddressAllowed(request.URL) ? request : nil);
}

- (void)URLSession:(NSURLSession*)session
              dataTask:(NSURLSessionDataTask*)dataTask
    didReceiveResponse:(NSURLResponse*)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    SPDFMacRemoteRequest* record = [self recordForTask:dataTask];
    NSHTTPURLResponse* http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse*)response : nil;
    if (!record || _done || !http) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSInteger status = http.statusCode;
    _qStatus = status;
    if (status >= 300 && status < 400) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureInsecureRedirect notify:YES];
    } else if (status == 404 || status == 410) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureNotFound notify:YES];
    } else if (status == 401 || status == 403) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureForbidden notify:YES];
    } else if (status != 200 && status != 206) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureServer notify:YES];
    } else if (record.probe) {
        [self acceptFirstResponse:http record:record];
    } else if (status != 206 || ![self contentRangeOf:http matches:record]) {
        // Ranges worked a moment ago: the file changed on the server, or a proxy stopped passing them on. Starting
        // again from the beginning, in one stream, is the one answer that is right either way.
        [self restartAsOneStream];
    }
    completionHandler(_done || ![_requests containsObject:record] ? NSURLSessionResponseCancel
                                                                   : NSURLSessionResponseAllow);
}

- (BOOL)contentRangeOf:(NSHTTPURLResponse*)http matches:(SPDFMacRemoteRequest*)record {
    long long first = -1, last = -1, total = -1;
    NSString* range = [http valueForHTTPHeaderField:@"Content-Range"];
    if (sscanf(range.UTF8String ?: "", "bytes %lld-%lld/%lld", &first, &last, &total) != 3) return NO;
    return first == record.start && last >= first && total == _qLength;
}

- (void)acceptFirstResponse:(NSHTTPURLResponse*)http record:(SPDFMacRemoteRequest*)record {
    _fetchURL = http.URL ?: _fetchURL;
    _validator = [http valueForHTTPHeaderField:@"ETag"] ?: [http valueForHTTPHeaderField:@"Last-Modified"];
    long long first = -1, last = -1, total = -1;
    NSString* range = [http valueForHTTPHeaderField:@"Content-Range"];
    if (http.statusCode == 206 &&
        sscanf(range.UTF8String ?: "", "bytes %lld-%lld/%lld", &first, &last, &total) == 3 && first == 0) {
        _ranged = YES;
        _qLength = total;
    } else {
        _ranged = NO;
        _qLength = http.expectedContentLength; // -1 when the server does not say
        record.end = _qLength > 0 ? _qLength : INT64_MAX;
    }
    record.probe = NO;
    if (_qLength > kMaxDocumentBytes) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureTooLarge notify:YES];
        return;
    }
    if (_qLength == 0) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureNotPDF notify:YES];
        return;
    }
    if (_qLength > 0 && _progressive) {
        if (![self prepareFileWithLength:_qLength resumeRanges:_ranged ? _resumeRanges : nil]) {
            [self finishWithFailure:SPDFMacRemoteDownloadFailureDisk notify:YES];
            return;
        }
        if (_ranged && spdf_progressive_has(_source, 0, MIN(_qLength, kFirstRequestBytes))) {
            // Carrying on: the start is already here, so this request's bytes go to what is still missing.
            record.withdrawn = YES;
            [record.task cancel];
            [self checkStartIfArrived];
        }
        [self pump];
    } else {
        // Not read while it downloads (another type, or a PDF of unknown length): the file holds exactly the bytes
        // that came, in order, so a Markdown or text tab shows what has arrived each time it rereads the file.
        _fd = open(self.path.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (_fd < 0) {
            [self finishWithFailure:SPDFMacRemoteDownloadFailureDisk notify:YES];
            return;
        }
        [self writeSidecar];
    }
    [self scheduleNotify];
}

- (void)restartAsOneStream {
    for (SPDFMacRemoteRequest* record in [_requests copy]) {
        record.withdrawn = YES;
        [record.task cancel];
    }
    [_requests removeAllObjects];
    [_wants removeAllObjects];
    if (_source) spdf_progressive_unregister(_source);
    _source = NULL;
    if (_fd >= 0) close(_fd);
    _fd = -1;
    _ranged = NO;
    _validator = nil;
    _resumeRanges = nil;
    _checkedStart = NO;
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:_fetchURL];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    SPDFMacRemoteRequest* record = [SPDFMacRemoteRequest new];
    record.probe = YES;
    record.end = INT64_MAX;
    record.attempt = 1; // a dropped stream cannot pick up where it stopped
    record.task = [_session dataTaskWithRequest:request];
    [_requests addObject:record];
    [record.task resume];
}

- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)dataTask didReceiveData:(NSData*)data {
    (void)session;
    SPDFMacRemoteRequest* record = [self recordForTask:dataTask];
    if (!record || record.withdrawn || _done || _fd < 0) return;
    int64_t offset = record.next;
    NSData* bytes = data;
    if (_qLength > 0 && offset + (int64_t)bytes.length > _qLength)
        bytes = [data subdataWithRange:NSMakeRange(0, (NSUInteger)MAX((int64_t)0, _qLength - offset))];
    if (![self writeBytes:bytes at:offset]) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureDisk notify:YES];
        return;
    }
    record.next = offset + (int64_t)bytes.length;
    if (_source) spdf_progressive_add(_source, offset, (int64_t)bytes.length);
    _qReceived = _source ? spdf_progressive_received(_source) : record.next;
    if (![self checkStartIfArrived] ||
        (_progressive && !_source && !_checkedStart && _qReceived >= 1024 && ![self streamLooksLikePDF])) {
        [self finishWithFailure:SPDFMacRemoteDownloadFailureNotPDF notify:YES];
        return;
    }
    if (_source && CFAbsoluteTimeGetCurrent() - _lastSidecar > 1.0) [self writeSidecar];
    [self scheduleNotify];
}

- (BOOL)streamLooksLikePDF {
    _checkedStart = YES;
    char head[1024];
    if (pread(_fd, head, sizeof head, 0) != (ssize_t)sizeof head) return NO;
    for (size_t i = 0; i + 5 <= sizeof head; ++i)
        if (memcmp(head + i, "%PDF-", 5) == 0) return YES;
    return NO;
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
    (void)session;
    SPDFMacRemoteRequest* record = [self recordForTask:task];
    if (!record) return;
    [_requests removeObject:record];
    if (_done) return;
    if (record.withdrawn) {
        [self pump];
        return;
    }
    if (error) {
        BOOL certificate = error.code <= NSURLErrorSecureConnectionFailed && error.code >= NSURLErrorClientCertificateRequired;
        BOOL redirect = error.code == NSURLErrorCancelled && record.next == record.start;
        if (redirect && _qStatus >= 300 && _qStatus < 400) {
            [self finishWithFailure:SPDFMacRemoteDownloadFailureInsecureRedirect notify:YES];
            return;
        }
        // One more try from where it stopped: a dropped connection on a long download is not the end of it.
        if (!certificate && record.attempt < 2 && (_ranged || (record.probe && _progressive && record.next == 0))) {
            SPDFMacRemoteRequest* again = [self requestFrom:record.next to:record.end == INT64_MAX ? kFirstRequestBytes
                                                                                                     : record.end
                                                      fill:record.fill];
            again.probe = record.probe;
            again.attempt = record.attempt + 1;
            return;
        }
        [self finishWithFailure:certificate ? SPDFMacRemoteDownloadFailureCertificate : SPDFMacRemoteDownloadFailureNetwork
                         notify:YES];
        return;
    }
    if (!_ranged) {
        // The whole file in one stream: done when it ends (and complete only when it brought every byte).
        BOOL complete = _qLength < 0 || record.next >= _qLength;
        if (_qLength < 0) _qLength = record.next;
        if (_progressive && !_checkedStart && ![self streamLooksLikePDF]) {
            complete = NO;
            _qFailure = SPDFMacRemoteDownloadFailureNotPDF;
        }
        SPDFMacRemoteDownloadFailure failure =
            complete ? SPDFMacRemoteDownloadFailureNone
                     : (_qFailure != SPDFMacRemoteDownloadFailureNone ? _qFailure : SPDFMacRemoteDownloadFailureNetwork);
        [self finishWithFailure:failure notify:YES];
        return;
    }
    [self pump];
}

#pragma mark - Telling the reader

- (void)scheduleNotify {
    if (_notifyScheduled) return;
    _notifyScheduled = YES;
    double wait = MAX(0.0, 0.08 - (CFAbsoluteTimeGetCurrent() - _lastNotify));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), _queue, ^{
        self->_notifyScheduled = NO;
        self->_lastNotify = CFAbsoluteTimeGetCurrent();
        [self publishFinished:NO];
    });
}

- (void)publishFinished:(BOOL)finished {
    int64_t length = _qLength, received = _qReceived;
    SPDFMacRemoteDownloadFailure failure = _qFailure;
    NSInteger status = _qStatus;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished) return; // a progress note that crossed the finish
        self.length = length;
        self.received = received;
        self.httpStatus = status;
        if (finished) {
            self.finished = YES;
            self.failure = failure;
            [self.delegate remoteDownloadDidFinish:self];
        } else {
            [self.delegate remoteDownloadDidProgress:self];
        }
    });
}

- (void)finishWithFailure:(SPDFMacRemoteDownloadFailure)failure notify:(BOOL)notify {
    if (_done) return;
    _done = YES;
    _qFailure = failure;
    for (SPDFMacRemoteRequest* record in _requests) [record.task cancel];
    [_requests removeAllObjects];
    [_session invalidateAndCancel]; // the session holds its delegate until invalidated
    NSFileManager* files = NSFileManager.defaultManager;
    NSString* sidecar = [SPDFMacRemoteDownload sidecarForPath:self.path];
    if (failure == SPDFMacRemoteDownloadFailureNone) {
        // Complete: the file is an ordinary document from here on. Its date moves to now, which is also what tells
        // the reader's file watcher (and the Collection) that it changed, and it remembers where it came from.
        if (_fd >= 0) {
            fsync(_fd);
            struct timespec times[2] = {{0, UTIME_OMIT}, {0, UTIME_NOW}};
            futimens(_fd, times);
            NSData* from = [NSPropertyListSerialization dataWithPropertyList:@[ self.url.absoluteString ]
                                                                      format:NSPropertyListBinaryFormat_v1_0
                                                                     options:0
                                                                       error:nil];
            if (from) fsetxattr(_fd, "com.apple.metadata:kMDItemWhereFroms", from.bytes, from.length, 0, 0);
        }
        [files removeItemAtPath:sidecar error:nil];
        _qReceived = _qLength;
    } else if (_fd < 0 && !_source) {
        // Nothing arrived (the server never answered): nothing to carry on from.
        [files removeItemAtPath:sidecar error:nil];
    } else if (failure == SPDFMacRemoteDownloadFailureNetwork || failure == SPDFMacRemoteDownloadFailureDisk) {
        // What arrived stays for the next try; reads of what did not now fail at once instead of waiting.
        [self writeSidecar];
        if (_source) spdf_progressive_stop(_source);
    } else {
        // Nothing here is the document the link named: leave nothing behind.
        if (_source) spdf_progressive_unregister(_source);
        _source = NULL;
        [files removeItemAtPath:sidecar error:nil];
        if (_fd >= 0) [files removeItemAtPath:self.path error:nil];
    }
    if (failure == SPDFMacRemoteDownloadFailureNone && _source) {
        spdf_progressive_unregister(_source);
        _source = NULL;
    }
    if (_fd >= 0) close(_fd);
    _fd = -1;
    rmdir(self.path.stringByDeletingLastPathComponent.fileSystemRepresentation); // only when nothing is left in it
    if (notify) [self publishFinished:YES];
}

@end
