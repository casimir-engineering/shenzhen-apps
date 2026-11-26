// Pictures in and out of Annotate's core canvas, and its fonts (SPDFMacAnnotateImageIO.h).
//
// Decoding draws the picture, oriented as displayed, into one premultiplied sRGB RGBA buffer the core takes as its
// Background. Encoding goes the other way with the file's own metadata (orientation reset, since the pixels are
// already turned) and, for an RGB picture with its own profile, converted back into that profile so a Display P3
// photo stays Display P3. Nothing here is touched before Annotate is used.
#import "SPDFMacAnnotateImageIO.h"

#import "SPDFMacAnnotateIntegration.h"

#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/stat.h>

static NSString* const kSPDFAnnotateErrorDomain = @"ShenzhenPDF.Annotate";

static NSError* AnnotateError(NSString* message) {
    return [NSError errorWithDomain:kSPDFAnnotateErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Document kinds

static NSSet<NSString*>* PictureExtensions(void) {
    static NSSet* set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"png", @"jpg", @"jpeg", @"jpe", @"jfif", @"jfif-tbnl", @"bmp", @"gif", @"tif", @"tiff", @"heic", @"heif",
            @"webp", @"jp2", @"jpx", @"j2k", @"psd", @"pnm", @"pam", @"pbm", @"pgm", @"ppm", @"pfm", @"jb2", @"jbig2",
            @"raw", @"raw10", @"cr2", @"cr3", @"crw", @"nef", @"nrw", @"arw", @"sr2", @"srf", @"orf", @"raf", @"rw2",
            @"rwl", @"pef", @"dng", @"srw", @"3fr", @"fff", @"iiq", @"x3f"
        ]];
    });
    return set;
}

SPDFAnnotateDocumentKind SPDFAnnotateDocumentKindForPath(NSString* path) {
    NSString* ext = path.pathExtension.lowercaseString;
    if (!path.length) return SPDFAnnotateDocumentNone;
    if ([ext isEqualToString:@"pdf"]) return SPDFAnnotateDocumentPDF;
    if ([ext isEqualToString:@"szpaint"]) return SPDFAnnotateDocumentCanvas;
    if ([PictureExtensions() containsObject:ext]) return SPDFAnnotateDocumentPicture;
    if (!ext.length) {
        UTType* type = nil;
        [[NSURL fileURLWithPath:path] getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
        if ([type conformsToType:UTTypePDF]) return SPDFAnnotateDocumentPDF;
        if ([type conformsToType:UTTypeImage] && ![type conformsToType:UTTypeSVG]) return SPDFAnnotateDocumentPicture;
    }
    return SPDFAnnotateDocumentText;  // Markdown, plain text, EPUB, XPS, CBZ, FB2, SVG and the rest
}

#pragma mark - The decoded picture

@interface SPDFAnnotatePicture ()
@property(nonatomic, readwrite) int width;
@property(nonatomic, readwrite) int height;
@property(nonatomic, readwrite) float dpi;
@property(nonatomic, readwrite) BOOL hasAlpha;
@property(nonatomic, readwrite, copy) NSString* format;
@property(nonatomic, readwrite) NSUInteger frameCount;
@property(nonatomic, readwrite) BOOL writable;
@property(nonatomic, readwrite, copy) NSDictionary* properties;
@property(nonatomic, strong) NSMutableData* bytes;
@end

@implementation SPDFAnnotatePicture {
    CGColorSpaceRef _colorSpace;
}
- (void)dealloc {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}
- (CGColorSpaceRef)colorSpace {
    return _colorSpace;
}
- (void)takeColorSpace:(CGColorSpaceRef)space {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
    _colorSpace = space ? CGColorSpaceRetain(space) : NULL;
}
- (spdf_paint_pixels)pixels {
    spdf_paint_pixels pixels = {self.width, self.height, self.width * 4, (const unsigned char*)self.bytes.bytes, 0};
    return pixels;
}
@end

static BOOL TypeIsCameraRaw(NSString* uti) {
    UTType* type = uti.length ? [UTType typeWithIdentifier:uti] : nil;
    return type && [type conformsToType:UTTypeRAWImage];
}

static BOOL TypeIsWritable(NSString* uti) {
    if (!uti.length || TypeIsCameraRaw(uti) || [uti isEqualToString:@"org.webmproject.webp"]) return NO;
    NSArray* types = CFBridgingRelease(CGImageDestinationCopyTypeIdentifiers());
    return [types containsObject:uti];
}

// The picture drawn upright into premultiplied sRGB RGBA. `image` is already oriented.
static SPDFAnnotatePicture* PictureFromImage(CGImageRef image, NSError** error) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!width || !height) {
        if (error) *error = AnnotateError(@"This picture is empty.");
        return nil;
    }
    if (width > SPDF_PAINT_MAX_SIDE || height > SPDF_PAINT_MAX_SIDE ||
        (unsigned long long)width * height > SPDF_PAINT_MAX_PIXELS) {
        if (error) *error = AnnotateError(@"This picture is too large to annotate (at most 16384 x 16384 pixels).");
        return nil;
    }
    SPDFAnnotatePicture* picture = [SPDFAnnotatePicture new];
    picture.bytes = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(picture.bytes.mutableBytes, width, height, 8, width * 4, srgb,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(srgb);
    if (!context) {
        if (error) *error = AnnotateError(@"There isn't enough memory to open this picture.");
        return nil;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    picture.width = (int)width;
    picture.height = (int)height;
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    picture.hasAlpha = alpha != kCGImageAlphaNone && alpha != kCGImageAlphaNoneSkipLast &&
                       alpha != kCGImageAlphaNoneSkipFirst;
    [picture takeColorSpace:CGImageGetColorSpace(image)];
    return picture;
}

static SPDFAnnotatePicture* DecodeSource(CGImageSourceRef source, NSURL* url, NSError** error) {
    NSString* type = (__bridge NSString*)CGImageSourceGetType(source) ?: @"";
    size_t count = CGImageSourceGetCount(source);
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) ?: @{};
    CGImageRef image = NULL;
    if (url && TypeIsCameraRaw(type)) {
        // As the reader develops it (SPDFMacCameraRaw.mm): Core Image's RAW decoder, orientation applied.
        CIRAWFilter* raw = [CIRAWFilter filterWithImageURL:url];
        CIImage* output = raw.outputImage;
        if (output && !CGRectIsInfinite(output.extent)) {
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CIContext* context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
            image = [context createCGImage:output fromRect:CGRectIntegral(output.extent) format:kCIFormatRGBA8
                                colorSpace:srgb];
            CGColorSpaceRelease(srgb);
        }
    }
    if (!image) {
        double w = [properties[(NSString*)kCGImagePropertyPixelWidth] doubleValue];
        double h = [properties[(NSString*)kCGImagePropertyPixelHeight] doubleValue];
        // The thumbnail call at full size is ImageIO's one way to get the pixels already turned by their EXIF
        // orientation, which is how the reader shows the picture.
        NSDictionary* options = @{
            (NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (NSString*)kCGImageSourceShouldCacheImmediately: @YES,
            (NSString*)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1.0, MAX(w, h))),
        };
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    }
    if (!image) {
        if (error) *error = AnnotateError(@"This picture can't be read.");
        return nil;
    }
    SPDFAnnotatePicture* picture = PictureFromImage(image, error);
    CGImageRelease(image);
    if (!picture) return nil;
    picture.format = type;
    picture.frameCount = count;
    picture.properties = properties;
    picture.writable = TypeIsWritable(type) && count <= 1;
    if ([type isEqualToString:@"public.jpeg"] || [type isEqualToString:@"com.microsoft.bmp"]) picture.hasAlpha = NO;
    double dpi = [properties[(NSString*)kCGImagePropertyDPIWidth] doubleValue];
    picture.dpi = dpi > 0 ? (float)dpi : 72.0f;
    return picture;
}

SPDFAnnotatePicture* SPDFAnnotateDecodePicture(NSString* path, NSError** error) {
    if (error) *error = nil;
    NSURL* url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                                                         (__bridge CFDictionaryRef)@{(NSString*)kCGImageSourceShouldCache: @NO});
    if (!source) {
        if (error) *error = AnnotateError(@"This picture can't be read.");
        return nil;
    }
    SPDFAnnotatePicture* picture = DecodeSource(source, url, error);
    CFRelease(source);
    return picture;
}

SPDFAnnotatePicture* SPDFAnnotateDecodePictureData(NSData* data, NSError** error) {
    if (error) *error = nil;
    CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    if (!source) {
        if (error) *error = AnnotateError(@"This picture can't be read.");
        return nil;
    }
    SPDFAnnotatePicture* picture = DecodeSource(source, nil, error);
    CFRelease(source);
    return picture;
}

// A picture file copied in Finder comes first: Finder also puts the file's icon on the pasteboard as TIFF.
static NSArray<NSURL*>* PictureFiles(NSPasteboard* pasteboard) {
    NSMutableArray* files = [NSMutableArray array];
    for (NSURL* url in [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}])
        if (SPDFAnnotateDocumentKindForPath(url.path) == SPDFAnnotateDocumentPicture) [files addObject:url];
    return files;
}

static NSArray<NSPasteboardType>* PictureTypes(void) {
    return @[NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg", @"public.heic"];
}

SPDFAnnotatePicture* SPDFAnnotatePictureFromPasteboard(NSPasteboard* pasteboard) {
    for (NSURL* url in PictureFiles(pasteboard)) {
        SPDFAnnotatePicture* picture = SPDFAnnotateDecodePicture(url.path, NULL);
        if (picture) return picture;
    }
    for (NSPasteboardType type in PictureTypes()) {
        NSData* data = [pasteboard dataForType:type];
        SPDFAnnotatePicture* picture = data ? SPDFAnnotateDecodePictureData(data, NULL) : nil;
        if (picture) return picture;
    }
    return nil;
}

BOOL SPDFAnnotatePasteboardHasPicture(NSPasteboard* pasteboard) {
    return [pasteboard availableTypeFromArray:PictureTypes()] != nil || PictureFiles(pasteboard).count > 0;
}

#pragma mark - Encoding

static NSArray<NSDictionary*>* FormatTable(void) {
    static NSArray* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            @{@"format": @"png", @"title": @"PNG", @"extension": @"png", @"uti": @"public.png"},
            @{@"format": @"jpeg", @"title": @"JPEG", @"extension": @"jpg", @"uti": @"public.jpeg"},
            @{@"format": @"heic", @"title": @"HEIC", @"extension": @"heic", @"uti": @"public.heic"},
            @{@"format": @"tiff", @"title": @"TIFF", @"extension": @"tiff", @"uti": @"public.tiff"},
            @{@"format": @"bmp", @"title": @"BMP", @"extension": @"bmp", @"uti": @"com.microsoft.bmp"},
            @{@"format": @"gif", @"title": @"GIF", @"extension": @"gif", @"uti": @"com.compuserve.gif"},
            @{@"format": @"szpaint", @"title": SPDFAnnotateProjectFormatTitle, @"extension": @"szpaint",
              @"uti": @"com.intuition.shenzhenpdf.szpaint"},
        ];
    });
    return table;
}

NSArray<NSDictionary*>* SPDFAnnotateSaveFormats(void) {
    return FormatTable();
}

NSString* SPDFAnnotateFormatForPath(NSString* path) {
    NSString* ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"jpe"]) return @"jpeg";
    if ([ext isEqualToString:@"tif"]) return @"tiff";
    if ([ext isEqualToString:@"heif"]) return @"heic";
    for (NSDictionary* row in FormatTable())
        if ([row[@"extension"] isEqualToString:ext]) return row[@"format"];
    return nil;
}

// doc.save_as's format name, or a UTI, as the UTI ImageIO writes.
static NSString* UTIForFormat(NSString* format) {
    for (NSDictionary* row in FormatTable())
        if ([row[@"format"] isEqualToString:format] || [row[@"uti"] isEqualToString:format]) return row[@"uti"];
    return format.length && [format containsString:@"."] ? format : @"public.png";
}

static NSDictionary* PropertiesForWrite(NSDictionary* source, size_t width, size_t height, NSString* uti,
                                        CGFloat quality) {
    NSMutableDictionary* properties = [source mutableCopy] ?: [NSMutableDictionary dictionary];
    // The pixels are written upright, at their new size: metadata about the old ones would turn or mislabel them.
    for (NSString* key in @[(NSString*)kCGImagePropertyPixelWidth, (NSString*)kCGImagePropertyPixelHeight,
                            (NSString*)kCGImagePropertyDepth, (NSString*)kCGImagePropertyHasAlpha,
                            (NSString*)kCGImagePropertyColorModel, (NSString*)kCGImagePropertyProfileName,
                            (NSString*)kCGImagePropertyFileContentsDictionary])
        [properties removeObjectForKey:key];
    properties[(NSString*)kCGImagePropertyOrientation] = @1;
    NSMutableDictionary* tiff = [properties[(NSString*)kCGImagePropertyTIFFDictionary] mutableCopy];
    if (tiff) {
        tiff[(NSString*)kCGImagePropertyTIFFOrientation] = @1;
        properties[(NSString*)kCGImagePropertyTIFFDictionary] = tiff;
    }
    NSMutableDictionary* exif = [properties[(NSString*)kCGImagePropertyExifDictionary] mutableCopy];
    if (exif) {
        exif[(NSString*)kCGImagePropertyExifPixelXDimension] = @(width);
        exif[(NSString*)kCGImagePropertyExifPixelYDimension] = @(height);
        properties[(NSString*)kCGImagePropertyExifDictionary] = exif;
    }
    // A PNG's own chunk dictionary names the old frame's interlace and gamma; ImageIO writes its own.
    if (![uti isEqualToString:@"public.png"]) [properties removeObjectForKey:(NSString*)kCGImagePropertyPNGDictionary];
    if ([uti isEqualToString:@"public.jpeg"] || [uti isEqualToString:@"public.heic"])
        properties[(NSString*)kCGImageDestinationLossyCompressionQuality] = @(quality > 0 ? quality : 0.92);
    return properties;
}

static CGImageRef CreateImage(const spdf_bitmap* bitmap, BOOL opaqueOnWhite, CGColorSpaceRef target) {
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bitmap->rgba,
                                                              (size_t)bitmap->stride * (size_t)bitmap->height, NULL);
    CGImageRef image = CGImageCreate((size_t)bitmap->width, (size_t)bitmap->height, 8, 32, (size_t)bitmap->stride,
                                     srgb, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL,
                                     false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    BOOL convert = target && CGColorSpaceGetModel(target) == kCGColorSpaceModelRGB && !CFEqual(target, srgb);
    CGColorSpaceRelease(srgb);
    if (!image || (!opaqueOnWhite && !convert)) return image;
    // JPEG and BMP have no alpha: flattened onto white, as Paint and Preview do. A picture with its own RGB profile
    // gets its pixels back in that profile.
    CGColorSpaceRef space = convert ? target : CGImageGetColorSpace(image);
    CGBitmapInfo info = opaqueOnWhite ? (CGBitmapInfo)kCGImageAlphaNoneSkipLast
                                      : (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)bitmap->width, (size_t)bitmap->height, 8, 0, space,
                                                 info | kCGBitmapByteOrder32Big);
    if (!context) return image;
    CGRect all = CGRectMake(0, 0, bitmap->width, bitmap->height);
    if (opaqueOnWhite) {
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, all);
    }
    CGContextDrawImage(context, all, image);
    CGImageRef converted = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageRelease(image);
    return converted;
}

NSData* SPDFAnnotateEncodePicture(const spdf_bitmap* bitmap, NSString* format, NSDictionary* properties,
                                  CGFloat quality, NSError** error) {
    if (error) *error = nil;
    if (!bitmap || !bitmap->rgba || bitmap->width <= 0 || bitmap->height <= 0) {
        if (error) *error = AnnotateError(@"There is nothing to save.");
        return nil;
    }
    NSString* uti = UTIForFormat(format);
    BOOL opaque = [uti isEqualToString:@"public.jpeg"] || [uti isEqualToString:@"com.microsoft.bmp"];
    CGColorSpaceRef target = NULL;
    NSString* profile = properties[(NSString*)kCGImagePropertyProfileName];
    if ([profile isKindOfClass:NSString.class] && [profile containsString:@"P3"])
        target = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGImageRef image = CreateImage(bitmap, opaque, target);
    if (target) CGColorSpaceRelease(target);
    if (!image) {
        if (error) *error = AnnotateError(@"There isn't enough memory to save this picture.");
        return nil;
    }
    NSMutableData* data = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)uti, 1, NULL);
    BOOL ok = destination != NULL;
    if (ok) {
        NSDictionary* write = PropertiesForWrite(properties, (size_t)bitmap->width, (size_t)bitmap->height, uti, quality);
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)write);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    if (!ok || !data.length) {
        if (error) *error = AnnotateError(@"This picture couldn't be written in that format.");
        return nil;
    }
    return data;
}

BOOL SPDFAnnotateWriteFileAtomically(NSData* data, NSString* path, NSError** error) {
    if (error) *error = nil;
    NSString* folder = path.stringByDeletingLastPathComponent;
    NSString* temporary = [folder stringByAppendingPathComponent:
                                      [@".szpdf-annotate-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![data writeToFile:temporary options:0 error:error]) {
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        if (error && !*error) *error = AnnotateError(@"The picture couldn't be written to its folder.");
        return NO;
    }
    struct stat info;
    mode_t mode = stat(path.fileSystemRepresentation, &info) == 0 ? (info.st_mode & 07777) : 0644;
    chmod(temporary.fileSystemRepresentation, mode);
    if (rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = AnnotateError(@"The picture couldn't be replaced. The original was left unchanged.");
        return NO;
    }
    return YES;
}

BOOL SPDFAnnotateWriteToPasteboard(const spdf_bitmap* bitmap, NSPasteboard* pasteboard) {
    NSData* png = SPDFAnnotateEncodePicture(bitmap, @"png", nil, 0, NULL);
    NSData* tiff = png ? SPDFAnnotateEncodePicture(bitmap, @"tiff", nil, 0, NULL) : nil;
    if (!png) return NO;
    [pasteboard clearContents];
    [pasteboard setData:png forType:NSPasteboardTypePNG];
    if (tiff) [pasteboard setData:tiff forType:NSPasteboardTypeTIFF];
    return YES;
}

#pragma mark - Fonts

// CoreText's file for (family, bold, italic), and the face's index inside a collection (.ttc).
static int ResolveFont(void* user, const char* family, int bold, int italic, char* path_out, size_t path_cap,
                       int* face_index) {
    (void)user;
    @autoreleasepool {
        NSString* name = family && family[0] ? @(family) : nil;
        CTFontRef base = name ? CTFontCreateWithName((__bridge CFStringRef)name, 12, NULL)
                              : CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12, NULL);
        if (!base) return 0;
        // CTFontCreateWithName falls back to Helvetica for an unknown family: that is not the font asked for.
        NSString* got = CFBridgingRelease(CTFontCopyFamilyName(base));
        if (name && [got caseInsensitiveCompare:name] != NSOrderedSame) {
            CFRelease(base);
            return 0;
        }
        CTFontSymbolicTraits traits = (bold ? kCTFontTraitBold : 0) | (italic ? kCTFontTraitItalic : 0);
        CTFontRef font = traits ? CTFontCreateCopyWithSymbolicTraits(base, 12, NULL, traits, traits) : NULL;
        if (!font) font = (CTFontRef)CFRetain(base);
        CFRelease(base);
        NSURL* url = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
        NSString* postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));
        CFRelease(font);
        if (!url.isFileURL || !url.path.fileSystemRepresentation) return 0;
        const char* path = url.path.fileSystemRepresentation;
        if (strlen(path) + 1 > path_cap) return 0;
        strcpy(path_out, path);
        int index = 0;
        NSString* ext = url.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"ttc"] || [ext isEqualToString:@"otc"]) {
            NSArray* faces = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
            for (NSUInteger i = 0; i < faces.count; ++i) {
                NSString* faceName = CFBridgingRelease(CTFontDescriptorCopyAttribute(
                    (__bridge CTFontDescriptorRef)faces[i], kCTFontNameAttribute));
                if ([faceName isEqualToString:postscript]) {
                    index = (int)i;
                    break;
                }
            }
        }
        if (face_index) *face_index = index;
        return 1;
    }
}

void SPDFAnnotateInstallFontResolver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ spdf_paint_set_font_resolver(ResolveFont, NULL); });
}

NSArray<NSString*>* SPDFAnnotateFontFamilies(void) {
    static NSArray* families;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        families = [[NSFontManager.sharedFontManager availableFontFamilies]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] ?: @[];
    });
    return families;
}

#pragma mark - Colours

NSColor* SPDFAnnotateColor(spdf_paint_color color) {
    return [NSColor colorWithSRGBRed:((color >> 24) & 0xFF) / 255.0 green:((color >> 16) & 0xFF) / 255.0
                                blue:((color >> 8) & 0xFF) / 255.0 alpha:(color & 0xFF) / 255.0];
}

spdf_paint_color SPDFAnnotatePaintColor(NSColor* color) {
    NSColor* srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!srgb) return 0x000000FFu;
    CGFloat c[4] = {0, 0, 0, 1};
    [srgb getRed:&c[0] green:&c[1] blue:&c[2] alpha:&c[3]];
    spdf_paint_color out = 0;
    for (int i = 0; i < 4; ++i) out = (out << 8) | (spdf_paint_color)lround(MAX(0.0, MIN(1.0, c[i])) * 255.0);
    return out;
}

NSString* SPDFAnnotateColorString(spdf_paint_color color) {
    return (color & 0xFF) == 0xFF ? [NSString stringWithFormat:@"#%06X", color >> 8]
                                  : [NSString stringWithFormat:@"#%08X", color];
}

BOOL SPDFAnnotateParseColor(id value, spdf_paint_color* out) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString* text = value;
    if (![text hasPrefix:@"#"] || (text.length != 7 && text.length != 9)) return NO;
    unsigned long long number = 0;
    NSScanner* scanner = [NSScanner scannerWithString:[text substringFromIndex:1]];
    if (![scanner scanHexLongLong:&number] || !scanner.isAtEnd) return NO;
    if (out) *out = text.length == 7 ? (spdf_paint_color)((number << 8) | 0xFF) : (spdf_paint_color)number;
    return YES;
}
