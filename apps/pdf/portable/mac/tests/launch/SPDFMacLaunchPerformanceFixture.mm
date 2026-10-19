// The launch performance gate's document: a synthetic drawing set, deterministic from its arguments, so a launch
// that restores it costs the same in every run and on every tree (the probe builds against release tags too).
// A3 pages of short stroked curves, one A4 page at index 3, a thick border: the shape of the owner's drawing sets.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

bool SPDFLaunchPerformanceWriteDrawingSet(const char* path, long pages, long curves) {
    @autoreleasepool {
        CGRect a3 = CGRectMake(0, 0, 1190.55, 841.89), a4 = CGRectMake(0, 0, 595.28, 841.89);
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        CGContextRef ctx = CGPDFContextCreateWithURL((__bridge CFURLRef)url, &a3, NULL);
        if (!ctx) return false;
        for (long p = 0; p < pages; p++) {
            CGRect box = p == 3 ? a4 : a3;
            NSData* boxData = [NSData dataWithBytes:&box length:sizeof(box)];
            NSDictionary* info = @{(__bridge NSString*)kCGPDFContextMediaBox : boxData};
            CGPDFContextBeginPage(ctx, (__bridge CFDictionaryRef)info);
            CGContextSetRGBStrokeColor(ctx, 0, 0, 0, 1);
            CGContextSetLineWidth(ctx, 0.5);
            unsigned seed = (unsigned)(p * 7919 + 17);
            for (long i = 0; i < curves; i++) {
                seed = seed * 1103515245u + 12345u;
                CGFloat x = (seed >> 8) % (unsigned)box.size.width;
                seed = seed * 1103515245u + 12345u;
                CGFloat y = (seed >> 8) % (unsigned)box.size.height;
                CGContextBeginPath(ctx);
                CGContextMoveToPoint(ctx, x, y);
                CGContextAddCurveToPoint(ctx, x + 6, y + 3, x + 2, y + 9, x + 11, y + (i % 7));
                CGContextStrokePath(ctx);
            }
            CGContextSetLineWidth(ctx, 3.0);
            CGContextStrokeRect(ctx, CGRectInset(box, 24, 24));
            CGPDFContextEndPage(ctx);
        }
        CGPDFContextClose(ctx);
        CGContextRelease(ctx);
        return true;
    }
}
