#pragma once
#import <Cocoa/Cocoa.h>
static inline NSImage* SPDFGroupExpansionImage(BOOL collapse) {
    static NSImage* images[2]; static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSUInteger index=0;index<2;index++) {
            BOOL inward=index==1;
            images[index]=[NSImage imageWithSize:NSMakeSize(20,20) flipped:NO drawingHandler:^BOOL(NSRect rect) {
                (void)rect; [NSColor.blackColor setStroke];
                NSBezierPath* outline=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1,1,18,18) xRadius:4 yRadius:4];
                outline.lineWidth=1.4; [outline stroke];
                NSBezierPath* arrows=[NSBezierPath bezierPath]; arrows.lineWidth=1.4;
                arrows.lineCapStyle=NSLineCapStyleRound; arrows.lineJoinStyle=NSLineJoinStyleRound;
                if (inward) {
                    [arrows moveToPoint:NSMakePoint(15,15)]; [arrows lineToPoint:NSMakePoint(11.5,11.5)];
                    [arrows moveToPoint:NSMakePoint(11.5,15)]; [arrows lineToPoint:NSMakePoint(11.5,11.5)]; [arrows lineToPoint:NSMakePoint(15,11.5)];
                    [arrows moveToPoint:NSMakePoint(5,5)]; [arrows lineToPoint:NSMakePoint(8.5,8.5)];
                    [arrows moveToPoint:NSMakePoint(5,8.5)]; [arrows lineToPoint:NSMakePoint(8.5,8.5)]; [arrows lineToPoint:NSMakePoint(8.5,5)];
                } else {
                    [arrows moveToPoint:NSMakePoint(11,11)]; [arrows lineToPoint:NSMakePoint(15,15)];
                    [arrows moveToPoint:NSMakePoint(11,15)]; [arrows lineToPoint:NSMakePoint(15,15)]; [arrows lineToPoint:NSMakePoint(15,11)];
                    [arrows moveToPoint:NSMakePoint(9,9)]; [arrows lineToPoint:NSMakePoint(5,5)];
                    [arrows moveToPoint:NSMakePoint(5,9)]; [arrows lineToPoint:NSMakePoint(5,5)]; [arrows lineToPoint:NSMakePoint(9,5)];
                }
                [arrows stroke]; return YES;
            }];
            // Match the adjacent scope symbol visually; keep the 26-point hit target.
            images[index].size=NSMakeSize(16,16);
            [images[index] setTemplate:YES];
        }
    });
    return images[collapse ? 1 : 0];
}
