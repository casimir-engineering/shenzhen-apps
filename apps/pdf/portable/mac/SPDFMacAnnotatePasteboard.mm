// Copy and Cut put Annotate's pixels on the pasteboard as a promise: the PNG and TIFF are encoded when something
// pastes them, not before. Encoding a large picture took tens of milliseconds, and Cut deleted the object only after
// it, so the object stayed on screen that long.
#import "SPDFMacAnnotateImageIO.h"

@interface SPDFAnnotatePastedPicture : NSObject <NSPasteboardItemDataProvider>
@property(nonatomic, strong) NSData* pixels;
@property(nonatomic) int width, height, stride;
@end

@implementation SPDFAnnotatePastedPicture

- (void)pasteboard:(NSPasteboard*)pasteboard item:(NSPasteboardItem*)item provideDataForType:(NSPasteboardType)type {
    (void)pasteboard;
    spdf_bitmap bitmap = {self.width, self.height, self.stride, (unsigned char*)self.pixels.bytes};
    NSData* data = SPDFAnnotateEncodePicture(&bitmap, [type isEqual:NSPasteboardTypePNG] ? @"png" : @"tiff", nil, 0, NULL);
    if (data) [item setData:data forType:type];
}

@end

// The last picture promised, kept until the next copy replaces it (the pasteboard item does not keep its provider).
static SPDFAnnotatePastedPicture* gPromised;

BOOL SPDFAnnotateWriteToPasteboard(const spdf_bitmap* bitmap, NSPasteboard* pasteboard) {
    if (!bitmap || !bitmap->rgba || bitmap->width <= 0 || bitmap->height <= 0) return NO;
    SPDFAnnotatePastedPicture* picture = [SPDFAnnotatePastedPicture new];
    picture.pixels = [NSData dataWithBytes:bitmap->rgba length:(NSUInteger)bitmap->stride * (NSUInteger)bitmap->height];
    picture.width = bitmap->width;
    picture.height = bitmap->height;
    picture.stride = bitmap->stride;
    NSPasteboardItem* item = [NSPasteboardItem new];
    if (![item setDataProvider:picture forTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF ]]) return NO;
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[ item ]]) return NO;
    gPromised = picture;
    return YES;
}
