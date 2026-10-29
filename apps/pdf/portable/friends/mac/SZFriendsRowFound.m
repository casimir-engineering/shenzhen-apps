// How a nearby person was found (PROTOCOL.md found, capability nearby.found): the route icon of each method that sees
// them, then the helper's label ("Local network and Bluetooth"), at the start of the row's second line. A friend's
// row in the Friends list draws the icons alone, so their latest message keeps the line.

#import "mac/SZFriendsRowView.h"

static const CGFloat SZFFoundIconSide = 11;
static const CGFloat SZFFoundIconGap = 3;

NSArray<NSString *> *SZFriendsFoundMethods(NSDictionary *found) {
    NSMutableArray *methods = [NSMutableArray array];
    if (!SZFStr(found, @"label").length) return methods; // nothing to say, so no icons either
    for (NSString *method in SZFArr(found, @"methods"))
        if ([@[ @"lan", @"p2p_wifi", @"bluetooth" ] containsObject:method] && ![methods containsObject:method])
            [methods addObject:method];
    return methods;
}

CGFloat SZFriendsDrawFound(NSArray<NSString *> *methods, NSString *label, NSRect line, SZFriendsAppearance *appearance) {
    if ((!label.length && !methods.count) || NSWidth(line) <= 0) return 0;
    CGFloat x = NSMinX(line), right = NSMaxX(line);
    NSColor *iconColor = SZFriendsRouteColor(appearance, @"local");
    for (NSString *method in methods) {
        if (x + SZFFoundIconSide > right) break;
        NSRect icon = NSMakeRect(x, floor(NSMidY(line) - SZFFoundIconSide / 2), SZFFoundIconSide, SZFFoundIconSide);
        SZFriendsDrawRouteIcon(method, icon, iconColor);
        x += SZFFoundIconSide + SZFFoundIconGap;
    }
    if (!label.length) return x - NSMinX(line);
    if (methods.count) x += 1;
    NSFont *font = appearance.secondaryFont;
    CGFloat width = MIN(SZFriendsTextWidth(label, font), MAX(0, right - x));
    if (width > 0) {
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
        [label drawWithRect:NSMakeRect(x, NSMinY(line), width, NSHeight(line))
                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                 attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : appearance.secondaryTextColor,
                              NSParagraphStyleAttributeName : paragraph}];
    }
    return x + width - NSMinX(line);
}
