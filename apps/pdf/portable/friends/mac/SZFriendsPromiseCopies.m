// SZFriendsPromiseCopies: promised files checked through one descriptor and copied where their source cannot write.

#import "mac/SZFriendsPromiseCopies.h"

#import "mac/SZFriendsDrops.h"

#include <copyfile.h>
#include <fcntl.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const SZFCopiesExtension = @"copies";
// Promise folders live in this folder (SZFriendsDrops.m), and the copies beside them, so its sweep of stale folders
// removes stale copies too and nothing outside it is ever removed here.
static NSString *const SZFDropsFolderName = @"Shenzhen Friends drops";

static void SZFRemove(NSURL *url) {
    if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

static NSURL *SZFCopiesFolder(NSURL *folder) {
    NSString *name = [folder.lastPathComponent stringByAppendingPathExtension:SZFCopiesExtension];
    return [folder.URLByDeletingLastPathComponent URLByAppendingPathComponent:name isDirectory:YES];
}

// One file, copied from the descriptor that was checked, so what is sent is what passed the check. O_NOFOLLOW refuses
// a symlink, and O_NONBLOCK keeps a FIFO swapped in after the lstat from blocking the open.
static BOOL SZFCopyOne(NSURL *url, const struct stat *home, int copiesFD, BOOL *isFolder) {
    struct stat checked = {}, parent = {}, opened = {};
    if (!url.isFileURL || lstat(url.fileSystemRepresentation, &checked) != 0) return NO;
    if (S_ISDIR(checked.st_mode)) {
        *isFolder = YES;
        return NO;
    }
    if (!S_ISREG(checked.st_mode)) return NO;
    NSURL *container = url.URLByDeletingLastPathComponent;
    if (stat(container.fileSystemRepresentation, &parent) != 0 || parent.st_dev != home->st_dev ||
        parent.st_ino != home->st_ino)
        return NO;
    NSString *name = url.lastPathComponent;
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) return NO;
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NO;
    BOOL ok = fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) && opened.st_dev == checked.st_dev &&
              opened.st_ino == checked.st_ino;
    if (ok) {
        const char *copyName = name.fileSystemRepresentation;
        // A clone costs nothing on APFS, where the temporary folder lives; another volume gets a plain copy.
        if (fclonefileat(fd, copiesFD, copyName, 0) == 0) {
            ok = fchmodat(copiesFD, copyName, 0600, AT_SYMLINK_NOFOLLOW) == 0;
        } else {
            int out = openat(copiesFD, copyName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            ok = out >= 0 && fcopyfile(fd, out, NULL, COPYFILE_DATA) == 0;
            if (out >= 0) close(out);
        }
    }
    close(fd);
    return ok;
}

@implementation SZFriendsPromiseCopies

+ (NSArray<SZFriendsAttachableItem *> *)copyPromisedFiles:(NSArray<NSURL *> *)files
                                                 inFolder:(NSURL *)folder
                                            refusedFolder:(BOOL *)refusedFolder {
    if (refusedFolder) *refusedFolder = NO;
    struct stat home = {};
    if (!folder.isFileURL || stat(folder.fileSystemRepresentation, &home) != 0) return nil;
    if (!files.count) return @[];
    NSURL *copies = SZFCopiesFolder(folder);
    if (mkdir(copies.fileSystemRepresentation, 0700) != 0) return nil;
    int copiesFD = open(copies.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    NSMutableArray *items = copiesFD >= 0 ? [NSMutableArray array] : nil;
    BOOL isFolder = NO;
    for (NSURL *url in files) {
        if (!items) break;
        if (!SZFCopyOne(url, &home, copiesFD, &isFolder)) {
            items = nil;
            break;
        }
        SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
        item.title = url.lastPathComponent;
        item.fileURL = [copies URLByAppendingPathComponent:url.lastPathComponent isDirectory:NO];
        [items addObject:item];
    }
    if (copiesFD >= 0) close(copiesFD);
    // One bad file sends none, and leaves no copy of the others behind.
    if (!items) SZFRemove(copies);
    if (refusedFolder) *refusedFolder = isFolder;
    return items;
}

+ (void)copyPromisedFiles:(NSArray<NSURL *> *)files
                 inFolder:(NSURL *)folder
               completion:(void (^)(NSArray<SZFriendsAttachableItem *> *, BOOL))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL refusedFolder = NO;
        NSArray *items = [self copyPromisedFiles:files inFolder:folder refusedFolder:&refusedFolder];
        // The source can still write there; nothing in it is needed once the copies exist.
        SZFRemove(folder);
        [self discardCopiesForItems:items ?: @[] after:SZFriendsPromiseLifetime];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items ?: @[], refusedFolder);
        });
    });
}

+ (BOOL)isPromiseCopy:(NSURL *)url {
    NSURL *copies = url.URLByDeletingLastPathComponent;
    return url.isFileURL && [copies.pathExtension isEqualToString:SZFCopiesExtension] &&
           [copies.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:SZFDropsFolderName];
}

+ (void)discardCopiesForFileObjects:(NSArray<NSDictionary *> *)files {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *file in files) {
        NSString *path = [file isKindOfClass:NSDictionary.class] ? file[@"path"] : nil;
        if (![path isKindOfClass:NSString.class] || !path.length) continue;
        SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
        item.fileURL = [NSURL fileURLWithPath:path];
        [items addObject:item];
    }
    [self discardCopiesForItems:items after:0];
}

+ (void)discardCopiesForItems:(NSArray<SZFriendsAttachableItem *> *)items after:(NSTimeInterval)delay {
    NSMutableSet<NSURL *> *folders = [NSMutableSet set];
    for (SZFriendsAttachableItem *item in items)
        if ([self isPromiseCopy:item.fileURL]) [folders addObject:item.fileURL.URLByDeletingLastPathComponent];
    if (!folders.count) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0) * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       for (NSURL *copies in folders) SZFRemove(copies);
                   });
}

@end
