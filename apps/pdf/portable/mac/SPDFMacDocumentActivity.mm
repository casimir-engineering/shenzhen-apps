// activity.yaml: the store half of SPDFMacDocumentActivity.h.
#import "SPDFMacDocumentActivity.h"
#import "SPDFMacStateDirectory.h"
#import <CoreServices/CoreServices.h>
#include "spdf_yaml.h"
#include <fcntl.h>
#include <os/lock.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSString* const SPDFDocumentActivityFileName = @"activity.yaml";
// Beyond this many documents the least recent are forgotten, so the file stays a few hundred kilobytes at most.
static const NSUInteger kActivityDocumentLimit = 5000;

static id ObjectFromYAMLFile(NSString* path) {
    NSMutableData* data = [[NSData dataWithContentsOfFile:path] mutableCopy];
    if (!data) return nil;
    [data appendBytes:"" length:1];
    char* json = spdf_json_from_yaml((const char*)data.bytes);
    if (!json) return nil;
    NSData* text = [NSData dataWithBytesNoCopy:json length:strlen(json) freeWhenDone:YES];
    return [NSJSONSerialization JSONObjectWithData:text options:NSJSONReadingMutableContainers error:nil];
}

static BOOL WriteYAMLFile(id object, NSString* path) {
    NSMutableData* json = [[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys
                                                             error:nil] mutableCopy];
    if (!json) return NO;
    [json appendBytes:"" length:1];
    char header[128];
    spdf_state_header_for_file(path.lastPathComponent.UTF8String, header, sizeof(header));
    char* yaml = spdf_yaml_from_json((const char*)json.bytes, header);
    if (!yaml) return NO;
    NSData* data = [NSData dataWithBytesNoCopy:yaml length:strlen(yaml) freeWhenDone:YES];
    if ([[NSData dataWithContentsOfFile:path] isEqualToData:data]) return YES;
    return [data writeToFile:path atomically:YES];
}

static NSTimeInterval SpotlightLastUsed(NSString* path) {
    MDItemRef item = MDItemCreate(kCFAllocatorDefault, (__bridge CFStringRef)path);
    if (!item) return 0;
    CFTypeRef value = MDItemCopyAttribute(item, kMDItemLastUsedDate);
    CFRelease(item);
    if (!value) return 0;
    NSTimeInterval result = CFGetTypeID(value) == CFDateGetTypeID()
        ? ((__bridge NSDate*)value).timeIntervalSince1970 : 0;
    CFRelease(value);
    return result;
}

static double Latest(NSDictionary* entry) {
    double latest = 0;
    for (NSDictionary* level in @[ entry ?: @{}, entry[@"estimate"] ?: @{} ])
        for (NSString* key in @[ @"opened", @"viewed", @"notViewedSince" ])
            latest = MAX(latest, [level[key] isKindOfClass:NSNumber.class] ? [level[key] doubleValue] : 0);
    return latest;
}

@implementation SPDFMacDocumentActivityStore {
    os_unfair_lock _lock;
    NSTimeInterval _createdAt;                                // this build has recorded real values since
    NSMutableDictionary<NSString*, NSDictionary*>* _pending; // under _lock: real values not yet written
    NSMutableSet<NSString*>* _forgotten;                      // under _lock: deleted; a view ending later is not kept
    BOOL _started, _flushScheduled;                          // under _lock
    dispatch_queue_t _queue;                                  // created at -start or the first query
    NSMutableDictionary* _file;                               // on _queue: activity.yaml as last read or written
    struct timespec _fileStamp;                               // on _queue
}

+ (instancetype)sharedStore {
    static SPDFMacDocumentActivityStore* store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] initWithDirectory:SPDFMacStateDirectoryPath()]; });
    return store;
}

- (instancetype)initWithDirectory:(NSString*)directory {
    if (!(self = [super init])) return nil;
    _directory = [directory copy];
    _createdAt = NSDate.date.timeIntervalSince1970;
    _lock = OS_UNFAIR_LOCK_INIT;
    _pending = [NSMutableDictionary dictionary];
    _flushDelay = 10;
    _lastUsedDate = ^NSTimeInterval(NSString* path) { return SpotlightLastUsed(path); };
    return self;
}

- (BOOL)hasQueue {
    os_unfair_lock_lock(&_lock);
    BOOL result = _queue != nil;
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (dispatch_queue_t)queue {
    os_unfair_lock_lock(&_lock);
    if (!_queue) _queue = dispatch_queue_create("ShenzhenPDF.document-activity",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_queue_t queue = _queue;
    os_unfair_lock_unlock(&_lock);
    return queue;
}

- (void)start {
    os_unfair_lock_lock(&_lock);
    BOOL first = !_started, pending = _pending.count > 0;
    _started = YES;
    os_unfair_lock_unlock(&_lock);
    if (first && pending) [self scheduleFlush];
}

- (void)record:(NSString*)key path:(NSString*)path at:(NSTimeInterval)time {
    if (!path.length || !isfinite(time) || time <= 0) return;
    NSString* standard = path.stringByStandardizingPath;
    os_unfair_lock_lock(&_lock);
    // A deleted document's tab stamps its view as it closes; a new open of that path counts again.
    if ([key isEqual:@"opened"]) [_forgotten removeObject:standard];
    if ([_forgotten containsObject:standard]) { os_unfair_lock_unlock(&_lock); return; }
    _pending[standard] = SPDFDocumentActivityMerge(_pending[standard], @{key : @(time)});
    BOOL schedule = _started && !_flushScheduled;
    os_unfair_lock_unlock(&_lock);
    if (schedule) [self scheduleFlush];
}
- (void)recordOpenedPath:(NSString*)path at:(NSTimeInterval)time { [self record:@"opened" path:path at:time]; }
- (void)recordViewedPath:(NSString*)path at:(NSTimeInterval)time { [self record:@"viewed" path:path at:time]; }

- (void)forgetPaths:(NSArray<NSString*>*)paths {
    NSMutableArray* standard = [NSMutableArray array];
    for (NSString* path in paths) if (path.length) [standard addObject:path.stringByStandardizingPath];
    os_unfair_lock_lock(&_lock);
    [_pending removeObjectsForKeys:standard];
    if (!_forgotten) _forgotten = [NSMutableSet set];
    [_forgotten addObjectsFromArray:standard];
    os_unfair_lock_unlock(&_lock);
    if (!standard.count || ![NSFileManager.defaultManager fileExistsAtPath:self.path]) return;
    // Waited for: a window whose last tab this closed ends its process right after.
    dispatch_sync([self queue], ^{
        int fd = open([self.directory stringByAppendingPathComponent:@"activity.lock"].fileSystemRepresentation,
                      O_CREAT | O_RDWR, 0600);
        if (fd >= 0) flock(fd, LOCK_EX);
        // Read as it is now, without the first-write backfill: forgetting must not invent anything.
        NSMutableDictionary* file = [ObjectFromYAMLFile(self.path) mutableCopy];
        NSMutableDictionary* documents = [file[@"documents"] isKindOfClass:NSDictionary.class] ? [file[@"documents"] mutableCopy] : nil;
        NSUInteger before = documents.count;
        [documents removeObjectsForKeys:standard];
        if (documents && documents.count != before) {
            file[@"documents"] = documents;
            if (WriteYAMLFile(file, self.path)) { _file = file; [self rememberFileStamp]; }
        }
        if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
    });
}

- (void)scheduleFlush {
    os_unfair_lock_lock(&_lock);
    if (_flushScheduled) { os_unfair_lock_unlock(&_lock); return; }
    _flushScheduled = YES;
    os_unfair_lock_unlock(&_lock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.flushDelay * NSEC_PER_SEC)), [self queue], ^{
        [self writePending];
    });
}

- (void)flushNow {
    dispatch_sync([self queue], ^{ [self writePending]; });
}

- (NSString*)path { return [self.directory stringByAppendingPathComponent:SPDFDocumentActivityFileName]; }

// On the queue, under activity.lock: the file as it is now, backfilled once.
- (NSMutableDictionary*)readFileForWrite:(BOOL*)changed {
    NSMutableDictionary* file = [ObjectFromYAMLFile(self.path) mutableCopy];
    if (![file isKindOfClass:NSMutableDictionary.class]) file = [NSMutableDictionary dictionary];
    if (![file[@"documents"] isKindOfClass:NSDictionary.class]) file[@"documents"] = [NSMutableDictionary dictionary];
    else file[@"documents"] = [file[@"documents"] mutableCopy];
    file[@"version"] = @1;
    if (!file[@"backfilledAt"]) {
        NSDictionary* sources = self.backfillSources ? self.backfillSources() : @{};
        id session = ObjectFromYAMLFile([self.directory stringByAppendingPathComponent:@"session.yaml"]);
        id settings = ObjectFromYAMLFile([self.directory stringByAppendingPathComponent:@"settings.yaml"]);
        id recents = [settings isKindOfClass:NSDictionary.class] ? settings[@"recentlyOpened"] : nil;
        NSDictionary* guesses = SPDFDocumentActivityBackfill([session isKindOfClass:NSDictionary.class] ? session : nil,
            sources[@"collection"], recents, self.lastUsedDate, MIN(_createdAt, [file[@"recordedSince"] doubleValue] ?: DBL_MAX));
        NSMutableDictionary* documents = file[@"documents"];
        for (NSString* path in guesses) documents[path] = SPDFDocumentActivityMerge(documents[path], guesses[path]);
        file[@"backfilledAt"] = @(round(NSDate.date.timeIntervalSince1970));
        *changed = YES;
    }
    return file;
}

- (void)writePending {
    os_unfair_lock_lock(&_lock);
    NSDictionary* pending = [_pending copy];
    [_pending removeAllObjects];
    _flushScheduled = NO;
    os_unfair_lock_unlock(&_lock);
    if (!pending.count && _file[@"backfilledAt"]) return;
    [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    NSString* lockPath = [self.directory stringByAppendingPathComponent:@"activity.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd >= 0) flock(fd, LOCK_EX);
    BOOL changed = NO;
    NSMutableDictionary* file = [self readFileForWrite:&changed];
    NSMutableDictionary* documents = file[@"documents"];
    for (NSString* path in pending) documents[path] = SPDFDocumentActivityMerge(documents[path], pending[path]);
    if (pending.count && ![file[@"recordedSince"] isKindOfClass:NSNumber.class]) {
        double first = DBL_MAX;
        for (NSDictionary* entry in pending.allValues)
            for (NSString* key in @[ @"opened", @"viewed" ])
                if ([entry[key] isKindOfClass:NSNumber.class]) first = MIN(first, [entry[key] doubleValue]);
        if (first < DBL_MAX) file[@"recordedSince"] = @(first);
    }
    if (documents.count > kActivityDocumentLimit) {
        NSArray* order = [documents keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
            return [@(Latest(b)) compare:@(Latest(a))];
        }];
        [documents removeObjectsForKeys:[order subarrayWithRange:NSMakeRange(kActivityDocumentLimit,
                                                                             order.count - kActivityDocumentLimit)]];
    }
    BOOL written = (!pending.count && !changed) || WriteYAMLFile(file, self.path);
    if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
    if (!written) {
        // Kept for the next try rather than lost: merged with anything recorded meanwhile.
        os_unfair_lock_lock(&_lock);
        for (NSString* path in pending) _pending[path] = SPDFDocumentActivityMerge(_pending[path], pending[path]);
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _file = file;
    [self rememberFileStamp];
}

- (void)rememberFileStamp {
    struct stat info = {};
    _fileStamp = stat(self.path.fileSystemRepresentation, &info) ? (struct timespec){} : info.st_mtimespec;
}

// On the queue: the file as another window's process may have left it.
- (void)refreshFile {
    struct stat info = {};
    BOOL exists = !stat(self.path.fileSystemRepresentation, &info);
    BOOL same = _file && exists && info.st_mtimespec.tv_sec == _fileStamp.tv_sec &&
        info.st_mtimespec.tv_nsec == _fileStamp.tv_nsec;
    if (same && _file[@"backfilledAt"]) return;
    id file = exists ? ObjectFromYAMLFile(self.path) : nil;
    _file = [file isKindOfClass:NSDictionary.class] ? [file mutableCopy] : nil;
    [self rememberFileStamp];
    // Never backfilled in this profile: do it now, and keep it, so every later answer starts from the same guesses.
    if (!_file[@"backfilledAt"]) [self writePending];
}

- (NSDictionary<NSString*, NSDictionary*>*)entriesForPaths:(NSArray<NSString*>*)paths {
    __block NSDictionary* result = nil;
    dispatch_sync([self queue], ^{ result = [self entriesOnQueueForPaths:paths]; });
    return result;
}

- (NSDictionary*)entriesOnQueueForPaths:(NSArray<NSString*>*)paths {
    [self refreshFile];
    NSDictionary* documents = [_file[@"documents"] isKindOfClass:NSDictionary.class] ? _file[@"documents"] : @{};
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    os_unfair_lock_lock(&_lock);
    for (NSString* path in paths) {
        if (![path isKindOfClass:NSString.class] || !path.length) continue;
        NSString* standard = path.stringByStandardizingPath;
        result[standard] = SPDFDocumentActivityMerge(documents[standard], _pending[standard]);
    }
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (void)entriesForPaths:(NSArray<NSString*>*)paths
             completion:(void (^)(NSDictionary<NSString*, NSDictionary*>*))completion {
    NSArray* copied = [paths copy];
    dispatch_async([self queue], ^{
        NSDictionary* entries = [self entriesOnQueueForPaths:copied];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(entries); });
    });
}

- (NSTimeInterval)recordedSince {
    __block NSTimeInterval since = 0;
    dispatch_sync([self queue], ^{
        [self refreshFile];
        since = [_file[@"recordedSince"] isKindOfClass:NSNumber.class] ? [_file[@"recordedSince"] doubleValue] : 0;
    });
    os_unfair_lock_lock(&_lock);
    for (NSDictionary* entry in _pending.allValues)
        for (NSString* key in @[ @"opened", @"viewed" ])
            if ([entry[key] isKindOfClass:NSNumber.class] && (!since || [entry[key] doubleValue] < since))
                since = [entry[key] doubleValue];
    os_unfair_lock_unlock(&_lock);
    return since;
}
@end
