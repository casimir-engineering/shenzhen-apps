// Thumbnails as values: fitting and encoding what a renderer drew, checking and re-encoding what a friend sent, and
// writing the cache file (SZFriendsThumbnails.h). Everything that touches bytes is the C in this directory.

#import "service/thumbnails/SZFriendsThumbnails.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/thumbnails/szfriends_image.h"
#import "service/thumbnails/szfriends_qoi.h"

const NSUInteger SZFriendsThumbnailMaxSide = 192;
const NSUInteger SZFriendsThumbnailMaxBytes = 64000;
const NSTimeInterval SZFriendsThumbnailRenderTimeout = 2.0;

// Longer sides tried after the first, in order: each step roughly halves the pixel count every two steps, and 32 px
// still reads as "a page" or "a photo".
static const uint32_t SZFriendsThumbnailSteps[] = {160, 128, 112, 96, 80, 64, 48, 32};

static NSError *SZFriendsThumbnailError(NSInteger code, NSString *why) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSDebugDescriptionErrorKey : why}];
}

@implementation SZFriendsThumbnailPixels

- (nullable instancetype)initWithRGBA:(NSData *)rgba width:(NSUInteger)width height:(NSUInteger)height {
    if (width == 0 || height == 0 || width > 4096 || height > 4096 || rgba.length != width * height * 4) return nil;
    if ((self = [super init])) {
        _rgba = [rgba copy];
        _width = width;
        _height = height;
    }
    return self;
}

@end

@interface SZFriendsThumbnail ()
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height qoi:(NSData *)qoi png:(NSData *)png;
@end

@implementation SZFriendsThumbnail

- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height qoi:(NSData *)qoi png:(NSData *)png {
    if ((self = [super init])) {
        _width = width;
        _height = height;
        _qoi = qoi;
        _png = png;
    }
    return self;
}

@end

static NSData *_Nullable SZFriendsPNGFromRGBA(const uint8_t *rgba, uint32_t width, uint32_t height) {
    size_t size = szfriends_png_size(width, height);
    NSMutableData *png = size ? [NSMutableData dataWithLength:size] : nil;
    if (png == nil || szfriends_png_encode(rgba, width, height, png.mutableBytes, size) != size) return nil;
    return png;
}

static BOOL SZFriendsIsOpaque(const uint8_t *rgba, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        if (rgba[i * 4 + 3] != 255) return NO;
    }
    return YES;
}

// One attempt at one size: the pixels scaled to `side` on the longer side (or as they are), then QOI and PNG.
static SZFriendsThumbnail *_Nullable SZFriendsThumbnailAtSide(SZFriendsThumbnailPixels *pixels, uint32_t side) {
    uint32_t width = 0, height = 0;
    szfriends_fit_size((uint32_t)pixels.width, (uint32_t)pixels.height, side, &width, &height);
    NSData *scaled = pixels.rgba;
    if (width != pixels.width || height != pixels.height) {
        NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)width * height * 4];
        if (!szfriends_rgba_downscale(pixels.rgba.bytes, (uint32_t)pixels.width, (uint32_t)pixels.height,
                                      buffer.mutableBytes, width, height)) {
            return nil;
        }
        scaled = buffer;
    }
    size_t pixelCount = (size_t)width * height;
    uint8_t channels = SZFriendsIsOpaque(scaled.bytes, pixelCount) ? 3 : 4;
    NSMutableData *qoi = [NSMutableData dataWithLength:SZFriendsThumbnailMaxBytes];
    size_t length = szfriends_qoi_encode(scaled.bytes, width, height, channels, qoi.mutableBytes, qoi.length);
    if (length == 0) return nil;
    qoi.length = length;
    NSData *png = SZFriendsPNGFromRGBA(scaled.bytes, width, height);
    return png ? [[SZFriendsThumbnail alloc] initWithWidth:width height:height qoi:qoi png:png] : nil;
}

SZFriendsThumbnail *_Nullable SZFriendsThumbnailFromPixels(SZFriendsThumbnailPixels *pixels) {
    uint32_t longer = (uint32_t)MAX(pixels.width, pixels.height);
    SZFriendsThumbnail *thumbnail = SZFriendsThumbnailAtSide(pixels, (uint32_t)SZFriendsThumbnailMaxSide);
    for (size_t i = 0; thumbnail == nil && i < sizeof SZFriendsThumbnailSteps / sizeof SZFriendsThumbnailSteps[0];
         i++) {
        // A step at or above the picture's own size would encode the same pixels again.
        if (SZFriendsThumbnailSteps[i] >= MIN(longer, (uint32_t)SZFriendsThumbnailMaxSide)) continue;
        thumbnail = SZFriendsThumbnailAtSide(pixels, SZFriendsThumbnailSteps[i]);
    }
    return thumbnail;
}

static NSData *SZFriendsRefuseThumbnail(NSString **reason, NSString *why) {
    if (reason) *reason = why;
    return nil;
}

NSData *_Nullable SZFriendsPNGFromReceivedThumbnail(NSData *qoi, uint64_t declaredWidth, uint64_t declaredHeight,
                                                   NSString **reason) {
    // Every bound is checked before the pixel buffer exists, so what a peer declares never sizes an allocation.
    if (qoi.length < SZFRIENDS_QOI_MIN_SIZE || qoi.length > SZFriendsThumbnailMaxBytes) {
        return SZFriendsRefuseThumbnail(reason, [NSString stringWithFormat:@"%lu bytes", (unsigned long)qoi.length]);
    }
    if (declaredWidth == 0 || declaredHeight == 0 || declaredWidth > SZFriendsThumbnailMaxSide ||
        declaredHeight > SZFriendsThumbnailMaxSide) {
        return SZFriendsRefuseThumbnail(reason, [NSString stringWithFormat:@"declared %llu x %llu", declaredWidth,
                                                                           declaredHeight]);
    }
    szfriends_qoi_desc desc;
    if (!szfriends_qoi_read_header(qoi.bytes, qoi.length, (uint32_t)SZFriendsThumbnailMaxSide,
                                   (uint32_t)SZFriendsThumbnailMaxSide, &desc)) {
        return SZFriendsRefuseThumbnail(reason, @"not a QOI header within the limits");
    }
    if (desc.width != declaredWidth || desc.height != declaredHeight) {
        return SZFriendsRefuseThumbnail(reason, @"the QOI header disagrees with the declared size");
    }
    NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)desc.width * desc.height * 4];
    if (!szfriends_qoi_decode(qoi.bytes, qoi.length, &desc, rgba.mutableBytes, rgba.length)) {
        return SZFriendsRefuseThumbnail(reason, @"malformed QOI");
    }
    NSData *png = SZFriendsPNGFromRGBA(rgba.bytes, desc.width, desc.height);
    return png ?: SZFriendsRefuseThumbnail(reason, @"PNG encoding failed");
}

NSString *_Nullable SZFriendsTypeIdentifierForFileName(NSString *name) {
    NSString *extension = name.pathExtension;
    if (extension.length == 0) return nil;
    UTType *type = [UTType typeWithFilenameExtension:extension];
    return type == nil || type.isDynamic ? nil : type.identifier;
}

static BOOL SZFriendsEnsureThumbnailDirectory(NSString *directory, NSError **error) {
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
        if (error) *error = SZFriendsThumbnailError(errno, @"cannot create the thumbnail directory");
        return NO;
    }
    // A planted symlink would send pictures of a friend's documents somewhere else.
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) {
        if (error) *error = SZFriendsThumbnailError(ENOTDIR, @"the thumbnail directory is not a directory");
        return NO;
    }
    return YES;
}

NSString *_Nullable SZFriendsWriteThumbnailFile(NSData *png, NSString *directory, NSError **error) {
    if (!SZFriendsEnsureThumbnailDirectory(directory, error)) return nil;
    uint8_t random[16];
    arc4random_buf(random, sizeof random);
    NSMutableString *name = [NSMutableString stringWithCapacity:36];
    for (size_t i = 0; i < sizeof random; i++) [name appendFormat:@"%02x", random[i]];
    [name appendString:@".png"];
    NSString *path = [directory stringByAppendingPathComponent:name];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        if (error) *error = SZFriendsThumbnailError(errno, @"cannot create the thumbnail file");
        return nil;
    }
    const uint8_t *bytes = png.bytes;
    size_t remaining = png.length;
    BOOL ok = YES;
    while (ok && remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        ok = written > 0;
        if (ok) {
            bytes += written;
            remaining -= (size_t)written;
        }
    }
    // Flushed before the store records it, so a row never names a file a power cut left empty.
    ok = ok && fsync(fd) == 0;
    int failure = errno;
    close(fd);
    if (!ok) {
        unlink(path.fileSystemRepresentation);
        if (error) *error = SZFriendsThumbnailError(failure, @"cannot write the thumbnail file");
        return nil;
    }
    return path;
}
