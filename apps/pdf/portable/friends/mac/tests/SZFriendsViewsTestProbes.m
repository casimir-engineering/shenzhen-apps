// Shenzhen Friends views tests: probes for what the person sees and does. Pixels sampled in sRGB, and a clock that
// fires the views' timers, hands them presses and records what VoiceOver is told.

#import "SZFriendsViewsTestSupport.h"

uint32_t SZFTestResolved(NSColor *color, NSAppearanceName name) {
    __block NSColor *srgb = nil;
    [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
        srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return ((uint32_t)lround(srgb.redComponent * 255) << 16) | ((uint32_t)lround(srgb.greenComponent * 255) << 8) |
           (uint32_t)lround(srgb.blueComponent * 255);
}

NSBitmapImageRep *SZFTestBitmap(NSView *view) {
    [view layoutSubtreeIfNeeded];
    NSRect bounds = view.bounds;
    size_t width = (size_t)NSWidth(bounds), height = (size_t)NSHeight(bounds);
    // An sRGB context, so the sampled values are the tokens' own sRGB values: caching into an NSBitmapImageRep
    // converted them through another colour space and #286398 came back as #3278a9.
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                            (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:NO];
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        // The dropdown's background under the view, as the page behind it draws it in the app (default tokens).
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = context;
        [[SZFriendsAppearance new].backgroundColor setFill];
        NSRectFill(NSMakeRect(0, 0, width, height));
        [NSGraphicsContext restoreGraphicsState];
        [view displayRectIgnoringOpacity:bounds inContext:context];
    }];
    CGImageRef image = CGBitmapContextCreateImage(cg);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    CGContextRelease(cg);
    return rep;
}

uint32_t SZFTestBitmapPixel(NSBitmapImageRep *rep, NSInteger x, NSInteger y) {
    // The raw samples, which are sRGB: -colorAtX:y: tags them Generic RGB, and converting that back to sRGB shifts
    // every value (#292b2e read as #36393c).
    NSUInteger samples[4] = {0};
    [rep getPixel:samples atX:x y:y];
    return (uint32_t)((samples[0] << 16) | (samples[1] << 8) | samples[2]);
}

uint32_t SZFTestPixelAt(NSView *view, NSPoint point) {
    NSBitmapImageRep *rep = SZFTestBitmap(view);
    // Bitmap rows run top-down whatever the view's flippedness, as do the Friends views' coordinates.
    CGFloat y = view.isFlipped ? point.y : NSHeight(view.bounds) - point.y;
    return SZFTestBitmapPixel(rep, (NSInteger)floor(point.x), (NSInteger)floor(y));
}

BOOL SZFTestSameColor(uint32_t a, uint32_t b, int tolerance) {
    for (int shift = 0; shift <= 16; shift += 8)
        if (abs((int)((a >> shift) & 255) - (int)((b >> shift) & 255)) > tolerance) return NO;
    return YES;
}

@implementation SZFTestClock
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _blocks = [NSMutableArray array];
    _delays = [NSMutableArray array];
    _spoken = [NSMutableArray array];
    _notifiedElements = [NSMutableArray array];
    _now = 1000;
    _clickCount = 1;
    return self;
}
@end

void SZFTestInstallClock(SZFriendsContext *context, SZFTestClock *clock) {
    context.scheduleAfter = ^(NSTimeInterval seconds, dispatch_block_t block) {
        [clock.delays addObject:@(seconds)];
        [clock.blocks addObject:block];
    };
    context.currentPress = ^SZFriendsPress(void) { return (SZFriendsPress){clock.now, clock.clickCount}; };
    context.postAccessibility = ^(id element, NSAccessibilityNotificationName name, NSDictionary *info) {
        NSString *text = info[NSAccessibilityAnnouncementKey];
        BOOL high = [info[NSAccessibilityPriorityKey] integerValue] == NSAccessibilityPriorityHigh;
        [clock.spoken addObject:text ? [NSString stringWithFormat:@"%@%@: %@", name, high ? @" (high)" : @"", text]
                                     : name];
        [clock.notifiedElements addObject:element ?: NSNull.null];
    };
}

// The press happens `delay` after the clock's last one; the click count goes back to 1 afterwards.
void SZFTestClickAfter(SZFTestClock *clock, NSButton *button, NSTimeInterval delay, NSInteger clickCount) {
    clock.now += delay;
    clock.clickCount = clickCount;
    [button performClick:nil];
    clock.clickCount = 1;
}
