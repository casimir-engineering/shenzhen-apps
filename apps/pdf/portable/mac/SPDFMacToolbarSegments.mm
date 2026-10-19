#import "SPDFMacIconGeometry.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacSupport.h"

// Native keyboard/AX remains intact; explicit mouse geometry and drawing prevent the
// inactive-window and disabled tints from fading an icon a second time.
@interface SPDFReadableToolbarSegments : NSSegmentedControl
@property(nonatomic) NSInteger pressedSegment;
@property(nonatomic) BOOL dispatchingMouseAction;
@end
@implementation SPDFReadableToolbarSegments
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) {
        _pressedSegment=-1; SPDFConfigureIconViewRendering(self);
    }
    return self;
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsDisplay=YES; }
- (NSInteger)selectedSegment { return self.dispatchingMouseAction ? self.pressedSegment : super.selectedSegment; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (NSRect)frameForSegment:(NSInteger)segment {
    return NSMakeRect(segment*NSWidth(self.bounds)/self.segmentCount,0,
        NSWidth(self.bounds)/self.segmentCount,NSHeight(self.bounds));
}
- (void)mouseDown:(NSEvent*)event {
    if (!self.enabled || !self.segmentCount) return;
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    for (NSInteger i=0;i<self.segmentCount;i++) if (NSPointInRect(point,[self frameForSegment:i])) {
        if (![self isEnabledForSegment:i]) return;
        self.pressedSegment=i; self.selectedSegment=i; [self setNeedsDisplay:YES];
        // Drawing and hit testing use the same rectangles. Avoid native segment
        // tracking across zoom/reflow, which can swallow repeated/edge clicks.
        self.dispatchingMouseAction=YES;
        [self sendAction:self.action to:self.target];
        self.dispatchingMouseAction=NO; self.selectedSegment=-1;
        __weak SPDFReadableToolbarSegments* weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            weakSelf.pressedSegment=-1; [weakSelf setNeedsDisplay:YES];
        });
        return;
    }
}
- (void)mouseUp:(NSEvent*)event { (void)event; self.pressedSegment=-1; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty; if (!self.segmentCount) return;
    NSRect bounds = NSInsetRect(self.bounds,1,2);
    if (self.segmentCount > 1 || self.cell.highlighted) {
        [[NSColor.labelColor colorWithAlphaComponent:.025] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:5 yRadius:5] fill];
    }
    NSBezierPath* outline=[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:5 yRadius:5];
    for (NSInteger segment=0; segment<self.segmentCount; segment++) {
        NSRect frame=[self frameForSegment:segment];
        if (self.pressedSegment==segment) {
            [NSGraphicsContext saveGraphicsState]; [outline addClip];
            [[NSColor.labelColor colorWithAlphaComponent:.08] setFill]; NSRectFillUsingOperation(frame,NSCompositingOperationSourceOver);
            [NSGraphicsContext restoreGraphicsState];
        }
        if (segment>0) { [[NSColor.labelColor colorWithAlphaComponent:.09] setFill];
            NSRectFillUsingOperation(NSMakeRect(NSMinX(frame),NSMinY(bounds)+5,.5,NSHeight(bounds)-10),NSCompositingOperationSourceOver); }

        NSColor* color = SPDFChromeIconColor(self.enabled && [self isEnabledForSegment:segment]);
        NSImage* image = [self imageForSegment:segment];
        NSRect slot=NSMakeRect(floor(NSMidX(frame)-8),floor(NSMidY(frame)-8),16,16);
        // Tint in the destination context, without a size-specific NSImage cache.
        [NSGraphicsContext saveGraphicsState];
        CGContextRef context=NSGraphicsContext.currentContext.CGContext;
        CGContextBeginTransparencyLayer(context,NULL);
        SPDFDrawVectorIcon(image,slot,self.isFlipped);
        [color setFill]; NSRectFillUsingOperation(slot,NSCompositingOperationSourceIn);
        CGContextEndTransparencyLayer(context); [NSGraphicsContext restoreGraphicsState];
    }
    if (self.window.firstResponder == self) {
        [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly);
        [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:5 yRadius:5] fill]; [NSGraphicsContext restoreGraphicsState];
    }
}
@end

// Compact two-segment momentary "pill" for a paired back/forward style toolbar
// action; the shared action switches on selectedSegment (0 = leading,
// 1 = trailing).
// One configuration for every toolbar pill, so a single-segment control and a
// paired one share background, height and icon tint exactly.
static NSSegmentedControl* spdf_toolbar_segments(id target, SEL action, NSInteger segmentCount) {
    NSSegmentedControl* control = [[SPDFReadableToolbarSegments alloc] init];
    control.segmentCount = segmentCount;
    control.segmentStyle = NSSegmentStyleRounded;
    control.trackingMode = NSSegmentSwitchTrackingMomentary;
    control.target = target;
    control.action = action;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [control setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    return control;
}

NSSegmentedControl* spdf_paired_toolbar_segments(id target, SEL action, NSImage* leadingImage, NSImage* trailingImage) {
    NSSegmentedControl* control = spdf_toolbar_segments(target, action, 2);
    [control setImage:leadingImage forSegment:0];
    [control setImage:trailingImage forSegment:1];
    return control;
}

NSSegmentedControl* spdf_single_toolbar_segment(id target, SEL action, NSImage* image) {
    NSSegmentedControl* control = spdf_toolbar_segments(target, action, 1);
    [control setImage:image forSegment:0];
    return control;
}
