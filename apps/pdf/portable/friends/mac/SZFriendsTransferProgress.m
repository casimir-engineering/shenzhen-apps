// SZFriendsTransferProgress.h. The glyphs are the mockup's SVG paths, read by a small path reader (M, L, H, V, C, A,
// Z and their relative forms), so the three apps' icons stay the same drawing.

#import "mac/SZFriendsTransferProgress.h"

NSColor *SZFriendsTransferRouteColor(NSString *method) {
    uint32_t rgb = [method isEqualToString:@"lan"]         ? 0x22a35a
                   : [method isEqualToString:@"p2p_wifi"]  ? 0x0ea5b0
                   : [method isEqualToString:@"internet"]  ? 0x8b5cf6
                   : [method isEqualToString:@"bluetooth"] ? 0xf59e0b
                                                           : 0x3983f7;
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                               green:((rgb >> 8) & 0xff) / 255.0
                                blue:(rgb & 0xff) / 255.0
                               alpha:1];
}

#pragma mark - SVG paths

// Reads the numbers of a path's data in order ("4.6-5.6" is two numbers, ".4.9" too).
static NSArray<NSNumber *> *SZFPathNumbers(NSString *text, NSUInteger *index) {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    NSUInteger i = *index, n = text.length;
    while (i < n) {
        unichar c = [text characterAtIndex:i];
        if (c == ' ' || c == ',') {
            i++;
            continue;
        }
        if (!(c == '-' || c == '.' || (c >= '0' && c <= '9'))) break;
        NSUInteger start = i;
        BOOL dot = NO;
        if (c == '-') i++;
        while (i < n) {
            unichar d = [text characterAtIndex:i];
            if (d >= '0' && d <= '9') i++;
            else if (d == '.' && !dot) {
                dot = YES;
                i++;
            } else break;
        }
        [numbers addObject:@([[text substringWithRange:NSMakeRange(start, i - start)] doubleValue])];
    }
    *index = i;
    return numbers;
}

// An SVG arc (rx = ry, no rotation, as the mockup's) appended from the current point to (x, y).
static void SZFArc(NSBezierPath *path, NSPoint from, double r, BOOL large, BOOL sweep, double x, double y) {
    double dx = (from.x - x) / 2, dy = (from.y - y) / 2;
    double d2 = dx * dx + dy * dy;
    if (d2 == 0) return;
    if (r * r < d2) r = sqrt(d2);
    double k = sqrt(MAX(0, (r * r - d2) / d2)) * (large == sweep ? -1 : 1);
    double cx = (from.x + x) / 2 + k * dy, cy = (from.y + y) / 2 - k * dx;
    double a1 = atan2(from.y - cy, from.x - cx) * 180 / M_PI, a2 = atan2(y - cy, x - cx) * 180 / M_PI;
    // `sweep` turns towards increasing angles in the path's own numbers, which AppKit calls counterclockwise.
    [path appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:r startAngle:a1 endAngle:a2 clockwise:!sweep];
}

static NSBezierPath *SZFPath(NSString *data) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    NSUInteger i = 0;
    NSPoint current = NSZeroPoint, start = NSZeroPoint;
    unichar command = 'M';
    while (i < data.length) {
        unichar c = [data characterAtIndex:i];
        if (c == ' ' || c == ',') {
            i++;
            continue;
        }
        if (isalpha(c)) {
            command = c;
            i++;
        }
        BOOL relative = islower(command);
        unichar op = (unichar)toupper(command);
        if (op == 'Z') {
            [path closePath];
            current = start;
            continue;
        }
        NSArray<NSNumber *> *v = SZFPathNumbers(data, &i);
        NSUInteger arity = op == 'H' || op == 'V' ? 1 : op == 'C' ? 6 : op == 'A' ? 7 : 2;
        if (v.count == 0) break;
        for (NSUInteger j = 0; j + arity <= v.count; j += arity) {
            double ox = relative ? current.x : 0, oy = relative ? current.y : 0;
            switch (op) {
            case 'M':
                current = NSMakePoint(ox + v[j].doubleValue, oy + v[j + 1].doubleValue);
                if (j == 0) {
                    [path moveToPoint:current];
                    start = current;
                } else {
                    [path lineToPoint:current]; // more pairs after M are lines
                }
                break;
            case 'L':
                current = NSMakePoint(ox + v[j].doubleValue, oy + v[j + 1].doubleValue);
                [path lineToPoint:current];
                break;
            case 'H':
                current.x = ox + v[j].doubleValue;
                [path lineToPoint:current];
                break;
            case 'V':
                current.y = oy + v[j].doubleValue;
                [path lineToPoint:current];
                break;
            case 'C': {
                NSPoint p1 = NSMakePoint(ox + v[j].doubleValue, oy + v[j + 1].doubleValue);
                NSPoint p2 = NSMakePoint(ox + v[j + 2].doubleValue, oy + v[j + 3].doubleValue);
                current = NSMakePoint(ox + v[j + 4].doubleValue, oy + v[j + 5].doubleValue);
                [path curveToPoint:current controlPoint1:p1 controlPoint2:p2];
                break;
            }
            case 'A': {
                double x = ox + v[j + 5].doubleValue, y = oy + v[j + 6].doubleValue;
                SZFArc(path, current, v[j].doubleValue, v[j + 3].boolValue, v[j + 4].boolValue, x, y);
                current = NSMakePoint(x, y);
                break;
            }
            default: break;
            }
        }
        if (op == 'M') command = relative ? 'l' : 'L';
    }
    return path;
}

static void SZFDot(NSBezierPath *dots, CGFloat cx, CGFloat cy, CGFloat r) {
    [dots appendBezierPathWithOvalInRect:NSMakeRect(cx - r, cy - r, 2 * r, 2 * r)];
}

// The mockup's glyph for `method` in the current coordinates' 16 x 16 box (y down: the view is flipped).
static void SZFDrawRouteGlyph(NSString *method, NSColor *color) {
    NSBezierPath *stroke = [NSBezierPath bezierPath], *dots = [NSBezierPath bezierPath];
    CGFloat width = 1.5;
    BOOL round = YES;
    if ([method isEqualToString:@"lan"]) {
        width = 1.7;
        [stroke appendBezierPath:SZFPath(@"M1.8 6.2a9 9 0 0 1 12.4 0")];
        [stroke appendBezierPath:SZFPath(@"M4.1 8.7a5.7 5.7 0 0 1 7.8 0")];
        [stroke appendBezierPath:SZFPath(@"M6.4 11.1a2.4 2.4 0 0 1 3.2 0")];
        SZFDot(dots, 8, 13.2, 0.9);
    } else if ([method isEqualToString:@"p2p_wifi"]) {
        width = 1.4;
        [stroke appendBezierPath:[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.4, 8.2, 3.6, 6.2)
                                                                 xRadius:0.9
                                                                 yRadius:0.9]];
        [stroke appendBezierPath:[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(11, 8.2, 3.6, 6.2)
                                                                 xRadius:0.9
                                                                 yRadius:0.9]];
        [stroke appendBezierPath:SZFPath(@"M4.6 5.2a4.8 4.8 0 0 1 6.8 0")];
        [stroke appendBezierPath:SZFPath(@"M6.2 7a2.5 2.5 0 0 1 3.6 0")];
        SZFDot(dots, 8, 8.6, 0.75);
    } else if ([method isEqualToString:@"internet"]) {
        width = 1.2;
        round = NO;
        [stroke appendBezierPathWithOvalInRect:NSMakeRect(8 - 4.4, 5.4 - 4.4, 8.8, 8.8)];
        [stroke appendBezierPath:SZFPath(@"M3.6 5.4h8.8M8 1c1.6 1.6 1.6 7.2 0 8.8M8 1c-1.6 1.6-1.6 7.2 0 8.8")];
    } else if ([method isEqualToString:@"bluetooth"]) {
        width = 1.7;
        [stroke appendBezierPath:SZFPath(@"M4.6 5.2 11.2 10.8 8 13.6V2.4l3.2 2.8-6.6 5.6")];
    } else {
        width = 1.5;
        [stroke appendBezierPath:SZFPath(@"M4.6 12.4h7a2.8 2.8 0 0 0 .4-5.6 4 4 0 0 0-7.7.9 2.4 2.4 0 0 0 .3 4.7Z")];
    }
    stroke.lineWidth = width;
    stroke.lineCapStyle = round ? NSLineCapStyleRound : NSLineCapStyleButt;
    stroke.lineJoinStyle = round ? NSLineJoinStyleRound : NSLineJoinStyleMiter;
    [color setStroke];
    [stroke stroke];
    [color setFill];
    [dots fill];
    if ([method isEqualToString:@"internet"]) {
        // "P2P" under the globe: 5.6 units, heavy, centred on x 8 with its baseline at y 15.6.
        NSFont *font = [NSFont systemFontOfSize:5.6 weight:NSFontWeightHeavy];
        NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : color,
                                     NSKernAttributeName : @0.2};
        NSSize size = [@"P2P" sizeWithAttributes:attributes];
        [@"P2P" drawAtPoint:NSMakePoint(8 - size.width / 2, 15.6 - font.ascender) withAttributes:attributes];
    }
}

#pragma mark - Route icon

@implementation SZFriendsTransferRouteIcon
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityImageRole;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect box = NSInsetRect(self.bounds, 0.5, 0.5);
    CGFloat radius = 6 * NSWidth(self.bounds) / 24;
    NSColor *glyph;
    if (self.active) {
        [SZFriendsTransferRouteColor(self.method) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius] fill];
        glyph = NSColor.whiteColor;
    } else {
        // Used earlier, not now: an outline, the glyph in the quiet text colour.
        NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:radius - 0.5 yRadius:radius - 0.5];
        outline.lineWidth = 1;
        [SZFriendsDynamicColor(0xc4c4c4, 0x4a4a4a) setStroke];
        [outline stroke];
        glyph = SZFriendsDynamicColor(0x8a8a8a, 0x8a8a8a);
    }
    CGFloat side = NSWidth(self.bounds) * 16 / 24;
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:(NSWidth(self.bounds) - side) / 2 yBy:(NSHeight(self.bounds) - side) / 2];
    [transform scaleBy:side / 16];
    [transform concat];
    SZFDrawRouteGlyph(self.method ?: @"relay", glyph);
    [NSGraphicsContext restoreGraphicsState];
}
@end

#pragma mark - Split bar

@implementation SZFriendsSplitProgressBar {
    NSTimer *_timer;
    NSTimeInterval _start;
}
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityProgressIndicatorRole;
}
- (id)accessibilityValue {
    return self.determinate ? @(self.fraction) : nil;
}
- (void)setFinishing:(BOOL)finishing {
    _finishing = finishing;
    [self updateTimer];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateTimer];
}
- (void)updateTimer {
    BOOL moving = self.finishing && self.window != nil &&
                  !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (moving && _timer == nil) {
        _start = NSProcessInfo.processInfo.systemUptime;
        __weak SZFriendsSplitProgressBar *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
          (void)timer;
          weakSelf.needsDisplay = YES;
        }];
        [NSRunLoop.currentRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    } else if (!moving && _timer != nil) {
        [_timer invalidate];
        _timer = nil;
    }
}
- (void)dealloc {
    [_timer invalidate];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    CGFloat radius = NSHeight(bounds) / 2, width = NSWidth(bounds);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius];
    // On the card's own fill: a step darker (lighter in dark) than it, so the empty part reads as a track.
    [SZFriendsDynamicColor(0xd6d6d6, 0x4a4a4a) setFill];
    [track fill];
    [NSGraphicsContext saveGraphicsState];
    [track addClip];
    NSColor *accent = SZFriendsTransferRouteColor(@"relay"); // the mockup's accent, #3983f7
    if (self.finishing) {
        // A full bar whose lighter band slides across, once every 1.4 s (still under reduce motion).
        NSColor *light = [accent blendedColorWithFraction:0.4 ofColor:NSColor.whiteColor];
        NSGradient *gradient = [[NSGradient alloc] initWithColorsAndLocations:accent, 0.0, light, 0.5, accent, 1.0, nil];
        double phase = _timer ? fmod((NSProcessInfo.processInfo.systemUptime - _start) / 1.4, 1.0) : 0;
        CGFloat tile = 2 * width, x = -phase * tile;
        for (int i = 0; i < 2; i++)
            [gradient drawInRect:NSMakeRect(x + i * tile, 0, tile, NSHeight(bounds)) angle:0];
    } else if (!self.determinate) {
        [accent setFill];
        NSRectFill(NSMakeRect(width * 0.3, 0, width * 0.3, NSHeight(bounds)));
    } else if (self.segments.count) {
        CGFloat x = 0;
        for (NSDictionary *segment in self.segments) {
            double share = [segment[@"fraction"] isKindOfClass:NSNumber.class] ? [segment[@"fraction"] doubleValue] : 0;
            NSString *method = [segment[@"method"] isKindOfClass:NSString.class] ? segment[@"method"] : nil;
            CGFloat w = width * MAX(0, MIN(1, share));
            [SZFriendsTransferRouteColor(method) setFill];
            NSRectFill(NSMakeRect(x, 0, w, NSHeight(bounds)));
            x += w;
        }
    } else {
        [accent setFill];
        NSRectFill(NSMakeRect(0, 0, round(width * MAX(0, MIN(1, self.fraction))), NSHeight(bounds)));
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end
