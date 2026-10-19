#import "SPDFMacFileWatcher.h"

#import <CoreServices/CoreServices.h>

#include <fcntl.h>
#include <unistd.h>

// Quiet window before a detected change is reported. A file mid-write tends to
// fire several vnode/FSEvents notifications; we coalesce them and only call the
// owner once the dust settles.
static const NSTimeInterval kSPDFFileWatcherDebounce = 0.4;

// Fallback polling cadence, used only when neither FSEvents nor a vnode source
// could be installed. Deliberately slow: the event paths are the norm.
static const NSTimeInterval kSPDFFileWatcherPollInterval = 1.5;

@implementation SPDFMacFileWatcher {
    NSString* _watchedPath;
    NSString* _watchedDirectory;     // standardized parent directory
    NSString* _watchedName;          // last path component (case-insensitive match)
    int _vnodeFD;                    // -1 when none
    dispatch_source_t _vnodeSource;  // nil when none
    FSEventStreamRef _eventStream;   // NULL when none
    NSTimer* _pollTimer;             // nil unless in fallback / poll-only mode
    NSTimer* _debounceTimer;         // nil when no pending coalesced fire
    BOOL _pollOnly;                  // YES: stat-poll only, never open/stream source
}

- (instancetype)init {
    if ((self = [super init])) {
        _vnodeFD = -1;
    }
    return self;
}

- (void)dealloc {
    [self teardownResources];
}

- (NSString*)watchedPath {
    return _watchedPath;
}

- (void)watchPath:(NSString*)path {
    [self watchPath:path pollOnly:NO];
}

- (void)watchPath:(NSString*)path pollOnly:(BOOL)pollOnly {
    NSString* standardized = path.length ? (path.stringByStandardizingPath ?: path) : nil;

    // No-op if already watching this exact path in the same mode and the watch is
    // still live. (Mode must match: a switch between event and poll-only watching
    // must re-arm.)
    if (standardized && [standardized isEqualToString:_watchedPath] && pollOnly == _pollOnly &&
        (_eventStream || _vnodeSource || _pollTimer)) {
        return;
    }

    [self teardownResources];
    _pollOnly = pollOnly;

    if (!standardized.length) {
        _watchedPath = nil;
        _watchedDirectory = nil;
        _watchedName = nil;
        return;
    }

    _watchedPath = [standardized copy];
    _watchedDirectory = [standardized.stringByDeletingLastPathComponent copy];
    _watchedName = [standardized.lastPathComponent copy];

    if (pollOnly) {
        // Read-only source: NEVER open an FSEvents stream nor an O_EVTONLY vnode
        // fd on it (either can re-trigger the macOS prompt). Stat-based polling
        // only — it reads metadata, never the file content.
        [self startPollTimer];
        return;
    }

    BOOL eventStreamStarted = [self startEventStream];
    BOOL vnodeStarted = [self startVnodeSource];

    // Only fall back to polling if neither event mechanism came up. FSEvents
    // alone is sufficient and robust to atomic saves; the vnode source is a
    // latency optimization for in-place writes.
    if (!eventStreamStarted && !vnodeStarted) {
        [self startPollTimer];
    }
}

- (void)stop {
    [self teardownResources];
    _watchedPath = nil;
    _watchedDirectory = nil;
    _watchedName = nil;
    _pollOnly = NO;
}

#pragma mark - FSEvents (parent directory)

static void SPDFFileWatcherEventCallback(ConstFSEventStreamRef streamRef,
                                         void* clientCallBackInfo,
                                         size_t numEvents,
                                         void* eventPaths,
                                         const FSEventStreamEventFlags eventFlags[],
                                         const FSEventStreamEventId eventIds[]) {
    (void)streamRef;
    (void)numEvents;
    (void)eventPaths;
    (void)eventFlags;
    (void)eventIds;
    SPDFMacFileWatcher* watcher = (__bridge SPDFMacFileWatcher*)clientCallBackInfo;
    // Delivered on the main dispatch queue (set below). Any event under the
    // parent directory is a cheap candidate; the debounced owner callback does
    // the precise filename + mtime/size check, so we do not need to scrutinize
    // the reported paths here.
    [watcher handleCandidateChange];
}

- (BOOL)startEventStream {
    if (!_watchedDirectory.length) return NO;

    FSEventStreamContext context = {0, (__bridge void*)self, NULL, NULL, NULL};
    NSArray<NSString*>* pathsToWatch = @[ _watchedDirectory ];
    FSEventStreamCreateFlags flags =
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot;

    _eventStream = FSEventStreamCreate(kCFAllocatorDefault, &SPDFFileWatcherEventCallback, &context,
                                       (__bridge CFArrayRef)pathsToWatch, kFSEventStreamEventIdSinceNow,
                                       (CFAbsoluteTime)0.1 /* latency seconds */, flags);
    if (!_eventStream) return NO;

    // Deliver callbacks on the main queue so the owner's mtime/size check and
    // any reload run on the main thread, matching the rest of the UI code.
    FSEventStreamSetDispatchQueue(_eventStream, dispatch_get_main_queue());
    if (!FSEventStreamStart(_eventStream)) {
        FSEventStreamInvalidate(_eventStream);
        FSEventStreamRelease(_eventStream);
        _eventStream = NULL;
        return NO;
    }
    return YES;
}

#pragma mark - GCD vnode source (in-place writes)

- (BOOL)startVnodeSource {
    if (!_watchedPath.length) return NO;

    int fd = open(_watchedPath.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return NO;

    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
            DISPATCH_VNODE_LINK | DISPATCH_VNODE_REVOKE,
        dispatch_get_main_queue());
    if (!source) {
        close(fd);
        return NO;
    }

    __weak SPDFMacFileWatcher* weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
      SPDFMacFileWatcher* strongSelf = weakSelf;
      if (!strongSelf) return;
      unsigned long flags = dispatch_source_get_data(source);
      // A delete/rename/revoke invalidates this fd (atomic save replaces the
      // inode). Tear the source down so we stop firing on a dead fd; the
      // FSEvents path keeps watching the directory and will catch the
      // replacement. If FSEvents is not running, re-point to recreate it.
      if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
          [strongSelf vnodeSourceInvalidated];
      }
      [strongSelf handleCandidateChange];
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });

    _vnodeFD = fd;
    _vnodeSource = source;
    dispatch_resume(source);
    return YES;
}

- (void)vnodeSourceInvalidated {
    // Cancel the (now stale) vnode source; its cancel handler closes the fd.
    if (_vnodeSource) {
        dispatch_source_cancel(_vnodeSource);
        _vnodeSource = nil;
    }
    _vnodeFD = -1;

    // If FSEvents is up it will see the replacement file; nothing more to do.
    // Otherwise try to re-arm a fresh vnode source after a short delay so an
    // atomic replace re-establishes in-place-write coverage. Avoid tight loops
    // when the file is gone for good (handler is debounced + owner re-checks).
    if (_eventStream) return;

    NSString* pathAtInvalidation = [_watchedPath copy];
    __weak SPDFMacFileWatcher* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SPDFMacFileWatcher* strongSelf = weakSelf;
      if (!strongSelf) return;
      if (![pathAtInvalidation isEqualToString:strongSelf->_watchedPath]) return;
      if (strongSelf->_vnodeSource) return;
      if (![strongSelf startVnodeSource] && !strongSelf->_eventStream && !strongSelf->_pollTimer) {
          [strongSelf startPollTimer];
      }
    });
}

#pragma mark - Polling fallback

- (void)startPollTimer {
    if (_pollTimer) return;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:kSPDFFileWatcherPollInterval
                                                  target:self
                                                selector:@selector(pollTimerFired:)
                                                userInfo:nil
                                                 repeats:YES];
    _pollTimer.tolerance = kSPDFFileWatcherPollInterval * 0.5;
}

- (void)pollTimerFired:(NSTimer*)timer {
    (void)timer;
    // The owner does the real mtime/size comparison; the poll just nudges it.
    [self handleCandidateChange];
}

#pragma mark - Debounce + dispatch to owner

- (void)handleCandidateChange {
    [_debounceTimer invalidate];
    _debounceTimer = [NSTimer scheduledTimerWithTimeInterval:kSPDFFileWatcherDebounce
                                                      target:self
                                                    selector:@selector(debounceFired:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)debounceFired:(NSTimer*)timer {
    (void)timer;
    _debounceTimer = nil;
    NSString* path = [_watchedPath copy];
    if (!path.length) return;
    void (^handler)(NSString*) = self.changeHandler;
    if (handler) handler(path);
}

#pragma mark - Teardown

- (void)teardownResources {
    [_debounceTimer invalidate];
    _debounceTimer = nil;

    [_pollTimer invalidate];
    _pollTimer = nil;

    if (_eventStream) {
        FSEventStreamStop(_eventStream);
        FSEventStreamInvalidate(_eventStream);
        FSEventStreamRelease(_eventStream);
        _eventStream = NULL;
    }

    if (_vnodeSource) {
        dispatch_source_cancel(_vnodeSource);  // cancel handler closes the fd
        _vnodeSource = nil;
        _vnodeFD = -1;
    } else if (_vnodeFD >= 0) {
        close(_vnodeFD);
        _vnodeFD = -1;
    }
}

@end
