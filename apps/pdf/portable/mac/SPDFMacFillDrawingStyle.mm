#import "SPDFMacFillDrawingStyle.h"

#import "SPDFMacStateDirectory.h"
#import "SPDFMacSupport.h"

#include "spdf_recolor.h"

#include <sys/stat.h>

static const SPDFFillRGB kColors[] = {{0.89f, 0.16f, 0.13f}, {0.11f, 0.37f, 0.86f}, {0.14f, 0.58f, 0.27f}, {0, 0, 0}};
static NSString* const kColorNames[] = {@"Red", @"Blue", @"Green", @"Black"};
static const CGFloat kWidths[] = {1, 2, 4};
static NSString* const kWidthNames[] = {@"Thin", @"Medium", @"Thick"};
static const CGFloat kEraserSizes[] = {8, 16, 32};
static NSString* const kEraserSizeNames[] = {@"Small", @"Medium", @"Large"};

static NSInteger SPDFClampIndex(NSInteger index, NSInteger count, NSInteger fallback) {
    return index >= 0 && index < count ? index : fallback;
}

@implementation SPDFMacFillDrawingStyle {
    BOOL _loading;
}

+ (instancetype)sharedStyle {
    static SPDFMacFillDrawingStyle* style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      style = [SPDFMacFillDrawingStyle new];
      [style load];
    });
    return style;
}

- (instancetype)init {
    if ((self = [super init])) {
        _widthIndex = 1;
        _eraserSizeIndex = 1;
    }
    return self;
}

- (NSString*)path {
    return [[SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"FillSign"]
        stringByAppendingPathComponent:@"drawing.json"];
}

- (void)load {
    NSData* data = [NSData dataWithContentsOfFile:[self path]];
    NSDictionary* saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![saved isKindOfClass:NSDictionary.class]) return;
    _loading = YES;
    if ([saved[@"color"] isKindOfClass:NSNumber.class]) self.colorIndex = [saved[@"color"] integerValue];
    if ([saved[@"width"] isKindOfClass:NSNumber.class]) self.widthIndex = [saved[@"width"] integerValue];
    if ([saved[@"eraser"] isKindOfClass:NSString.class]) self.eraserParts = [saved[@"eraser"] isEqual:@"parts"];
    if ([saved[@"eraserSize"] isKindOfClass:NSNumber.class]) self.eraserSizeIndex = [saved[@"eraserSize"] integerValue];
    _loading = NO;
}

- (void)save {
    if (_loading) return;
    spdf_mac_support_directory();  // creates the state folder itself
    NSString* folder = [[self path] stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    NSDictionary* saved = @{
        @"color" : @(self.colorIndex),
        @"width" : @(self.widthIndex),
        @"eraser" : self.eraserParts ? @"parts" : @"lines",
        @"eraserSize" : @(self.eraserSizeIndex),
    };
    NSData* data = [NSJSONSerialization dataWithJSONObject:saved options:NSJSONWritingSortedKeys error:nil];
    NSString* path = [self path];
    NSString* temp = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    if (![data writeToFile:temp options:0 error:nil]) return;
    chmod(temp.fileSystemRepresentation, 0600);
    if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) unlink(temp.fileSystemRepresentation);
}

- (void)setColorIndex:(NSInteger)index {
    _colorIndex = SPDFClampIndex(index, [SPDFMacFillDrawingStyle colorCount], 0);
    [self save];
}

- (void)setWidthIndex:(NSInteger)index {
    _widthIndex = SPDFClampIndex(index, [SPDFMacFillDrawingStyle widthCount], 1);
    [self save];
}

- (void)setEraserParts:(BOOL)parts {
    _eraserParts = parts;
    [self save];
}

- (void)setEraserSizeIndex:(NSInteger)index {
    _eraserSizeIndex = SPDFClampIndex(index, [SPDFMacFillDrawingStyle eraserSizeCount], 1);
    [self save];
}

- (SPDFFillRGB)color { return kColors[self.colorIndex]; }
- (CGFloat)width { return kWidths[self.widthIndex]; }
- (CGFloat)eraserSize { return kEraserSizes[self.eraserSizeIndex]; }

+ (NSInteger)colorCount { return sizeof(kColors) / sizeof(kColors[0]); }
+ (SPDFFillRGB)colorAtIndex:(NSInteger)index { return kColors[SPDFClampIndex(index, [self colorCount], 0)]; }
+ (NSString*)colorNameAtIndex:(NSInteger)index { return kColorNames[SPDFClampIndex(index, [self colorCount], 0)]; }
+ (NSInteger)widthCount { return sizeof(kWidths) / sizeof(kWidths[0]); }
+ (CGFloat)widthAtIndex:(NSInteger)index { return kWidths[SPDFClampIndex(index, [self widthCount], 1)]; }
+ (NSString*)widthNameAtIndex:(NSInteger)index { return kWidthNames[SPDFClampIndex(index, [self widthCount], 1)]; }
+ (NSInteger)eraserSizeCount { return sizeof(kEraserSizes) / sizeof(kEraserSizes[0]); }
+ (CGFloat)eraserSizeAtIndex:(NSInteger)index {
    return kEraserSizes[SPDFClampIndex(index, [self eraserSizeCount], 1)];
}
+ (NSString*)eraserSizeNameAtIndex:(NSInteger)index {
    return kEraserSizeNames[SPDFClampIndex(index, [self eraserSizeCount], 1)];
}

+ (NSInteger)indexOfColor:(SPDFFillRGB)color {
    for (NSInteger i = 0; i < [self colorCount]; ++i)
        if (fabsf(kColors[i].r - color.r) < 0.01f && fabsf(kColors[i].g - color.g) < 0.01f &&
            fabsf(kColors[i].b - color.b) < 0.01f)
            return i;
    return -1;
}

+ (NSInteger)indexOfWidth:(CGFloat)width {
    for (NSInteger i = 0; i < [self widthCount]; ++i)
        if (fabs(kWidths[i] - width) < 0.01) return i;
    return -1;
}

@end

NSColor* SPDFFillScreenColor(SPDFFillRGB color, BOOL darkPages) {
    if (!darkPages) return [NSColor colorWithSRGBRed:color.r green:color.g blue:color.b alpha:1];
    static spdf_recolor_table table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
    });
    unsigned char pixel[4] = {(unsigned char)lroundf(color.r * 255), (unsigned char)lroundf(color.g * 255),
                              (unsigned char)lroundf(color.b * 255), 255};
    spdf_recolor_rgba_span(pixel, 0, 1, &table);
    return [NSColor colorWithSRGBRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
}
