#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <ImageIO/ImageIO.h>

// Encryption describes the file format, not whether the reader needs a password.
// Owner-restricted PDFs often have an empty user password and are already readable.
// Thumbnail pixels remain in the window's bounded memory cache, never on disk.
static inline NSImage* SPDFCollectionPDFThumbnail(NSURL* URL, NSInteger page,
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
    return [[pdf pageAtIndex:index] thumbnailOfSize:NSMakeSize(260,300) forBox:kPDFDisplayBoxMediaBox];
}

// Decode only the requested thumbnail, not a full-resolution photograph.
static inline NSImage* SPDFCollectionImageThumbnail(NSURL* URL, NSInteger page) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache:@NO});
    if (!source) return nil;
    size_t count = CGImageSourceGetCount(source);
    size_t index = count ? MIN((size_t)MAX(0,page-1),count-1) : 0;
    CGImageRef thumbnail = count ? CGImageSourceCreateThumbnailAtIndex(source,index,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform:@YES,
            (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize:@300,
            (__bridge NSString*)kCGImageSourceShouldCacheImmediately:@YES}) : NULL;
    CFRelease(source);
    if (!thumbnail) return nil;
    NSImage* image = [[NSImage alloc] initWithCGImage:thumbnail size:NSZeroSize];
    CGImageRelease(thumbnail);
    return image;
}
