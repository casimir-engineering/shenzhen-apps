// HEIC, HEIF and WebP pictures, which MuPDF does not read: decoded by ImageIO (the first frame, turned upright from
// its orientation tag) into a PNG that MuPDF shows as a one-page picture, as camera RAW photos are shown
// (SPDFMacCameraRaw.mm installs this open hook with its own, before main: one pointer, nothing decoded). Annotate
// reads the file itself with ImageIO (SPDFMacAnnotateImageIO.mm); this is only what the reader shows.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "mupdf/fitz.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int ClaimsPath(const char* path) {
    const char* dot = path ? strrchr(path, '.') : NULL;
    if (!dot || strchr(dot, '/')) return 0;
    return !strcasecmp(dot, ".heic") || !strcasecmp(dot, ".heif") || !strcasecmp(dot, ".webp");
}

// The upright first frame as PNG bytes in malloc'd memory, or NULL. No MuPDF calls in here: a MuPDF exception must not
// unwind through Objective-C frames.
static unsigned char* DecodeAsPNG(const char* path, size_t* length) {
    @autoreleasepool {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], NULL);
        if (!source) return NULL;
        NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        double side = MAX([properties[(NSString*)kCGImagePropertyPixelWidth] doubleValue],
                          [properties[(NSString*)kCGImagePropertyPixelHeight] doubleValue]);
        NSDictionary* options = @{(NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                  (NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                  (NSString*)kCGImageSourceShouldCacheImmediately: @YES,
                                  (NSString*)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1, side))};
        CGImageRef image = side > 0 ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options)
                                    : NULL;
        CFRelease(source);
        if (!image) return NULL;
        NSMutableData* png = [NSMutableData data];
        CGImageDestinationRef out = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,
                                                                     (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
        BOOL written = NO;
        if (out) {
            CGImageDestinationAddImage(out, image, NULL);
            written = CGImageDestinationFinalize(out);
            CFRelease(out);
        }
        CGImageRelease(image);
        unsigned char* bytes = written && png.length ? (unsigned char*)malloc(png.length) : NULL;
        if (!bytes) return NULL;
        memcpy(bytes, png.bytes, png.length);
        *length = png.length;
        return bytes;
    }
}

fz_document* SPDFMacOpenImageIOPicture(fz_context* ctx, const char* path) {
    if (!ClaimsPath(path)) return NULL;
    size_t length = 0;
    unsigned char* png = DecodeAsPNG(path, &length);
    if (!png) fz_throw(ctx, FZ_ERROR_FORMAT, "This picture can't be read.");
    fz_buffer* volatile buffer = NULL;
    fz_document* doc = NULL;
    fz_try(ctx) {
        buffer = fz_new_buffer_from_copied_data(ctx, png, length);
        doc = fz_open_document_with_buffer(ctx, "image/png", buffer);
    }
    fz_always(ctx) {
        free(png);
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx) fz_rethrow(ctx);
    return doc;
}
