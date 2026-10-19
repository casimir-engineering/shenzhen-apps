// Shenzhen Friends views tests: the helper's file previews as the views find them.
//
// Fixture snapshots name previews in the person's real state directory. Tests move each one into the test state
// directory's thumbnails/ and write a PNG of the fixture's size there, so the views load real pictures and nothing
// reads the person's own Friends data.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

#include "client/szfriends_client.h"

NSString *SZFTestThumbnailDirectory(void) {
    char state[SZFRIENDS_PATH_CAP];
    if (szfriends_default_state_dir(state, sizeof state) != SZFRIENDS_OK) return nil;
    NSString *directory = [@(state) stringByAppendingPathComponent:@"thumbnails"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    return directory;
}

BOOL SZFTestWritePreviewPNG(NSString *path, NSInteger width, NSInteger height) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4
                        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (!rep) return NO;
    rep.size = NSMakeSize(width, height);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (height >= width) {
        // A document's first page: a white sheet, a heading, lines of text and a picture.
        [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, 0, width, height));
        [[NSColor colorWithSRGBRed:0.16 green:0.29 blue:0.52 alpha:1] setFill];
        NSRectFill(NSMakeRect(12, height - 28, width - 24, 12));
        [[NSColor colorWithSRGBRed:0.62 green:0.64 blue:0.68 alpha:1] setFill];
        for (CGFloat y = height - 46; y > 64; y -= 9) NSRectFill(NSMakeRect(12, y, width - 24 - (y > 120 ? 0 : 30), 3));
        [[NSColor colorWithSRGBRed:0.85 green:0.55 blue:0.25 alpha:1] setFill];
        NSRectFill(NSMakeRect(12, 14, width / 2, 40));
    } else {
        // A drawing: a pale grid with a bracket's outline.
        [[NSColor colorWithSRGBRed:0.90 green:0.95 blue:1 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, 0, width, height));
        [[NSColor colorWithSRGBRed:0.70 green:0.80 blue:0.92 alpha:1] setFill];
        for (CGFloat x = 8; x < width; x += 16) NSRectFill(NSMakeRect(x, 0, 1, height));
        for (CGFloat y = 8; y < height; y += 16) NSRectFill(NSMakeRect(0, y, width, 1));
        NSBezierPath *bracket = [NSBezierPath bezierPath];
        [bracket moveToPoint:NSMakePoint(30, 30)];
        [bracket lineToPoint:NSMakePoint(width - 40, 30)];
        [bracket lineToPoint:NSMakePoint(width - 40, height - 30)];
        [bracket lineToPoint:NSMakePoint(width - 70, height - 30)];
        [bracket lineToPoint:NSMakePoint(width - 70, 56)];
        [bracket lineToPoint:NSMakePoint(30, 56)];
        [bracket closePath];
        bracket.lineWidth = 3;
        [[NSColor colorWithSRGBRed:0.10 green:0.20 blue:0.40 alpha:1] setStroke];
        [bracket stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

NSDictionary *SZFTestLocalThumbnails(NSDictionary *data) {
    NSArray *items = data[@"items"];
    if (![items isKindOfClass:NSArray.class]) return data;
    NSString *directory = nil;
    NSMutableArray *moved = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSDictionary *thumbnail = [item isKindOfClass:NSDictionary.class] ? item[@"thumbnail"] : nil;
        if (![thumbnail isKindOfClass:NSDictionary.class] || ![thumbnail[@"path"] isKindOfClass:NSString.class]) {
            [moved addObject:item];
            continue;
        }
        directory = directory ?: SZFTestThumbnailDirectory();
        NSString *path = [directory stringByAppendingPathComponent:[thumbnail[@"path"] lastPathComponent]];
        if (![NSFileManager.defaultManager fileExistsAtPath:path])
            SZFTestWritePreviewPNG(path, [thumbnail[@"width"] integerValue], [thumbnail[@"height"] integerValue]);
        NSMutableDictionary *local = [thumbnail mutableCopy];
        local[@"path"] = path;
        NSMutableDictionary *copy = [item mutableCopy];
        copy[@"thumbnail"] = local;
        [moved addObject:copy];
    }
    NSMutableDictionary *result = [data mutableCopy];
    result[@"items"] = moved;
    return result;
}

BOOL SZFTestWaitForPreviews(NSView *root) {
    return SZFTestWaitUntil(5, ^BOOL {
        for (SZFriendsFilePreviewView *preview in SZFTestSubviews(root, SZFriendsFilePreviewView.class))
            if (preview.state == SZFriendsPreviewLoading) return NO;
        return YES;
    });
}
