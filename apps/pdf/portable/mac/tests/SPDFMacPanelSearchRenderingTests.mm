#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "SPDFMacGroupSearchControls.h"

static int failures;
static void Check(BOOL ok,const char* message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message); failures++; }
}
static CGFloat TextRightEdge(NSBitmapImageRep* bitmap,CGFloat width,BOOL dark) {
    CGFloat scale=bitmap.pixelsWide/width, right=-1;
    for (NSInteger y=ceil(9*scale);y<floor(21*scale);y++)
        for (NSInteger x=ceil(23*scale);x<floor((width-10)*scale);x++) {
            NSColor* pixel=[[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat light=(pixel.redComponent+pixel.greenComponent+pixel.blueComponent)/3;
            if (pixel.alphaComponent>.6 && (dark ? light>.42 : light<.7)) right=MAX(right,x/scale);
        }
    return right;
}
static void CheckRenderedPlaceholder(NSSearchField* field,BOOL dark) {
    [field.window.contentView displayIfNeeded]; [CATransaction flush];
    CGFloat width=NSWidth(field.bounds),scale=field.window.backingScaleFactor;
    NSInteger pixelsWide=ceil(width*scale),pixelsHigh=ceil(NSHeight(field.bounds)*scale);
    NSBitmapImageRep* layer=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pixelsWide pixelsHigh:pixelsHigh bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:pixelsWide*4 bitsPerPixel:32];
    NSGraphicsContext* context=[NSGraphicsContext graphicsContextWithBitmapImageRep:layer];
    CGContextTranslateCTM(context.CGContext,0,pixelsHigh); CGContextScaleCTM(context.CGContext,scale,-scale);
    [field.layer renderInContext:context.CGContext];
    // Compare the painted suffix with the complete label's typographic extent.
    // Native cacheDisplay/cell drawing can both reuse the same clipped text layer,
    // so neither is an independent reference once the field has been displayed.
    NSRect text=[(NSSearchFieldCell*)field.cell searchTextRectForBounds:field.bounds];
    CGFloat expected=NSMinX(text)+[field.placeholderString sizeWithAttributes:@{NSFontAttributeName:field.font}].width;
    CGFloat actual=TextRightEdge(layer,width,dark);
    fprintf(stdout,"Placeholder %.0fpt %s: label %.1f layer %.1f (%s)\n",width,dark ? "dark" : "light",
        expected,actual,field.placeholderString.UTF8String);
    Check(expected>30,"fixture contains visible placeholder text");
    Check(fabs(actual-expected)<=3,"native layer paints the complete placeholder suffix");
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(-10000,-10000,300,100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.contentView.wantsLayer=YES;
    for (NSNumber* darkValue in @[@NO,@YES]) {
        BOOL dark=darkValue.boolValue;
        window.appearance=[NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        for (NSNumber* widthValue in @[@140,@176,@188,@208,@240]) {
            NSSearchField* field=[[NSSearchField alloc] initWithFrame:NSMakeRect(5,10,widthValue.doubleValue,30)];
            SPDFConfigurePanelSearchField(field); SPDFUpdateGroupSearchPlaceholder(field);
            [window.contentView addSubview:field];
            CheckRenderedPlaceholder(field,dark);
            field.stringValue=@"a document query";
            NSRect typed=[field.cell drawingRectForBounds:field.bounds];
            NSRect cancel=[(NSSearchFieldCell*)field.cell cancelButtonRectForBounds:field.bounds];
            Check(NSMaxX(typed)<NSMinX(cancel),"typed query still leaves room for its clear button");
            field.stringValue=@""; SPDFUpdateGroupSearchPlaceholder(field);
            CheckRenderedPlaceholder(field,dark);
            [field removeFromSuperview];
        }
    }
    Check(!window.visible,"search rendering checks never show a window");
    if (!failures) puts("SPDFMacPanelSearchRenderingTests passed");
    return failures ? 1 : 0;
} }
