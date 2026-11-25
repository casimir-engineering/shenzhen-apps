#pragma once
// Pictures in and out of Annotate's core canvas, and the fonts it draws text with (docs/plans/annotate.md § 5 Files,
// § 8 Mac). ImageIO decodes a picture file into premultiplied RGBA for spdf_paint_open_picture and encodes the
// flattened canvas (spdf_paint_flatten) back in the file's own format with its metadata and colour profile; CoreText
// finds the font files spdf_paint_set_font_resolver asks for. Nothing here runs before Annotate is used.
//
// Encoding and decoding may run on any thread (the session encodes off the main thread); the font resolver is
// installed once on the main thread.
#import <Cocoa/Cocoa.h>

#import "SPDFMacAnnotateSession.h"

#include "spdf_paint.h"

NS_ASSUME_NONNULL_BEGIN

// What kind of document a file is for Annotate: a picture (the formats the reader shows as pictures: PNG, JPEG, GIF,
// BMP, TIFF, HEIC, WebP, camera RAW), a .szpaint project (a canvas), a PDF, or a text document (Markdown, plain text,
// EPUB, XPS, CBZ, FB2, SVG and the rest). By extension and, when the extension says nothing, by UTI.
FOUNDATION_EXPORT SPDFAnnotateDocumentKind SPDFAnnotateDocumentKindForPath(NSString* path);

// A decoded picture and what saving it needs.
@interface SPDFAnnotatePicture : NSObject
@property(nonatomic, readonly) int width;
@property(nonatomic, readonly) int height;
@property(nonatomic, readonly) float dpi;            // 72 when the file says nothing
@property(nonatomic, readonly) BOOL hasAlpha;        // the format keeps transparency (JPEG and BMP don't)
@property(nonatomic, readonly, copy) NSString* format;  // UTI, "public.jpeg"
@property(nonatomic, readonly) NSUInteger frameCount;   // > 1: an animated GIF or HEIC sequence
// Can be written back in place: ImageIO writes the format, and it is not an animation. NO for WebP, camera RAW and
// animated GIF or HEIC (Annotate then saves a copy as PNG).
@property(nonatomic, readonly) BOOL writable;
@property(nonatomic, readonly, copy) NSDictionary* properties;  // the first frame's metadata, written back on save
@property(nonatomic, readonly, nullable) CGColorSpaceRef colorSpace;
// Premultiplied RGBA8 sRGB, width x height, rows top to bottom (valid while this object lives).
@property(nonatomic, readonly) spdf_paint_pixels pixels;
@end

// Decodes a picture file (camera RAW through Core Image, as the reader shows it), oriented as displayed.
FOUNDATION_EXPORT SPDFAnnotatePicture* _Nullable SPDFAnnotateDecodePicture(NSString* path, NSError** error);
// Decodes pasteboard or dropped picture data (PNG, TIFF, any ImageIO format) for picture.add.
FOUNDATION_EXPORT SPDFAnnotatePicture* _Nullable SPDFAnnotateDecodePictureData(NSData* data, NSError** error);
// The first picture on a pasteboard, or nil.
FOUNDATION_EXPORT SPDFAnnotatePicture* _Nullable SPDFAnnotatePictureFromPasteboard(NSPasteboard* pasteboard);

// Encodes premultiplied RGBA (spdf_paint_flatten's bitmap) as `format` (a UTI, or doc.save_as's name: "png", "jpeg",
// "heic", "tiff", "bmp", "gif"), with `properties` (metadata, orientation reset to up) and the colour profile. JPEG
// and HEIC take quality 0-1 (0.92 by default); JPEG and BMP get transparent pixels flattened onto white.
FOUNDATION_EXPORT NSData* _Nullable SPDFAnnotateEncodePicture(const spdf_bitmap* bitmap, NSString* format,
                                                              NSDictionary* _Nullable properties, CGFloat quality,
                                                              NSError** error);
// Writes data to a temporary file in path's folder and swaps it in (as SPDFRotateImageAtPath does), keeping the
// file's permissions; NO with error, the original untouched.
FOUNDATION_EXPORT BOOL SPDFAnnotateWriteFileAtomically(NSData* data, NSString* path, NSError** error);
// Copy, cut and Copy to file: PNG and TIFF of the bitmap on the pasteboard.
FOUNDATION_EXPORT BOOL SPDFAnnotateWriteToPasteboard(const spdf_bitmap* bitmap, NSPasteboard* pasteboard);

// Save As choices, in the order the Save panel lists them: {"format": "png", "title": "PNG", "extension": "png",
// "uti": "public.png"}, ..., the last "szpaint" titled "Shenzhen Paint project".
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFAnnotateSaveFormats(void);
// The format doc.save_as uses for a path's extension, or nil.
FOUNDATION_EXPORT NSString* _Nullable SPDFAnnotateFormatForPath(NSString* path);

// Installs the CoreText font resolver into the core (spdf_paint_set_font_resolver), once. Called the first time a
// text object is drawn or the text bar opens, never at launch.
FOUNDATION_EXPORT void SPDFAnnotateInstallFontResolver(void);
// Font families the text bar lists (NSFontManager's, sorted), fetched once.
FOUNDATION_EXPORT NSArray<NSString*>* SPDFAnnotateFontFamilies(void);

// spdf_paint_color <-> NSColor (sRGB, alpha kept), for the swatches.
FOUNDATION_EXPORT NSColor* SPDFAnnotateColor(spdf_paint_color color);
FOUNDATION_EXPORT spdf_paint_color SPDFAnnotatePaintColor(NSColor* color);
// spdf_paint_color <-> the operations' "#RRGGBB" / "#RRGGBBAA" (alpha written only when not opaque).
FOUNDATION_EXPORT NSString* SPDFAnnotateColorString(spdf_paint_color color);
FOUNDATION_EXPORT BOOL SPDFAnnotateParseColor(id _Nullable value, spdf_paint_color* _Nullable out);

NS_ASSUME_NONNULL_END
