// Copy and Cut put Annotate's pixels on the pasteboard at once, as a promise, and encode the TIFF and the PNG on a
// background queue right after. Encoding a large picture took tens of milliseconds (seconds for a very large canvas),
// and Cut deleted the object only after it, so the object stayed on screen that long.
//
// Once both are encoded they replace the promise as real data, and the pixels are let go: the clipboard keeps the
// picture after ShenzhenPDF quits, and a quit has nothing left to encode. Until then a paste is answered from the
// encoding under way (waited for, not done twice). Should the quit come first, AppKit's terminate asks for the
// promised data: each kind is waited for at most kQuitWait, within the quit's own deadline (SPDFMacQuitFinishing.mm),
// so the TIFF, encoded first and quick, is there even when a very large PNG isn't. A picture over kTIFFMaxPixels is
// offered as PNG alone: its TIFF is 4 bytes a pixel, uncompressed, and the pasteboard took longer to take 760 MB of
// it (an A0 canvas at 600 ppi) than a quit may last. When something else takes the
// clipboard first, the pasteboard lets the promise go (pasteboardFinishedWithDataProvider:) and so does this file:
// the pixels and whatever was encoded are freed.
#import "SPDFMacAnnotateImageIO.h"

#import "SPDFMacQuitFinishing.h"

static const NSTimeInterval kQuitWait = 0.8;
static const double kTIFFMaxPixels = 50e6;

@interface SPDFAnnotatePastedPicture : NSObject <NSPasteboardItemDataProvider>
@property(atomic, strong) NSData* pixels;  // nil once both kinds are encoded, or the clipboard is someone else's
@property(nonatomic) int width, height, stride;
@property(nonatomic) BOOL tiffToo;  // not for a very large picture
@property(atomic, strong) NSData* png;
@property(atomic, strong) NSData* tiff;
@property(nonatomic, strong) dispatch_group_t tiffDone, pngDone;
@property(atomic) BOOL dropped;           // the pasteboard let go of this promise
@property(nonatomic) NSInteger changeCount;  // the general pasteboard's, right after the promise was written
@end

// The last picture promised, kept until both kinds are on the pasteboard or something else takes it (the pasteboard
// item does not keep its provider).
static SPDFAnnotatePastedPicture* gPromised;

static NSData* SPDFAnnotateEncodePasted(NSData* pixels, int width, int height, int stride, BOOL png) {
    if (!pixels) return nil;
    spdf_bitmap bitmap = {width, height, stride, (unsigned char*)pixels.bytes};
    return SPDFAnnotateEncodePicture(&bitmap, png ? @"png" : @"tiff", nil, 0, NULL);
}

@implementation SPDFAnnotatePastedPicture

- (void)pasteboard:(NSPasteboard*)pasteboard item:(NSPasteboardItem*)item provideDataForType:(NSPasteboardType)type {
    (void)pasteboard;
    BOOL png = [type isEqual:NSPasteboardTypePNG];
    NSData* data = png ? self.png : self.tiff;
    if (!data) {  // being encoded: waited for; while quitting, only as long as the quit can wait
        BOOL quitting = spdf_mac_quit_finishing();
        dispatch_time_t until = quitting ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuitWait * NSEC_PER_SEC))
                                         : DISPATCH_TIME_FOREVER;
        dispatch_group_wait(png ? self.pngDone : self.tiffDone, until);
        data = png ? self.png : self.tiff;
    }
    if (!data && !spdf_mac_quit_finishing())  // let go meanwhile, or not encoded: done now, as before
        data = SPDFAnnotateEncodePasted(self.pixels, self.width, self.height, self.stride, png);
    if (data) [item setData:data forType:type];
}

- (void)pasteboardFinishedWithDataProvider:(NSPasteboard*)pasteboard {
    (void)pasteboard;
    [self letGo];
}

- (void)letGo {
    self.dropped = YES;
    self.pixels = nil;
    self.png = nil;
    self.tiff = nil;
    if (gPromised == self) gPromised = nil;
}

// On a background queue: the TIFF (quick), then the PNG; then, on the main queue, both replace the promise.
- (void)encodeForPasteboard:(NSPasteboard*)pasteboard {
    self.tiffDone = dispatch_group_create();
    self.pngDone = dispatch_group_create();
    dispatch_group_enter(self.tiffDone);
    dispatch_group_enter(self.pngDone);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
          if (!self.dropped && self.tiffToo)
              self.tiff = SPDFAnnotateEncodePasted(self.pixels, self.width, self.height, self.stride, NO);
          dispatch_group_leave(self.tiffDone);
          if (!self.dropped)
              self.png = SPDFAnnotateEncodePasted(self.pixels, self.width, self.height, self.stride, YES);
          dispatch_group_leave(self.pngDone);
      }
      dispatch_async(dispatch_get_main_queue(), ^{ [self replacePromiseOn:pasteboard]; });
    });
}

- (void)replacePromiseOn:(NSPasteboard*)pasteboard {
    NSData* png = self.png;
    NSData* tiff = self.tiff;
    // Another copy, here or in another app, since: that one is on the clipboard.
    BOOL taken = gPromised != self || pasteboard.changeCount != self.changeCount;
    if (self.dropped || taken || !png || (self.tiffToo && !tiff)) {
        if (taken) [self letGo];
        return;
    }
    NSPasteboardItem* item = [NSPasteboardItem new];
    [item setData:png forType:NSPasteboardTypePNG];
    if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    [pasteboard clearContents];  // lets this promise go (pasteboardFinishedWithDataProvider:)
    [pasteboard writeObjects:@[ item ]];
    [self letGo];
}

@end

BOOL SPDFAnnotateWriteToPasteboard(const spdf_bitmap* bitmap, NSPasteboard* pasteboard) {
    if (!bitmap || !bitmap->rgba || bitmap->width <= 0 || bitmap->height <= 0) return NO;
    SPDFAnnotatePastedPicture* picture = [SPDFAnnotatePastedPicture new];
    picture.pixels = [NSData dataWithBytes:bitmap->rgba length:(NSUInteger)bitmap->stride * (NSUInteger)bitmap->height];
    picture.width = bitmap->width;
    picture.height = bitmap->height;
    picture.stride = bitmap->stride;
    picture.tiffToo = (double)bitmap->width * bitmap->height <= kTIFFMaxPixels;
    NSPasteboardItem* item = [NSPasteboardItem new];
    NSArray* types = picture.tiffToo ? @[ NSPasteboardTypePNG, NSPasteboardTypeTIFF ] : @[ NSPasteboardTypePNG ];
    if (![item setDataProvider:picture forTypes:types]) return NO;
    [gPromised letGo];  // the picture copied before: replaced now
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[ item ]]) return NO;
    picture.changeCount = pasteboard.changeCount;
    gPromised = picture;
    [picture encodeForPasteboard:pasteboard];
    return YES;
}
