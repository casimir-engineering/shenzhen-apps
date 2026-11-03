// SVG images in the reader's Markdown, drawn by MuPDF's SVG renderer (core/spdf_svg_image.h) rather than AppKit's,
// which reads neither matplotlib's `font:` shorthand nor its glyphs placed with <use>. The picture stays vector: the
// SVG becomes a one-page PDF, whose page a Markdown page draws at every draw (markdown/SPDFMarkdownVectorPicture.h), so
// it is crisp at any zoom and prints and exports as vectors. The dark theme draws a recoloured copy of that PDF.
#import "markdown/SPDFMarkdownResources.h"

#include "spdf_svg_image.h"

#include <stdlib.h>

static NSImage* SPDFMacSVGImageFromData(NSData* data) {
    size_t length = 0;
    float width = 0, height = 0;
    unsigned char* pdf = spdf_svg_image_pdf((const unsigned char*)data.bytes, data.length, &length, &width, &height);
    if (!pdf) return nil;
    NSData* bytes = [NSData dataWithBytesNoCopy:pdf length:length freeWhenDone:YES];
    NSPDFImageRep* rep = [NSPDFImageRep imageRepWithData:bytes];
    // The rep's own size rounds up to whole points (187.2 becomes 188); the image keeps the SVG's exact size.
    NSSize size = NSMakeSize(width, height);
    if (!rep || size.width <= 0 || size.height <= 0) return nil;
    NSImage* image = [[NSImage alloc] initWithSize:size];
    image.cacheMode = NSImageCacheNever;  // drawn from the page at every size, never from a bitmap made at another
    rep.size = size;
    [image addRepresentation:rep];
    return image;
}

static NSData* SPDFMacSVGImageDarkPDF(NSData* pdf) {
    size_t length = 0;
    unsigned char* dark = spdf_svg_image_pdf_dark((const unsigned char*)pdf.bytes, pdf.length, &length);
    return dark ? [NSData dataWithBytesNoCopy:dark length:length freeWhenDone:YES] : nil;
}

@interface SPDFMacSVGImage : NSObject
@end

@implementation SPDFMacSVGImage
// Installing these only stores function pointers; nothing is decoded until a document shows an SVG.
+ (void)load {
    SPDFMarkdownSetSVGDecoder(SPDFMacSVGImageFromData);
    SPDFMarkdownSetVectorRecolorer(SPDFMacSVGImageDarkPDF);
}
@end
