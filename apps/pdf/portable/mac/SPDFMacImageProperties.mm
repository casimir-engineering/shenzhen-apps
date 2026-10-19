#import "SPDFMacImageProperties.h"
#import <ImageIO/ImageIO.h>
#include "spdf_image_properties.h"

BOOL SPDFPathIsRasterImage(NSString* path) {
    NSString* ext = path.pathExtension.lowercaseString;
    // Match SPDFNativeDocumentExtensions' linked raster decoders, not system-wide UTIs.
    return ext.length && [@[@"png", @"jpg", @"jpeg", @"jpe", @"jfif-tbnl", @"jfif", @"bmp", @"gif",
        @"tif", @"tiff", @"jp2", @"jpx", @"j2k", @"jb2", @"jbig2", @"pnm", @"pam", @"pbm", @"pgm",
        @"ppm", @"pfm", @"psd"] containsObject:ext];
}

static void Row(NSMutableArray* rows, NSString* label, id value, NSString* tooltip = nil) {
    if (!value || ![value description].length) return;
    NSMutableDictionary* row = [@{@"label": label, @"value": [value description]} mutableCopy];
    if (tooltip.length) row[@"tooltip"] = tooltip;
    [rows addObject:row];
}

static void Dimensions(NSMutableArray* rows, double width, double height) {
    if (!(width > 0 && height > 0)) return;
    Row(rows, @"Pixel dimensions", [NSString stringWithFormat:@"%.0f × %.0f pixels", width, height],
        @"Stored pixel dimensions before applying orientation metadata.");
    Row(rows, @"Megapixels", [NSString stringWithFormat:@"%.3g MP", width * height / 1000000.0]);
}

NSArray<NSDictionary*>* SPDFImagePropertyRows(NSString* path) {
    if (!SPDFPathIsRasterImage(path)) return @[];
    NSNumber* regular = nil;
    NSURL* url = [NSURL fileURLWithPath:path];
    if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] || !regular.boolValue) return @[];
    NSMutableArray* rows = [NSMutableArray array];
    NSDictionary* options = @{(id)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                        (__bridge CFDictionaryRef)options);
    NSDictionary* info = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0,
                                               (__bridge CFDictionaryRef)options)) : nil;
    double width = [info[(id)kCGImagePropertyPixelWidth] doubleValue];
    double height = [info[(id)kCGImagePropertyPixelHeight] doubleValue];
    if (width <= 0 || height <= 0) {
        if (source) CFRelease(source);
        spdf_image_properties raw = {};
        if (!spdf_read_image_properties(path.fileSystemRepresentation, &raw)) return @[];
        Dimensions(rows, raw.width, raw.height);
        if (raw.colorspace[0]) Row(rows, @"Color space", @(raw.colorspace));
        if (raw.components > 0) Row(rows, @"Color components", @(raw.components));
        // MuPDF defaults DPI and (for most formats) bpc. Do not present those as file metadata.
        return rows;
    }
    Dimensions(rows, width, height);
    double xDPI = [info[(id)kCGImagePropertyDPIWidth] doubleValue];
    double yDPI = [info[(id)kCGImagePropertyDPIHeight] doubleValue];
    if (xDPI > 0 && yDPI > 0)
        Row(rows, @"Resolution", [NSString stringWithFormat:@"%.1f × %.1f dpi", xDPI, yDPI]);
    Row(rows, @"Color model", info[(id)kCGImagePropertyColorModel]);
    Row(rows, @"Color profile", info[(id)kCGImagePropertyProfileName]);
    NSNumber* depth = info[(id)kCGImagePropertyDepth];
    if (depth.integerValue > 0) Row(rows, @"Bit depth", [NSString stringWithFormat:@"%@ bits per component", depth]);
    NSNumber* alpha = info[(id)kCGImagePropertyHasAlpha];
    if (alpha) Row(rows, @"Alpha channel", alpha.boolValue ? @"Yes" : @"No");
    NSInteger orientation = [info[(id)kCGImagePropertyOrientation] integerValue];
    NSArray* orientations = @[@"", @"Normal", @"Mirrored horizontally", @"Rotated 180°", @"Mirrored vertically",
        @"Mirrored, rotated 90° clockwise", @"Rotated 90° clockwise", @"Mirrored, rotated 90° counterclockwise", @"Rotated 90° counterclockwise"];
    if (orientation > 0 && orientation < (NSInteger)orientations.count) Row(rows, @"Orientation", orientations[orientation]);
    size_t count = CGImageSourceGetCount(source);
    if (count > 1) Row(rows, @"Frames / images", @(count));
    NSDictionary* tiff = info[(id)kCGImagePropertyTIFFDictionary];
    NSString* make = tiff[(id)kCGImagePropertyTIFFMake];
    NSString* model = tiff[(id)kCGImagePropertyTIFFModel];
    NSString* camera = [@[make ?: @"", model ?: @""] componentsJoinedByString:@" "];
    Row(rows, @"Camera", [camera stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    NSDictionary* exif = info[(id)kCGImagePropertyExifDictionary];
    Row(rows, @"Captured", exif[(id)kCGImagePropertyExifDateTimeOriginal]);
    double exposure = [exif[(id)kCGImagePropertyExifExposureTime] doubleValue];
    if (exposure > 0) Row(rows, @"Exposure", exposure < 1 ? [NSString stringWithFormat:@"1/%.0f s", 1 / exposure] : [NSString stringWithFormat:@"%.3g s", exposure]);
    double aperture = [exif[(id)kCGImagePropertyExifFNumber] doubleValue];
    if (aperture > 0) Row(rows, @"Aperture", [NSString stringWithFormat:@"ƒ/%.1f", aperture]);
    NSArray* iso = exif[(id)kCGImagePropertyExifISOSpeedRatings];
    if ([iso isKindOfClass:NSArray.class] && iso.count) Row(rows, @"ISO", [iso componentsJoinedByString:@", "]);
    double focal = [exif[(id)kCGImagePropertyExifFocalLength] doubleValue];
    if (focal > 0) Row(rows, @"Focal length", [NSString stringWithFormat:@"%.1f mm", focal]);
    CFRelease(source);
    return rows;
}
