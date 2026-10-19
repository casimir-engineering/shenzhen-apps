#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <initializer_list>
#import "SPDFMacGroupActionButton.h"
#import "SPDFMacIconGeometry.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacSupport.h"

static int failures;
static void Check(BOOL ok,const char* message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message); failures++; }
}
@interface RedrawButton : SPDFGroupActionButton
@property NSUInteger paints;
@end
@implementation RedrawButton
- (void)updateLayer { self.paints++; [super updateLayer]; }
@end
static void Flush(NSWindow* window) {
    [window.contentView displayIfNeeded]; [CATransaction flush];
}
static void CheckNativeResize(NSWindow* window) {
    RedrawButton* button=[[RedrawButton alloc] initWithFrame:NSMakeRect(10,10,40,30)];
    button.image=[NSImage imageWithSystemSymbolName:@"scope" accessibilityDescription:nil];
    button.imagePosition=NSImageOnly; button.bordered=NO;
    [window.contentView addSubview:button]; Flush(window);
    NSUInteger before=button.paints;
    Check(before>0,"offscreen fixture actually paints the native icon");
    button.frame=NSMakeRect(10,10,26,26); Flush(window);
    Check(button.paints>before,"resizing redraws the native icon without a hover event");
    before=button.paints;
    for (int i=0;i<10;i++) { button.frame=button.frame; Flush(window); }
    Check(button.paints==before,"unchanged geometry does no additional drawing");
    [button viewDidChangeBackingProperties]; Flush(window);
    Check(button.paints>before,"a display-scale change invalidates the icon");
    Check(button.image.cacheMode==NSImageCacheNever,"native icon retains its uncached vector source");
    [button removeFromSuperview];
}
static void CheckPanelLayout(NSWindow* window) {
    SPDFSidebarNavigationControl* navigation=[[SPDFSidebarNavigationControl alloc] initWithFrame:NSMakeRect(0,0,240,64)];
    spdf_sidebar_mode_control_configure_navigation(navigation,YES,YES);
    [navigation setCollapseTarget:navigation action:@selector(description)];
    [window.contentView addSubview:navigation];
    // The Chats button raised the reader's minimum sidebar to 208 points;
    // the navigation strip has an 8-point inset on each side.
    NSString* coordinator=[NSString stringWithContentsOfFile:@"mac/ShenzhenPDFMac.mm"
        encoding:NSUTF8StringEncoding error:nil];
    Check([coordinator containsString:@"kMinSidebarWidth = 208.0"],
          "resize coverage matches the reader's minimum sidebar width");
    for (NSUInteger step=0;step<48;step++) {
        navigation.frame=NSMakeRect(.25*(step%4),0,192+.25*step,64);
        navigation.needsLayout=YES; [navigation layoutSubtreeIfNeeded]; Flush(window);
        for (NSButton* row in navigation.accessibilityChildren) {
            if ([row.accessibilityLabel isEqual:@"Hide side panel"]) continue;
            NSRect pixels=[navigation convertRectToBacking:row.frame];
            Check(fabs(NSMinX(pixels)-round(NSMinX(pixels)))<.001 &&
                  fabs(NSMaxX(pixels)-round(NSMaxX(pixels)))<.001,
                  "narrow and fractional panel widths keep icon targets on device pixels");
            Check(NSWidth(row.frame)>=22,"minimum panel preserves usable button targets");
            Check(NSContainsRect(navigation.bounds,row.frame),"every button stays inside the strip");
            NSPoint center=NSMakePoint(NSMidX(row.frame),NSMidY(row.frame));
            Check([navigation hitTest:[navigation convertPoint:center toView:navigation.superview]]==row,
                  "each visible button owns its center hit target");
            for (NSButton* other in navigation.accessibilityChildren)
                if (other!=row) Check(!NSIntersectsRect(row.frame,other.frame),"button targets do not overlap");
            Check(row.layerContentsPlacement==NSViewLayerContentsPlacementCenter,
                  "intermediate resize never stretches an old icon layer");
        }
    }
    [navigation removeFromSuperview];
}
static void CheckVectorDrawing(void) {
    __block NSUInteger draws=0;
    NSImage* source=[NSImage imageWithSize:NSMakeSize(24,12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        draws++; [NSColor.whiteColor setFill]; NSRectFill(rect); return YES;
    }];
    NSImage* icon=SPDFUncachedVectorIcon(source);
    Check(draws==0,"vector setup is lazy and does not rasterize a source");
    for (NSInteger scale=1;scale<=2;scale++) {
        for (NSInteger width : {16,22,28}) {
            NSBitmapImageRep* bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                pixelsWide:32*scale pixelsHigh:32*scale bitsPerSample:8 samplesPerPixel:4
                hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:32*scale*4 bitsPerPixel:32];
            NSGraphicsContext* context=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext=context;
            CGContextScaleCTM(context.CGContext,scale,scale);
            NSUInteger before=draws;
            SPDFDrawVectorIcon(icon,NSMakeRect((32-width)/2.,0,width,32),NO);
            [NSGraphicsContext restoreGraphicsState];
            Check(draws>before,"each destination size/scale draws the vector, not a cached bitmap");
            NSInteger minX=32*scale,minY=minX,maxX=-1,maxY=-1;
            for (NSInteger y=0;y<32*scale;y++) for (NSInteger x=0;x<32*scale;x++) {
                if ([bitmap colorAtX:x y:y].alphaComponent<.5) continue;
                minX=MIN(minX,x); maxX=MAX(maxX,x); minY=MIN(minY,y); maxY=MAX(maxY,y);
            }
            Check(maxX>=minX && fabs((maxX-minX+1)-2*(maxY-minY+1))<=2,
                  "painted wide icon keeps its 2:1 ratio at 1x and 2x");
        }
    }
    for (NSImage* image in @[spdf_ocr_toolbar_image(),spdf_translate_toolbar_image(),
                            spdf_markdown_font_size_toolbar_image(NO),spdf_markdown_font_size_toolbar_image(YES)]) {
        for (NSImageRep* rep in image.representations)
            Check(![rep isKindOfClass:NSBitmapImageRep.class],"toolbar icon sources are symbols or vector drawing handlers");
    }
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(-10000,-10000,320,100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.contentView.wantsLayer=YES;
    CheckNativeResize(window);
    for (NSString* appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
        window.appearance=[NSAppearance appearanceNamed:appearance]; CheckPanelLayout(window);
    }
    CheckVectorDrawing(); Check(!window.visible,"rendering checks never show a window");
    if (!failures) puts("SPDFMacIconRenderingTests passed");
    return failures ? 1 : 0;
} }
