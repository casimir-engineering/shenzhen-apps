#pragma once
#import <Cocoa/Cocoa.h>

// AppKit's offscreen cache omits the active, compositor-backed traffic-light
// fills. Preserve native window/button geometry and render those three fills
// as vectors in documentation fixtures only; never activate the user's app.
static NSBitmapImageRep* SPDFReadmeWindowBitmap(NSWindow* window) {
    NSView* frame=window.contentView.superview;
    [frame layoutSubtreeIfNeeded];
    NSBitmapImageRep* bitmap=[frame bitmapImageRepForCachingDisplayInRect:frame.bounds];
    [window.appearance performAsCurrentDrawingAppearance:^{
        [frame cacheDisplayInRect:frame.bounds toBitmapImageRep:bitmap];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        NSArray* types=@[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)];
        NSArray* colors=@[[NSColor colorWithSRGBRed:1 green:.373 blue:.341 alpha:1],
            [NSColor colorWithSRGBRed:.996 green:.737 blue:.180 alpha:1],
            [NSColor colorWithSRGBRed:.157 green:.784 blue:.251 alpha:1]];
        for(NSUInteger i=0;i<types.count;i++) {
            NSButton* button=[window standardWindowButton:(NSWindowButton)[types[i] unsignedIntegerValue]];
            if(!button || button.hidden) continue;
            NSRect rect=[button convertRect:button.bounds toView:frame];
            if(frame.flipped) rect.origin.y=NSHeight(frame.bounds)-NSMaxY(rect);
            CGFloat diameter=12;
            NSRect dot=NSMakeRect(NSMidX(rect)-diameter/2,NSMidY(rect)-diameter/2,diameter,diameter);
            [colors[i] setFill]; [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }
        [NSGraphicsContext restoreGraphicsState];
    }];
    return bitmap;
}
