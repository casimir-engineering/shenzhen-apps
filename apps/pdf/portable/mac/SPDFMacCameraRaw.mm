// Camera RAW photos (core/spdf_camera_raw.h), developed at full size by Core Image's RAW decoder, the one Preview and
// Photos use: every camera the installed macOS reads, with its colour, lens corrections and orientation. A file it
// cannot read falls back to the JPEG preview inside it.
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#include "spdf_camera_raw.h"
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static CIContext* DevelopContext(void) {
    static CIContext* context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
    });
    return context;
}

// The developed photo as a binary PPM in malloc'd memory, or NULL. No MuPDF calls in here: a MuPDF exception must not
// unwind through Objective-C frames.
static unsigned char* DevelopPhoto(const char* path, size_t* length) {
    @autoreleasepool {
        CIRAWFilter* raw = [CIRAWFilter filterWithImageURL:[NSURL fileURLWithPath:@(path)]];
        CIImage* image = raw.outputImage;
        if (!image) return NULL;
        CGRect extent = CGRectIntegral(image.extent);
        if (CGRectIsInfinite(extent) || CGRectIsEmpty(extent)) return NULL;
        const size_t width = (size_t)extent.size.width, height = (size_t)extent.size.height;
        if (width > 65535 || height > 65535) return NULL;

        char header[48];
        const size_t header_length = (size_t)snprintf(header, sizeof(header), "P6\n%zu %zu\n255\n", width, height);
        const size_t strip = 256;
        unsigned char* out = (unsigned char*)malloc(header_length + width * height * 3);
        unsigned char* rgba = (unsigned char*)malloc(width * 4 * strip);
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (!out || !rgba || !srgb) {
            free(out);
            free(rgba);
            if (srgb) CGColorSpaceRelease(srgb);
            return NULL;
        }
        memcpy(out, header, header_length);
        // Top to bottom in strips, so the RGBA scratch stays small; Core Image's y axis points up.
        for (size_t top = 0; top < height; top += strip) {
            const size_t rows = MIN(strip, height - top);
            const CGRect bounds = CGRectMake(extent.origin.x, extent.origin.y + (CGFloat)(height - top - rows),
                                             (CGFloat)width, (CGFloat)rows);
            [DevelopContext() render:image toBitmap:rgba rowBytes:(ptrdiff_t)(width * 4) bounds:bounds
                              format:kCIFormatRGBA8 colorSpace:srgb];
            unsigned char* dst = out + header_length + top * width * 3;
            const unsigned char* src = rgba;
            for (size_t i = 0, n = rows * width; i < n; ++i, src += 4, dst += 3) {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
            }
        }
        CGColorSpaceRelease(srgb);
        free(rgba);
        *length = header_length + width * height * 3;
        return out;
    }
}

// The last photo developed, for the other opens of the same file: the reader opens a document per render thread, and
// developing a large RAW takes seconds. Kept until a different file is developed or for a minute after its last use.
static pthread_mutex_t cacheLock = PTHREAD_MUTEX_INITIALIZER;
static char* cachedKey;
static unsigned char* cachedPhoto; // malloc'd
static size_t cachedLength;
static unsigned cacheGeneration;

static void DropCacheLocked(void) {
    free(cachedKey);
    free(cachedPhoto);
    cachedKey = NULL;
    cachedPhoto = NULL;
    cachedLength = 0;
}

// The file as it is now: a changed file is developed again.
static char* CacheKey(const char* path) {
    struct stat st;
    char* key = NULL;
    if (stat(path, &st) != 0) return NULL;
    if (asprintf(&key, "%s|%lld|%ld.%09ld", path, (long long)st.st_size, (long)st.st_mtimespec.tv_sec,
                 (long)st.st_mtimespec.tv_nsec) < 0)
        return NULL;
    return key;
}

static void ExpireCacheLater(void) {
    const unsigned generation = ++cacheGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      pthread_mutex_lock(&cacheLock);
      if (generation == cacheGeneration) DropCacheLocked();
      pthread_mutex_unlock(&cacheLock);
    });
}

// A copy of the developed photo in fz_malloc_no_throw memory, developing it when the cache does not hold this file.
// One development at a time: the opens racing for the same file wait for the first instead of repeating it.
static unsigned char* DevelopedPhoto(fz_context* ctx, const char* path, size_t* length) {
    char* key = CacheKey(path);
    unsigned char* copy = NULL;
    if (!key) return NULL;
    pthread_mutex_lock(&cacheLock);
    if (!cachedKey || strcmp(cachedKey, key) != 0) {
        DropCacheLocked();
        size_t developedLength = 0;
        unsigned char* developed = DevelopPhoto(path, &developedLength);
        if (developed) {
            cachedKey = key;
            key = NULL;
            cachedPhoto = developed;
            cachedLength = developedLength;
        }
    }
    if (cachedPhoto && (copy = (unsigned char*)fz_malloc_no_throw(ctx, cachedLength))) {
        memcpy(copy, cachedPhoto, cachedLength);
        *length = cachedLength;
    }
    if (cachedPhoto) ExpireCacheLater();
    pthread_mutex_unlock(&cacheLock);
    free(key);
    return copy;
}

static fz_document* DevelopWithCoreImage(fz_context* ctx, const char* path) {
    size_t length = 0;
    unsigned char* photo = DevelopedPhoto(ctx, path, &length);
    fz_buffer* buffer = NULL;
    fz_document* doc = NULL;
    if (!photo) return NULL;
    fz_var(buffer);
    fz_try(ctx) {
        buffer = fz_new_buffer_from_data(ctx, photo, length); // owns photo from here, even when it throws
        doc = fz_open_document_with_buffer(ctx, "image/x-portable-pixmap", buffer);
    }
    fz_always(ctx) fz_drop_buffer(ctx, buffer);
    fz_catch(ctx) fz_rethrow(ctx);
    return doc;
}

// HEIC, HEIF and WebP pictures (SPDFMacImageIOPictures.mm), installed beside the RAW decoder through the core's open
// hooks (core/spdf_core_document.h, which frontends don't include: its one entry declared here).
fz_document* SPDFMacOpenImageIOPicture(fz_context* ctx, const char* path);
extern "C" void spdf_core_add_open_hook(fz_document* (*hook)(fz_context* ctx, const char* path));

// Before main(): the launch prerender, the szpdf tool and every window open documents through spdf_open.
__attribute__((constructor)) static void InstallAtLoad(void) {
    spdf_camera_raw_install(DevelopWithCoreImage);
    spdf_core_add_open_hook(SPDFMacOpenImageIOPicture);
}
