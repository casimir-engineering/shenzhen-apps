#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <ImageIO/ImageIO.h>
#import "SPDFMacTabPreviewCache.h"

// The list's page well (SPDFCollectionPagePreview): thumbnails are made for exactly this box at the window's backing
// scale, 130 x 176 px at 2x. They used to be 260 x 300 pt (520 x 600 px, 1.2 MB decoded) for a 65 x 88 pt well.
static const NSSize kSPDFCollectionThumbnailPoints = {65, 88};

// `content` (a page or image, any unit) fitted in the well, in whole pixels.
static inline NSSize SPDFCollectionThumbnailPixels(NSSize content, CGFloat scale) {
    if (!(content.width > 0) || !(content.height > 0)) return NSZeroSize;
    CGFloat fit = MIN(kSPDFCollectionThumbnailPoints.width / content.width,
                      kSPDFCollectionThumbnailPoints.height / content.height) * MAX(scale, 1);
    return NSMakeSize(MAX(1, round(content.width * fit)), MAX(1, round(content.height * fit)));
}
// An opaque copy of `source` at its fitted pixel size (the tab hover preview's scaler), sized in points.
static inline NSImage* SPDFCollectionThumbnailFromPixels(CGImageRef source, CGFloat scale) {
    if (!source) return nil;
    NSSize pixels = SPDFCollectionThumbnailPixels(NSMakeSize(CGImageGetWidth(source), CGImageGetHeight(source)), scale);
    CGImageRef fitted = SPDFTabPreviewCreateThumbnail(source, (size_t)pixels.width, (size_t)pixels.height);
    if (!fitted) return nil;
    CGFloat points = MAX(scale, 1);
    NSImage* image = [[NSImage alloc] initWithCGImage:fitted
                                                 size:NSMakeSize(pixels.width / points, pixels.height / points)];
    CGImageRelease(fitted);
    return image;
}

// What a thumbnail is of, for the disk cache: a saved version never changes; an original is named by its size and
// modification time, so an edit misses and is rendered again. Nil when an original cannot be stat'ed.
static inline NSString* SPDFCollectionThumbnailDiskKey(NSDictionary* row, NSInteger page, CGFloat scale) {
    NSDictionary* document = row[@"document"], *version = row[@"version"];
    NSString* revision = [version[@"id"] length] ? [@"version " stringByAppendingString:version[@"id"]] : nil;
    if (!revision) {
        NSString* stamp = SPDFTabPreviewFileStamp(document[@"path"]);
        if (!stamp) return nil;
        revision = [NSString stringWithFormat:@"original %@ %@", document[@"path"], stamp];
    }
    return [NSString stringWithFormat:@"collection-thumbnail 1|%@|%@|page %ld|%gx|%gx%g", document[@"id"] ?: @"",
        revision, (long)page, scale, kSPDFCollectionThumbnailPoints.width, kSPDFCollectionThumbnailPoints.height];
}

// Encryption describes the file format, not whether the reader needs a password.
// Owner-restricted PDFs often have an empty user password and are already readable.
// A PDF that needed a password (`unlock` ran) leaves its pixels in memory only: the Collection never stores them.
// `box` is in points; PDFKit turns the page and draws it at the main screen's scale.
static inline NSImage* SPDFCollectionPDFThumbnail(NSURL* URL, NSInteger page, NSSize box,
                                                 void (^unlock)(PDFDocument*), NSError** error) {
    PDFDocument* pdf = [[PDFDocument alloc] initWithURL:URL];
    if (pdf.isLocked) [pdf unlockWithPassword:@""];
    if (pdf.isLocked && unlock) unlock(pdf);
    NSString* failure = !pdf ? @"The saved PDF could not be read." : pdf.isLocked ?
        @"Open this saved copy and unlock it to show its preview." : !pdf.pageCount ?
        @"The saved PDF has no pages." : nil;
    if (failure) {
        if (error) *error = [NSError errorWithDomain:@"SPDFCollectionThumbnail" code:pdf.isLocked ? 2 : 1
                                          userInfo:@{NSLocalizedDescriptionKey:failure}];
        return nil;
    }
    NSInteger index = MIN(MAX(0,page-1),(NSInteger)pdf.pageCount-1);
    return [[pdf pageAtIndex:index] thumbnailOfSize:box forBox:kPDFDisplayBoxMediaBox];
}

// Decode only the requested thumbnail, not a full-resolution photograph: `side` pixels at most.
static inline NSImage* SPDFCollectionImageThumbnail(NSURL* URL, NSInteger page, CGFloat side) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache:@NO});
    if (!source) return nil;
    size_t count = CGImageSourceGetCount(source);
    size_t index = count ? MIN((size_t)MAX(0,page-1),count-1) : 0;
    CGImageRef thumbnail = count ? CGImageSourceCreateThumbnailAtIndex(source,index,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform:@YES,
            (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize:@(side),
            (__bridge NSString*)kCGImageSourceShouldCacheImmediately:@YES}) : NULL;
    CFRelease(source);
    if (!thumbnail) return nil;
    NSImage* image = [[NSImage alloc] initWithCGImage:thumbnail size:NSZeroSize];
    CGImageRelease(thumbnail);
    return image;
}
