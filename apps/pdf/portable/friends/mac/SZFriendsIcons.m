// Vector icons for the Friends views, drawn from the mockups' 16-unit paths so they stay sharp at 1x and 2x.
//
// WHY paths, not SF Symbols: the Friends button must be two people and never a speech bubble (brief § Product
// contract), the route icons have no symbol equivalents on the macOS 12 floor, and a GTK port draws the same paths.

#import "mac/SZFriendsUI.h"

// Runs `body` with the current coordinates mapped so a 16 x 16 box (y down, as in the SVG mockups) fills `rect`.
static void SZFIconBox(NSRect rect, CGFloat units, void (^body)(void)) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    CGFloat scale = MIN(NSWidth(rect), NSHeight(rect)) / units;
    BOOL flipped = NSGraphicsContext.currentContext.isFlipped;
    [transform translateXBy:NSMidX(rect) yBy:NSMidY(rect)];
    [transform scaleXBy:scale yBy:flipped ? scale : -scale];
    [transform translateXBy:-units / 2 yBy:-units / 2];
    [transform concat];
    body();
    [NSGraphicsContext restoreGraphicsState];
}

static NSBezierPath *SZFStrokePath(CGFloat width) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = width;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

static void SZFCircle(NSBezierPath *path, CGFloat cx, CGFloat cy, CGFloat r) {
    [path appendBezierPathWithOvalInRect:NSMakeRect(cx - r, cy - r, 2 * r, 2 * r)];
}

static void SZFLine(NSBezierPath *path, CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    [path moveToPoint:NSMakePoint(x1, y1)];
    [path lineToPoint:NSMakePoint(x2, y2)];
}

// The second figure's head in the 16-unit box, shared by the drawing and SZFriendsPeopleIconSecondHeadRect.
static const CGFloat SZFSecondHeadX = 11.2, SZFSecondHeadY = 5, SZFSecondHeadR = 2, SZFPeopleStroke = 1.3;

void SZFriendsDrawPeopleIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(SZFPeopleStroke);
        SZFCircle(path, 6, 5.5, 2.5);
        [path moveToPoint:NSMakePoint(1.5, 13.5)];
        [path curveToPoint:NSMakePoint(6, 9.5) controlPoint1:NSMakePoint(1.5, 11) controlPoint2:NSMakePoint(3.5, 9.5)];
        [path curveToPoint:NSMakePoint(10.5, 13.5) controlPoint1:NSMakePoint(8.5, 9.5)
             controlPoint2:NSMakePoint(10.5, 11)];
        SZFCircle(path, SZFSecondHeadX, SZFSecondHeadY, SZFSecondHeadR);
        [path moveToPoint:NSMakePoint(11.2, 9.4)];
        [path curveToPoint:NSMakePoint(14.6, 13) controlPoint1:NSMakePoint(13.2, 9.5)
             controlPoint2:NSMakePoint(14.6, 10.9)];
        [color setStroke];
        [path stroke];
    });
}

NSRect SZFriendsPeopleIconSecondHeadRect(NSRect iconRect) {
    // SZFIconBox's mapping in a flipped view: the 16-unit box is centred in `iconRect` at the shorter side's scale.
    CGFloat scale = MIN(NSWidth(iconRect), NSHeight(iconRect)) / 16;
    CGFloat radius = (SZFSecondHeadR + SZFPeopleStroke / 2) * scale;
    CGFloat x = NSMidX(iconRect) + (SZFSecondHeadX - 8) * scale, y = NSMidY(iconRect) + (SZFSecondHeadY - 8) * scale;
    return NSMakeRect(x - radius, y - radius, 2 * radius, 2 * radius);
}

void SZFriendsDrawBackArrow(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.6);
        SZFLine(path, 13, 8, 3, 8);
        [path moveToPoint:NSMakePoint(7, 4)];
        [path lineToPoint:NSMakePoint(3, 8)];
        [path lineToPoint:NSMakePoint(7, 12)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawCopyIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.4);
        [path appendBezierPathWithRoundedRect:NSMakeRect(5, 5, 8.5, 8.5) xRadius:1.5 yRadius:1.5];
        [path moveToPoint:NSMakePoint(3, 10.5)];
        [path lineToPoint:NSMakePoint(3, 3.5)];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(3, 2.5) toPoint:NSMakePoint(4, 2.5) radius:1];
        [path lineToPoint:NSMakePoint(10.5, 2.5)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawPencilIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.4);
        [path moveToPoint:NSMakePoint(3, 13)];
        [path lineToPoint:NSMakePoint(4, 9.5)];
        [path lineToPoint:NSMakePoint(11, 2.5)];
        [path lineToPoint:NSMakePoint(13.5, 5)];
        [path lineToPoint:NSMakePoint(6.5, 12)];
        [path closePath];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawSearchIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.4);
        SZFCircle(path, 7, 7, 4.5);
        SZFLine(path, 10.4, 10.4, 14, 14);
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawCheckIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.8);
        [path moveToPoint:NSMakePoint(3, 8.5)];
        [path lineToPoint:NSMakePoint(6.5, 12)];
        [path lineToPoint:NSMakePoint(13, 4.5)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawCheckCircleIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.6);
        SZFCircle(path, 8, 8, 6.5);
        [path moveToPoint:NSMakePoint(5, 8.3)];
        [path lineToPoint:NSMakePoint(7.2, 10.5)];
        [path lineToPoint:NSMakePoint(11, 6)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawChevronDown(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.8);
        [path moveToPoint:NSMakePoint(4, 6)];
        [path lineToPoint:NSMakePoint(8, 10)];
        [path lineToPoint:NSMakePoint(12, 6)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawChevronRight(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.8);
        [path moveToPoint:NSMakePoint(6, 4)];
        [path lineToPoint:NSMakePoint(10, 8)];
        [path lineToPoint:NSMakePoint(6, 12)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawArcIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.8);
        [path appendBezierPathWithArcWithCenter:NSMakePoint(8, 8) radius:6 startAngle:-90 endAngle:180 clockwise:NO];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawBluetoothIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.3);
        [path moveToPoint:NSMakePoint(4.5, 5)];
        [path lineToPoint:NSMakePoint(11, 11)];
        [path lineToPoint:NSMakePoint(8, 14)];
        [path lineToPoint:NSMakePoint(8, 2)];
        [path lineToPoint:NSMakePoint(11, 5)];
        [path lineToPoint:NSMakePoint(4.5, 11)];
        [color setStroke];
        [path stroke];
    });
}

void SZFriendsDrawInfoIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.4);
        SZFCircle(path, 8, 8, 6.5);
        SZFLine(path, 8, 7.5, 8, 11.5);
        [color setStroke];
        [path stroke];
        NSBezierPath *dot = [NSBezierPath bezierPath];
        SZFCircle(dot, 8, 5, 0.9);
        [color setFill];
        [dot fill];
    });
}

void SZFriendsDrawCloseIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.5);
        SZFLine(path, 4.5, 4.5, 11.5, 11.5);
        SZFLine(path, 11.5, 4.5, 4.5, 11.5);
        [color setStroke];
        [path stroke];
    });
}

// Block: a circle with a slash (the mockup's path), never a stop sign or a hand, so it reads as "no entry".
void SZFriendsDrawBlockIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.6);
        SZFCircle(path, 8, 8, 6);
        SZFLine(path, 3.8, 12.2, 12.2, 3.8);
        [color setStroke];
        [path stroke];
    });
}

// The assistant's spark: a large four-pointed star and a small one, filled, as AI chat marks the assistant.
void SZFriendsDrawAssistantIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = [NSBezierPath bezierPath];
        CGFloat stars[2][3] = {{6.5, 9, 5.5}, {12.5, 3.5, 2.6}}; // centre x, centre y, radius
        for (int i = 0; i < 2; i++) {
            CGFloat x = stars[i][0], y = stars[i][1], r = stars[i][2], w = r * 0.28;
            [path moveToPoint:NSMakePoint(x, y - r)];
            [path curveToPoint:NSMakePoint(x + r, y) controlPoint1:NSMakePoint(x + w, y - w)
                 controlPoint2:NSMakePoint(x + w, y - w)];
            [path curveToPoint:NSMakePoint(x, y + r) controlPoint1:NSMakePoint(x + w, y + w)
                 controlPoint2:NSMakePoint(x + w, y + w)];
            [path curveToPoint:NSMakePoint(x - r, y) controlPoint1:NSMakePoint(x - w, y + w)
                 controlPoint2:NSMakePoint(x - w, y + w)];
            [path curveToPoint:NSMakePoint(x, y - r) controlPoint1:NSMakePoint(x - w, y - w)
                 controlPoint2:NSMakePoint(x - w, y - w)];
            [path closePath];
        }
        [color setFill];
        [path fill];
    });
}

// An arrow pointing up: "go" for the `/` command field, where Send would wrongly promise a message to the friend.
void SZFriendsDrawArrowUpIcon(NSRect rect, NSColor *color) {
    SZFIconBox(rect, 16, ^{
        NSBezierPath *path = SZFStrokePath(1.8);
        SZFLine(path, 8, 13, 8, 3.5);
        [path moveToPoint:NSMakePoint(3.8, 7.5)];
        [path lineToPoint:NSMakePoint(8, 3.3)];
        [path lineToPoint:NSMakePoint(12.2, 7.5)];
        [color setStroke];
        [path stroke];
    });
}

NSString *SZFriendsRouteGlyph(NSDictionary *route) {
    NSString *kind = SZFStr(route, @"kind"), *method = SZFStr(route, @"method");
    if ([kind isEqualToString:@"offline"]) return @"offline";
    // Trying to reach the friend online: the globe, in the colour of a route that is not up (SZFriendsRouteColor).
    if ([kind isEqualToString:@"connecting"]) return @"internet";
    if (![kind isEqualToString:@"local"] && ![kind isEqualToString:@"online"]) return nil; // none, or unknown
    if ([@[ @"lan", @"p2p_wifi", @"bluetooth", @"internet", @"relay" ] containsObject:method]) return method;
    return [kind isEqualToString:@"local"] ? @"lan" : @"internet";
}

// Each arc in its own subpath: appended to a path that has a current point, an arc first draws a line from it, and
// those lines crossed the dot ((⋈) instead of ((•)), unlike GTK's same mark).
static void SZFRouteArc(NSBezierPath *path, CGFloat cx, CGFloat cy, CGFloat r, CGFloat from, CGFloat to) {
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:r startAngle:from endAngle:to clockwise:NO];
    [path appendBezierPath:arc];
}

// The 12-unit paths, y down, as gtk/szfriends_gtk_glyphs.c builds them; `dots` gets the filled circles.
static CGFloat SZFRoutePaths(NSString *glyph, NSBezierPath *path, NSBezierPath *dots) {
    if ([glyph isEqualToString:@"lan"] || [glyph isEqualToString:@"local"]) {
        // Waves either side of a dot: "nearby, on your network".
        for (NSNumber *radius in @[ @3.4, @5.8 ]) {
            SZFRouteArc(path, 6, 6, radius.doubleValue, 135, 225);
            SZFRouteArc(path, 6, 6, radius.doubleValue, -45, 45);
        }
        SZFCircle(dots, 6, 6, 1.4);
        return 1.2;
    }
    if ([glyph isEqualToString:@"p2p_wifi"]) {
        // Two laptops, a screen over its base each, joined by a wave arching over them: Wi-Fi straight between the
        // two Macs, no network in between. Upright bars and a wave read as the text "0~0" (verify, wave 6e). The
        // bases sit on a pixel row at 11 pt, 1x and 2x, and keep a gap between them so the two stay two.
        [path appendBezierPathWithRoundedRect:NSMakeRect(1.3, 4.4, 3.2, 2.6) xRadius:0.5 yRadius:0.5];
        [path appendBezierPathWithRoundedRect:NSMakeRect(7.5, 4.4, 3.2, 2.6) xRadius:0.5 yRadius:0.5];
        SZFLine(path, 0.8, 9.27, 5, 9.27);
        SZFLine(path, 7, 9.27, 11.2, 9.27);
        [path moveToPoint:NSMakePoint(3.4, 2.4)];
        [path curveToPoint:NSMakePoint(8.6, 2.4) controlPoint1:NSMakePoint(4.8, 0.5)
             controlPoint2:NSMakePoint(7.2, 0.5)];
        return 1.1;
    }
    if ([glyph isEqualToString:@"bluetooth"]) {
        // The Bluetooth rune, SZFriendsDrawBluetoothIcon's path at 12 units.
        [path moveToPoint:NSMakePoint(3.5, 3.75)];
        [path lineToPoint:NSMakePoint(8.4, 8.25)];
        [path lineToPoint:NSMakePoint(6.1, 10.5)];
        [path lineToPoint:NSMakePoint(6.1, 1.5)];
        [path lineToPoint:NSMakePoint(8.4, 3.75)];
        [path lineToPoint:NSMakePoint(3.5, 8.25)];
        return 1.1;
    }
    if ([glyph isEqualToString:@"internet"] || [glyph isEqualToString:@"online"]) {
        // A globe: straight to the friend's Mac over the internet.
        SZFCircle(path, 6, 6, 4.6);
        SZFLine(path, 1.4, 6, 10.6, 6);
        [path appendBezierPathWithOvalInRect:NSMakeRect(4, 1.4, 4, 9.2)];
        return 1.1;
    }
    if ([glyph isEqualToString:@"relay"]) {
        // A server, two units with a light each: through the Friends relay. Unlike the globe it holds no curve.
        [path appendBezierPathWithRoundedRect:NSMakeRect(1.5, 1.5, 9, 4) xRadius:1 yRadius:1];
        [path appendBezierPathWithRoundedRect:NSMakeRect(1.5, 6.5, 9, 4) xRadius:1 yRadius:1];
        SZFCircle(dots, 3.6, 3.5, 0.75);
        SZFCircle(dots, 3.6, 8.5, 0.75);
        return 1.1;
    }
    if ([glyph isEqualToString:@"offline"]) {
        // A hollow dot crossed out: "not reachable now". A dashed ring read as a loading spinner.
        SZFCircle(path, 6, 6, 3.6);
        SZFLine(path, 1.6, 10.4, 10.4, 1.6);
        return 1.2;
    }
    return 0;
}

void SZFriendsDrawRouteIcon(NSString *glyph, NSRect rect, NSColor *color) {
    NSBezierPath *path = SZFStrokePath(1), *dots = [NSBezierPath bezierPath];
    CGFloat width = SZFRoutePaths(glyph, path, dots);
    if (width <= 0) return;
    path.lineWidth = width;
    SZFIconBox(rect, 12, ^{
        [color setStroke];
        [path stroke];
        [color setFill];
        [dots fill];
    });
}

void SZFriendsDrawDocumentGlyph(NSRect rect, NSString *kindLabel, NSColor *labelColor) {
    NSBezierPath *page = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:3 yRadius:3];
    [SZFriendsDynamicColor(0xe4e4ea, 0xe9e9ee) setFill];
    [page fill];
    if (!kindLabel.length) return;
    CGFloat size = MAX(6, floor(NSWidth(rect) * 0.32));
    NSDictionary *attributes = @{NSFontAttributeName : [NSFont systemFontOfSize:size weight:NSFontWeightBold],
                                 NSForegroundColorAttributeName : labelColor};
    NSSize textSize = [kindLabel sizeWithAttributes:attributes];
    BOOL flipped = NSGraphicsContext.currentContext.isFlipped;
    CGFloat inset = MAX(2, NSHeight(rect) * 0.1);
    CGFloat y = flipped ? NSMaxY(rect) - inset - textSize.height : NSMinY(rect) + inset;
    NSRect textRect = NSMakeRect(NSMinX(rect) + 1, y, NSWidth(rect) - 2, textSize.height);
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByClipping;
    NSMutableDictionary *drawn = [attributes mutableCopy];
    drawn[NSParagraphStyleAttributeName] = paragraph;
    [kindLabel drawInRect:textRect withAttributes:drawn];
}

NSRect SZFriendsBadgeRect(NSString *label, NSPoint topRight, NSFont *font) {
    CGFloat width = ceil([label sizeWithAttributes:@{NSFontAttributeName : font}].width) + 8;
    CGFloat height = 15;
    width = MAX(width, height);
    BOOL flipped = NSGraphicsContext.currentContext ? NSGraphicsContext.currentContext.isFlipped : YES;
    CGFloat y = flipped ? topRight.y : topRight.y - height;
    return NSMakeRect(topRight.x - width, y, width, height);
}

void SZFriendsDrawBadge(NSString *label, NSRect rect, NSFont *font, SZFriendsAppearance *appearance) {
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:NSHeight(rect) / 2
                                                         yRadius:NSHeight(rect) / 2];
    [appearance.badgeColor setFill];
    [pill fill];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : appearance.badgeTextColor,
                                 NSParagraphStyleAttributeName : paragraph};
    NSSize size = [label sizeWithAttributes:attributes];
    NSRect textRect = NSMakeRect(NSMinX(rect), NSMidY(rect) - size.height / 2, NSWidth(rect), size.height);
    [label drawInRect:textRect withAttributes:attributes];
}
