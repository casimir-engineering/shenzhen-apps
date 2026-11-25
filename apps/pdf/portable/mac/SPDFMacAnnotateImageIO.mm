// Pictures in and out of Annotate's core canvas, and its fonts (SPDFMacAnnotateImageIO.h).
//
// WAVE 0 STUB (Mac UI A implements): nothing decodes or encodes; every call answers nil, NO or an empty value.
#import "SPDFMacAnnotateImageIO.h"

@implementation SPDFAnnotatePicture
- (spdf_paint_pixels)pixels {
    spdf_paint_pixels none = {0, 0, 0, NULL, 0};
    return none;
}
- (CGColorSpaceRef)colorSpace {
    return NULL;
}
@end

SPDFAnnotateDocumentKind SPDFAnnotateDocumentKindForPath(NSString* path) {
    (void)path;
    return SPDFAnnotateDocumentNone;
}

SPDFAnnotatePicture* SPDFAnnotateDecodePicture(NSString* path, NSError** error) {
    (void)path;
    if (error) *error = nil;
    return nil;
}

SPDFAnnotatePicture* SPDFAnnotateDecodePictureData(NSData* data, NSError** error) {
    (void)data;
    if (error) *error = nil;
    return nil;
}

SPDFAnnotatePicture* SPDFAnnotatePictureFromPasteboard(NSPasteboard* pasteboard) {
    (void)pasteboard;
    return nil;
}

NSData* SPDFAnnotateEncodePicture(const spdf_bitmap* bitmap, NSString* format, NSDictionary* properties,
                                  CGFloat quality, NSError** error) {
    (void)bitmap; (void)format; (void)properties; (void)quality;
    if (error) *error = nil;
    return nil;
}

BOOL SPDFAnnotateWriteFileAtomically(NSData* data, NSString* path, NSError** error) {
    (void)data; (void)path;
    if (error) *error = nil;
    return NO;
}

BOOL SPDFAnnotateWriteToPasteboard(const spdf_bitmap* bitmap, NSPasteboard* pasteboard) {
    (void)bitmap; (void)pasteboard;
    return NO;
}

NSArray<NSDictionary*>* SPDFAnnotateSaveFormats(void) {
    return @[];
}

NSString* SPDFAnnotateFormatForPath(NSString* path) {
    (void)path;
    return nil;
}

void SPDFAnnotateInstallFontResolver(void) {
}

NSArray<NSString*>* SPDFAnnotateFontFamilies(void) {
    return @[];
}

NSColor* SPDFAnnotateColor(spdf_paint_color color) {
    return [NSColor colorWithSRGBRed:((color >> 24) & 0xFF) / 255.0 green:((color >> 16) & 0xFF) / 255.0
                                blue:((color >> 8) & 0xFF) / 255.0 alpha:(color & 0xFF) / 255.0];
}

spdf_paint_color SPDFAnnotatePaintColor(NSColor* color) {
    (void)color;
    return 0;
}
