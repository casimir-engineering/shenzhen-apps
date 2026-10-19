#import <Cocoa/Cocoa.h>
#import "../SPDFMacCollectionStyle.h"
#include <cmath>
#include <cstdio>

static int failures = 0;
static void Expect(NSString* name, BOOL value) {
    printf("%s %s\n",value ? "PASS" : "FAIL",name.UTF8String);
    if (!value) ++failures;
}
static NSBitmapImageRep* Render(NSView* view) {
    NSBitmapImageRep* bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    return bitmap;
}
// Measure visible ink, rather than the different nominal bounds of SF Symbols and text.
static CGFloat InkCenter(NSBitmapImageRep* bitmap, NSRect region, BOOL dark) {
    CGFloat scaleX = bitmap.pixelsWide/bitmap.size.width, scaleY = bitmap.pixelsHigh/bitmap.size.height;
    NSInteger first = bitmap.pixelsHigh, last = -1;
    for (NSInteger y = ceil(NSMinY(region)*scaleY); y < floor(NSMaxY(region)*scaleY); ++y)
        for (NSInteger x = ceil(NSMinX(region)*scaleX); x < floor(NSMaxX(region)*scaleX); ++x) {
            NSColor* pixel = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat luminance = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent)/3;
            if (pixel.alphaComponent > .5 && (dark ? luminance > .68 : luminance < .4)) {
                first = MIN(first,y); last = MAX(last,y);
            }
        }
    return last < 0 ? NAN : (first+last+1)/(2*scaleY);
}
static void CheckAlignment(NSControl* control, NSRect icon, NSRect title, NSString* name, BOOL dark) {
    NSBitmapImageRep* bitmap = Render(control);
    CGFloat symbolCenter = InkCenter(bitmap,icon,dark), textCenter = InkCenter(bitmap,title,dark);
    printf("  %s icon %.2f text %.2f difference %.2f pt\n",name.UTF8String,symbolCenter,textCenter,fabs(symbolCenter-textCenter));
    Expect([name stringByAppendingString:@" visible symbol and label align within 1.5pt"],
        std::isfinite(symbolCenter) && std::isfinite(textCenter) && fabs(symbolCenter-textCenter) <= 1.5);
    NSString* directory = NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_STYLE_EVIDENCE"];
    if (directory.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    }
}
static NSBitmapImageRep* RenderMask(NSSearchField* search, BOOL cellMask) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:320 pixelsHigh:62
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = NSMakeSize(160,31);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSColor.clearColor setFill]; NSRectFillUsingOperation(search.bounds,NSCompositingOperationCopy);
    [NSColor.blackColor setFill];
    if (cellMask) [(NSSearchFieldCell*)search.cell drawFocusRingMaskWithFrame:search.bounds inView:search];
    else [search drawFocusRingMask];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}
static void CheckMask(NSSearchField* search, BOOL cellMask) {
    NSBitmapImageRep* bitmap = RenderMask(search,cellMask);
    NSString* name = cellMask ? @"search cell focus mask" : @"search control focus mask";
    BOOL cornersClear = YES;
    for (NSArray<NSNumber*>* point in @[@[@1,@1],@[@318,@1],@[@1,@60],@[@318,@60]])
        cornersClear &= [bitmap colorAtX:point[0].integerValue y:point[1].integerValue].alphaComponent < .1;
    Expect([name stringByAppendingString:@" has transparent rounded corners"],cornersClear);
    Expect([name stringByAppendingString:@" fills center"],[bitmap colorAtX:160 y:31].alphaComponent > .9);
    Expect([name stringByAppendingString:@" reaches middle of each edge"],
        [bitmap colorAtX:160 y:2].alphaComponent > .9 && [bitmap colorAtX:2 y:31].alphaComponent > .9);
}
int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow* host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,200)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        host.releasedWhenClosed = NO;
        for (NSNumber* darkValue in @[@NO,@YES]) {
            BOOL dark = darkValue.boolValue;
            host.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            [host.appearance performAsCurrentDrawingAppearance:^{
                for (NSArray<NSString*>* item in @[@[@"Documents",@"doc.on.doc"],@[@"Settings",@"gearshape"]]) {
                    NSButton* button = SPDFCollectionButton(item[0],nil,nil,@"nav");
                    button.frame = NSMakeRect(0,0,160,32);
                    button.image = [NSImage imageWithSystemSymbolName:item[1] accessibilityDescription:nil];
                    [host.contentView addSubview:button];
                    CheckAlignment(button,NSMakeRect(8,3,18,26),NSMakeRect(33,3,118,26),
                        [NSString stringWithFormat:@"%@-%@",item[0],dark ? @"dark" : @"light"],dark);
                    [button removeFromSuperview];
                }
                NSPopUpButton* popup = SPDFCollectionPopUp(); [popup addItemsWithTitles:@[@"Unlimited (default)",@"Custom"]];
                popup.frame = NSMakeRect(0,0,170,26); [host.contentView addSubview:popup];
                CheckAlignment(popup,NSMakeRect(148,4,14,18),NSMakeRect(9,4,129,18),
                    dark ? @"Storage-popup-dark" : @"Storage-popup-light",dark);
                [popup removeFromSuperview];
            }];
        }
        NSSearchField* search = SPDFCollectionSearchField(); search.frame = NSMakeRect(0,0,160,31);
        [host.contentView addSubview:search];
        CheckMask(search,YES); CheckMask(search,NO);
        [host close];
    }
    return failures ? 1 : 0;
}
