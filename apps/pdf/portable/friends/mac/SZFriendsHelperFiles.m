// SZFriendsHelperFiles: which of the helper's files a view reads, and avatar photos read off the main thread.

#import "mac/SZFriendsHelperFiles.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include "client/szfriends_client.h"

const off_t SZFriendsAvatarPhotoMaxBytes = 256 * 1024;
const NSInteger SZFriendsAvatarPhotoMaxSide = 1024;

// Directly inside `directory`, by a name the helper chose: one component after "directory/", never "." or "..".
static BOOL SZFDirectlyIn(NSString *path, NSString *directory) {
    NSString *prefix = [directory stringByAppendingString:@"/"];
    if (!directory.length || ![path hasPrefix:prefix]) return NO;
    NSString *name = [path substringFromIndex:prefix.length];
    return name.length && ![name containsString:@"/"] && ![name isEqualToString:@"."] && ![name isEqualToString:@".."];
}

BOOL SZFriendsIsHelperFile(NSString *path, NSString *folder) {
    if (!path.isAbsolutePath || !folder.length) return NO;
    char state[SZFRIENDS_PATH_CAP];
    if (szfriends_default_state_dir(state, sizeof state) != SZFRIENDS_OK) return NO;
    if (SZFDirectlyIn(path, [@(state) stringByAppendingPathComponent:folder])) return YES;
    // The helper may report the state directory with a symbolic link on its way resolved.
    char resolved[PATH_MAX];
    return realpath(state, resolved) && SZFDirectlyIn(path, [@(resolved) stringByAppendingPathComponent:folder]);
}

NSData *SZFriendsReadRegularFile(NSString *path, off_t limit) {
    // No link followed, and a pipe or device never waited on: only a regular file of a bounded size is read.
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    NSMutableData *data = nil;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size <= limit) {
        data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
        size_t done = 0;
        while (data && done < data.length) {
            ssize_t got = read(fd, (uint8_t *)data.mutableBytes + done, data.length - done);
            if (got <= 0) data = nil;
            else done += (size_t)got;
        }
    }
    close(fd);
    return data;
}

static NSUInteger SZFRead16(const uint8_t *bytes) {
    return (NSUInteger)bytes[0] << 8 | bytes[1];
}

BOOL SZFriendsDeclaredImageSize(NSData *data, NSInteger *width, NSInteger *height, BOOL *isPNG) {
    static const uint8_t png[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    const uint8_t *bytes = data.bytes;
    NSUInteger size = data.length;
    if (isPNG) *isPNG = NO;
    if (size >= 24 && !memcmp(bytes, png, 8) && !memcmp(bytes + 12, "IHDR", 4)) {
        // Sides past 65535 fail every bound the views use; the high halves must be zero.
        if (SZFRead16(bytes + 16) || SZFRead16(bytes + 20)) return NO;
        *width = (NSInteger)SZFRead16(bytes + 18), *height = (NSInteger)SZFRead16(bytes + 22);
        if (isPNG) *isPNG = YES;
        return YES;
    }
    if (size < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return NO;
    // JPEG: walk the marker segments to the first frame header (ITU T.81 B.1.1), as the GTK views do.
    for (NSUInteger at = 2; at + 4 <= size;) {
        if (bytes[at] != 0xFF) return NO;
        while (at < size && bytes[at] == 0xFF) at++; // fill bytes
        if (at >= size) return NO;
        uint8_t marker = bytes[at++];
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue; // stand alone, without a length
        if (marker == 0xD8 || marker == 0xD9 || marker == 0xDA || at + 2 > size) return NO; // no frame first
        NSUInteger length = SZFRead16(bytes + at);
        if (length < 2 || at + length > size) return NO;
        BOOL frame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (frame) {
            if (length < 8) return NO;
            *height = (NSInteger)SZFRead16(bytes + at + 3), *width = (NSInteger)SZFRead16(bytes + at + 5);
            return YES;
        }
        at += length;
    }
    return NO;
}

CGImageRef SZFriendsCopyAvatarPhoto(NSString *path) {
    if (!SZFriendsIsHelperFile(path ?: @"", @"pictures")) return NULL;
    NSData *data = SZFriendsReadRegularFile(path, SZFriendsAvatarPhotoMaxBytes);
    NSInteger width = 0, height = 0;
    BOOL isPNG = NO;
    // The header's size is judged before anything is decoded, so a photo declaring 40,000 px is never decoded.
    if (!data || !SZFriendsDeclaredImageSize(data, &width, &height, &isPNG) || width < 1 || height < 1 ||
        width > SZFriendsAvatarPhotoMaxSide || height > SZFriendsAvatarPhotoMaxSide)
        return NULL;
    NSDictionary *sourceOptions = @{(id)kCGImageSourceShouldCache : @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data,
                                                          (__bridge CFDictionaryRef)sourceOptions);
    if (!source) return NULL;
    NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
    NSString *expected = isPNG ? UTTypePNG.identifier : UTTypeJPEG.identifier;
    CGImageRef image = NULL;
    // Decoded here, on the caller's thread, rather than when it is first drawn on the main thread.
    NSDictionary *imageOptions = @{(id)kCGImageSourceShouldCacheImmediately : @YES};
    if ([type isEqualToString:expected] && CGImageSourceGetCount(source) == 1)
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)imageOptions);
    CFRelease(source);
    // What decoded must be what the header declared: a header that lies about its pixels shows initials.
    if (image && ((NSInteger)CGImageGetWidth(image) != width || (NSInteger)CGImageGetHeight(image) != height)) {
        CGImageRelease(image);
        image = NULL;
    }
    return image;
}

#pragma mark - Loading off the main thread

static NSCache<NSString *, NSImage *> *SZFPhotoCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 200;
    });
    return cache;
}

// Paths being read, each with the views waiting to redraw (weakly held: a view that went away needs nothing).
static NSMutableDictionary<NSString *, NSHashTable<NSView *> *> *SZFPhotoWaiters(void) {
    static NSMutableDictionary *waiters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ waiters = [NSMutableDictionary dictionary]; });
    return waiters;
}

static dispatch_queue_t SZFPhotoQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("szfriends.views.avatar-photos",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                              QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

static NSUInteger SZFPhotoGeneration;

NSImage *SZFriendsAvatarPhoto(NSString *path, NSView *view) {
    // Judged by the path alone here; the file itself is opened only on the queue.
    if (!SZFriendsIsHelperFile(path ?: @"", @"pictures")) return nil;
    NSImage *image = [SZFPhotoCache() objectForKey:path];
    if (image) return image;
    NSHashTable *waiting = SZFPhotoWaiters()[path];
    BOOL loading = waiting != nil;
    if (!waiting) SZFPhotoWaiters()[path] = waiting = [NSHashTable weakObjectsHashTable];
    if (view) [waiting addObject:view];
    if (loading) return nil;
    NSUInteger generation = SZFPhotoGeneration;
    dispatch_async(SZFPhotoQueue(), ^{
        CGImageRef photo = SZFriendsCopyAvatarPhoto(path);
        NSImage *loaded = photo ? [[NSImage alloc] initWithCGImage:photo
                                                              size:NSMakeSize(CGImageGetWidth(photo),
                                                                              CGImageGetHeight(photo))]
                                : nil;
        if (photo) CGImageRelease(photo);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != SZFPhotoGeneration) return; // forgotten meanwhile: a later draw asks again
            NSHashTable *views = SZFPhotoWaiters()[path];
            [SZFPhotoWaiters() removeObjectForKey:path];
            if (!loaded) return;
            [SZFPhotoCache() setObject:loaded forKey:path];
            for (NSView *waiter in views) waiter.needsDisplay = YES;
        });
    });
    return nil;
}

void SZFriendsForgetAvatarPhotos(void) {
    SZFPhotoGeneration++;
    [SZFPhotoCache() removeAllObjects];
    [SZFPhotoWaiters() removeAllObjects];
}
