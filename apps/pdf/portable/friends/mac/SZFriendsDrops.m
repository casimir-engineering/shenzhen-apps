// SZFriendsDrops: reading the host's items, file URLs and file promises off a drag pasteboard.

#import "mac/SZFriendsDrops.h"
#import "mac/SZFriendsPromiseCopies.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>

const NSTimeInterval SZFriendsPromiseLifetime = 60 * 60;
// A folder of our own for promise folders, so sweeping stale ones never touches anything else in the temp folder.
static NSString *const SZFPromiseParentName = @"Shenzhen Friends drops";

static NSArray<NSURL *> *SZFFileURLs(NSPasteboard *pasteboard) {
    NSArray *urls = [pasteboard readObjectsForClasses:@[ NSURL.class ]
                                              options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    return urls ?: @[];
}

static NSArray<NSFilePromiseReceiver *> *SZFPromises(NSPasteboard *pasteboard) {
    NSArray *receivers = [pasteboard readObjectsForClasses:@[ NSFilePromiseReceiver.class ] options:nil];
    return receivers ?: @[];
}

// What the helper does with one file (SZFriendsOpenSnapshotSource): it reads a regular file, refuses a folder, and
// refuses a link without following it, as it does a FIFO, a socket or a device. Classified without following links,
// then, as the GTK views do (szfriends_gtk_drops.c), so the drag says no before the person lets go. A link to a folder
// counts as a folder, the words the person expects for what Finder shows as one; packages (.app, .pages) are folders
// on disk too. A file that vanished stays acceptable while dragging, and the helper answers file_missing.
static SZFriendsDropVerdict SZFVerdictForURL(NSURL *url) {
    const char *path = (url.filePathURL ?: url).fileSystemRepresentation;
    struct stat info = {}, target = {};
    if (!path || lstat(path, &info) != 0 || S_ISREG(info.st_mode)) return SZFriendsDropVerdictAccept;
    if (S_ISDIR(info.st_mode)) return SZFriendsDropVerdictRefuseFolder;
    if (S_ISLNK(info.st_mode) && stat(path, &target) == 0 && S_ISDIR(target.st_mode))
        return SZFriendsDropVerdictRefuseFolder;
    return SZFriendsDropVerdictRefuseNotAFile;
}

static BOOL SZFPromiseIsFolder(NSFilePromiseReceiver *receiver) {
    for (NSString *identifier in receiver.fileTypes) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type && ([type conformsToType:UTTypeFolder] || [type conformsToType:UTTypeDirectory])) return YES;
    }
    return NO;
}

static SZFriendsAttachableItem *SZFItemForURL(NSURL *url) {
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = url.lastPathComponent ?: @"";
    item.fileURL = url;
    return item;
}

NSString *SZFriendsDropRefusalKey(SZFriendsDropVerdict verdict) {
    if (verdict == SZFriendsDropVerdictRefuseFolder) return @"drop_folders_refused";
    return verdict == SZFriendsDropVerdictRefuseNotAFile ? @"drop_not_a_file" : nil;
}

SZFriendsDropHighlight SZFriendsDropHighlightForVerdict(SZFriendsDropVerdict verdict) {
    if (verdict == SZFriendsDropVerdictAccept) return SZFriendsDropHighlightAccept;
    return SZFriendsDropRefusalKey(verdict) ? SZFriendsDropHighlightRefuse : SZFriendsDropHighlightNone;
}

@implementation SZFriendsDrops

+ (NSArray<NSPasteboardType> *)draggedTypesForHost:(id<SZFriendsHost>)host {
    NSMutableArray *types = [NSMutableArray arrayWithObject:NSPasteboardTypeFileURL];
    [types addObjectsFromArray:NSFilePromiseReceiver.readableDraggedTypes];
    NSArray *extra = host ? [host friendsExtraPasteboardTypes] : nil;
    if (extra.count) [types addObjectsFromArray:extra];
    return types;
}

+ (NSArray<SZFriendsAttachableItem *> *)hostItems:(NSPasteboard *)pasteboard host:(id<SZFriendsHost>)host {
    if (!host || ![pasteboard availableTypeFromArray:[host friendsExtraPasteboardTypes] ?: @[]]) return @[];
    return [host friendsItemsFromPasteboard:pasteboard] ?: @[];
}

// Whether the host's own types are on the pasteboard, without resolving them. The verdict runs on every
// draggingEntered, and resolving a reader tab hashes its file (up to 64 MiB) on the main thread, which stalled a
// group of tabs dragged over the list; the items are resolved once, on the drop.
+ (BOOL)carriesHostItems:(NSPasteboard *)pasteboard host:(id<SZFriendsHost>)host {
    NSArray *types = host ? [host friendsExtraPasteboardTypes] : nil;
    return types.count && [pasteboard availableTypeFromArray:types] != nil;
}

// One bad file sends none; a folder's words win, being the ones a person meets most. None for no files.
static SZFriendsDropVerdict SZFVerdictForURLs(NSArray<NSURL *> *urls) {
    SZFriendsDropVerdict verdict = urls.count ? SZFriendsDropVerdictAccept : SZFriendsDropVerdictNone;
    for (NSURL *url in urls) {
        SZFriendsDropVerdict one = SZFVerdictForURL(url);
        if (one == SZFriendsDropVerdictRefuseFolder) return one;
        if (one != SZFriendsDropVerdictAccept) verdict = one;
    }
    return verdict;
}

+ (SZFriendsDropVerdict)verdictForPasteboard:(NSPasteboard *)pasteboard host:(id<SZFriendsHost>)host {
    if ([self carriesHostItems:pasteboard host:host]) {
        // The host's files, unresolved: a reader tab whose file is a link is refused as the same file from Finder.
        if ([host respondsToSelector:@selector(friendsDraggedFileURLsFromPasteboard:)])
            return SZFVerdictForURLs([host friendsDraggedFileURLsFromPasteboard:pasteboard] ?: @[]);
        return SZFriendsDropVerdictAccept;
    }
    NSArray<NSURL *> *urls = SZFFileURLs(pasteboard);
    if (urls.count) return SZFVerdictForURLs(urls);
    NSArray<NSFilePromiseReceiver *> *promises = SZFPromises(pasteboard);
    for (NSFilePromiseReceiver *receiver in promises)
        if (SZFPromiseIsFolder(receiver)) return SZFriendsDropVerdictRefuseFolder;
    return promises.count ? SZFriendsDropVerdictAccept : SZFriendsDropVerdictNone;
}

+ (NSUInteger)fileCountForPasteboard:(NSPasteboard *)pasteboard host:(id<SZFriendsHost>)host {
    if ([self verdictForPasteboard:pasteboard host:host] != SZFriendsDropVerdictAccept) return 0;
    NSUInteger count = [self hostItems:pasteboard host:host].count;
    if (count) return count;
    count = SZFFileURLs(pasteboard).count;
    if (count) return count;
    for (NSFilePromiseReceiver *receiver in SZFPromises(pasteboard)) count += MAX(receiver.fileTypes.count, 1u);
    return count;
}

+ (void)readItemsFromPasteboard:(NSPasteboard *)pasteboard
                           host:(id<SZFriendsHost>)host
               promiseDirectory:(NSString *)promiseDirectory
                     completion:(void (^)(NSArray<SZFriendsAttachableItem *> *, BOOL))completion {
    SZFriendsDropVerdict verdict = [self verdictForPasteboard:pasteboard host:host];
    if (verdict != SZFriendsDropVerdictAccept) {
        completion(@[], verdict == SZFriendsDropVerdictRefuseFolder);
        return;
    }
    // The host's own drag, even one that resolves to nothing, never falls through to file URLs or promises.
    if ([self carriesHostItems:pasteboard host:host]) {
        completion([self hostItems:pasteboard host:host], NO);
        return;
    }
    NSArray<NSURL *> *urls = SZFFileURLs(pasteboard);
    if (urls.count) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSURL *url in urls) [items addObject:SZFItemForURL(url)];
        completion(items, NO);
        return;
    }
    // Promises: the source writes each file into a folder of our own, then the files are sent like any other.
    NSURL *destination = [self promiseFolderInDirectory:promiseDirectory];
    if (!destination) {
        completion(@[], NO);
        return;
    }
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.qualityOfService = NSQualityOfServiceUserInitiated;
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSURL *> *received = [NSMutableArray array];
    NSObject *lock = [NSObject new];
    for (NSFilePromiseReceiver *receiver in SZFPromises(pasteboard)) {
        NSUInteger expected = MAX(receiver.fileTypes.count, 1u);
        for (NSUInteger i = 0; i < expected; i++) dispatch_group_enter(group);
        [receiver receivePromisedFilesAtDestination:destination options:@{} operationQueue:queue
                                             reader:^(NSURL *fileURL, NSError *error) {
                                                 if (!error && fileURL) {
                                                     @synchronized(lock) {
                                                         [received addObject:fileURL];
                                                     }
                                                 }
                                                 dispatch_group_leave(group);
                                             }];
    }
    // The source keeps writing rights to `destination`, so what is sent is a copy where it cannot write
    // (SZFriendsPromiseCopies.h); its folder goes at once and the copies once sent, or SZFriendsPromiseLifetime later.
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [SZFriendsPromiseCopies copyPromisedFiles:[received copy] inFolder:destination completion:completion];
    });
}

+ (NSArray<SZFriendsAttachableItem *> *)itemsForChosenFiles:(NSArray<NSURL *> *)urls
                                                    verdict:(SZFriendsDropVerdict *)verdict {
    SZFriendsDropVerdict judged = SZFVerdictForURLs(urls);
    if (verdict) *verdict = judged;
    if (judged != SZFriendsDropVerdictAccept) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *url in urls) [items addObject:SZFItemForURL(url)];
    return items;
}

+ (NSURL *)promiseFolderInDirectory:(NSString *)promiseDirectory {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *parent = [promiseDirectory ?: NSTemporaryDirectory() stringByAppendingPathComponent:SZFPromiseParentName];
    [files createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700}
                           error:nil];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-SZFriendsPromiseLifetime];
    for (NSURL *old in [files contentsOfDirectoryAtURL:[NSURL fileURLWithPath:parent isDirectory:YES]
                            includingPropertiesForKeys:@[ NSURLCreationDateKey ] options:0 error:nil]) {
        NSDate *created = nil;
        [old getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
        if (created && [created compare:cutoff] == NSOrderedAscending) [files removeItemAtURL:old error:nil];
    }
    NSURL *folder = [NSURL fileURLWithPath:[parent stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                               isDirectory:YES];
    BOOL made = [files createDirectoryAtURL:folder withIntermediateDirectories:NO
                                 attributes:@{NSFilePosixPermissions : @0700} error:nil];
    return made ? folder : nil;
}

+ (NSArray<SZFriendsAttachableItem *> *)itemsForPromisedFiles:(NSArray<NSURL *> *)files
                                                     inFolder:(NSURL *)folder
                                                refusedFolder:(BOOL *)refusedFolder {
    if (refusedFolder) *refusedFolder = NO;
    struct stat home = {};
    if (stat(folder.fileSystemRepresentation, &home) != 0) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *url in files) {
        struct stat st = {}, parent = {};
        // lstat, not stat: the link itself is what the source wrote.
        if (!url.isFileURL || lstat(url.fileSystemRepresentation, &st) != 0) return nil;
        if (S_ISDIR(st.st_mode)) {
            if (refusedFolder) *refusedFolder = YES;
            return nil;
        }
        if (!S_ISREG(st.st_mode)) return nil;
        NSURL *container = url.URLByDeletingLastPathComponent;
        if (stat(container.fileSystemRepresentation, &parent) != 0 || parent.st_dev != home.st_dev ||
            parent.st_ino != home.st_ino)
            return nil;
        [items addObject:SZFItemForURL(url)];
    }
    return items;
}

+ (void)discardPromiseFolder:(NSURL *)folder after:(NSTimeInterval)delay {
    if (!folder) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0) * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
                   });
}

@end
