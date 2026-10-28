// The downloader's private state, shared by SPDFMacRemoteDownload.mm (requests, scheduling, the file) and
// SPDFMacRemoteDownload+Session.mm (the URL session's answers, telling the reader, finishing).
#pragma once

#import "SPDFMacRemoteDownload.h"

// Sizes measured against a 2 Mbit/s link (docs/szpdf-links.md): a request for the bytes a page waits on is answered
// in about half a second, so a page needing three such round trips still shows within two; the fill behind it moves
// in 256 KB steps so a new request for a page never waits long for bandwidth.
static const int64_t kFirstRequestBytes = 64 * 1024;
static const int64_t kWantBytes = 128 * 1024;
static const int64_t kFillBytes = 256 * 1024;
static const int64_t kTailBytes = 64 * 1024;
static const int64_t kPrefetchBytes = 4 * 1024;
static const int64_t kMaxDocumentBytes = 2LL * 1024 * 1024 * 1024;
static const NSUInteger kMaxRequests = 3;
static const NSUInteger kMaxFillRequests = 2;
static const NSUInteger kMaxWants = 24;
static NSString* const kSidecarName = @".download";

// A request in flight: [start, end) asked for, `next` the byte it delivers next.
@interface SPDFMacRemoteRequest : NSObject
@property(nonatomic) NSURLSessionDataTask* task;
@property(nonatomic) int64_t start, next, end;
@property(nonatomic) BOOL fill, probe, withdrawn;
@property(nonatomic) NSInteger attempt;
@end

@class SPDFMacRemoteWantBox;

@interface SPDFMacRemoteDownload () {
  @package
    dispatch_queue_t _queue;
    NSURLSession* _session;
    NSURL* _fetchURL;
    int _fd;
    spdf_progressive* _source;
    SPDFMacRemoteWantBox* _box;
    int64_t _qLength, _qReceived;
    BOOL _ranged, _done, _started, _checkedStart;
    BOOL _progressive; // a PDF: read while it downloads; anything else is kept as it streams in and opens after
    NSString* _validator;
    NSMutableArray<SPDFMacRemoteRequest*>* _requests;
    NSMutableArray<NSNumber*>* _wants;
    NSMutableArray<NSNumber*>* _prefetch; // offsets, in file order
    struct timespec _pinned;
    CFAbsoluteTime _lastNotify, _lastSidecar;
    BOOL _notifyScheduled;
    NSString* _resumeRanges;
    SPDFMacRemoteDownloadFailure _qFailure;
    NSInteger _qStatus;
}
@property(nonatomic, readwrite) int64_t length;
@property(nonatomic, readwrite) int64_t received;
@property(nonatomic, readwrite) BOOL finished;
@property(nonatomic, readwrite) SPDFMacRemoteDownloadFailure failure;
@property(nonatomic, readwrite) NSInteger httpStatus;
+ (NSString*)sidecarForPath:(NSString*)path;
- (void)queueWantAt:(int64_t)offset;
- (SPDFMacRemoteRequest*)requestFrom:(int64_t)start to:(int64_t)end fill:(BOOL)fill;
- (SPDFMacRemoteRequest*)recordForTask:(NSURLSessionTask*)task;
- (void)pump;
- (BOOL)prepareFileWithLength:(int64_t)length resumeRanges:(NSString*)ranges;
- (BOOL)writeBytes:(NSData*)data at:(int64_t)offset;
- (void)writeSidecar;
- (BOOL)checkStartIfArrived;
@end

@interface SPDFMacRemoteDownload (Session) <NSURLSessionDataDelegate>
- (void)restartAsOneStream;
- (void)scheduleNotify;
- (void)finishWithFailure:(SPDFMacRemoteDownloadFailure)failure notify:(BOOL)notify;
@end

BOOL SPDFMacRemoteAddressAllowed(NSURL* url);
