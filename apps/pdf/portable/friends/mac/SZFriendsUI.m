// Snapshot accessors, colors, labels and rich text shared by every Friends view.

#import "mac/SZFriendsUI.h"

#pragma mark - Hidden from the host's assistant

NSString *const SZFriendsHiddenIdentifierPrefix = @"szfriends.";
NSString *const SZFriendsIdentifierTitleButton = @"szfriends.title-button";
NSString *const SZFriendsIdentifierDropdown = @"szfriends.dropdown";
NSString *const SZFriendsIdentifierConfirmation = @"szfriends.confirmation";
NSString *const SZFriendsIdentifierSettings = @"szfriends.settings";
NSString *const SZFriendsIdentifierAlert = @"szfriends.alert";
NSString *const SZFriendsIdentifierOpenPanel = @"szfriends.open-panel";

void SZFriendsHideWindowFromAssistant(NSWindow *window, NSString *identifier) {
    // Both: a host may walk windows by their content view or check the window itself.
    window.identifier = identifier;
    window.contentView.identifier = identifier;
}

#pragma mark - Snapshot accessors

static id SZFValue(id object, NSString *key) {
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    id value = ((NSDictionary *)object)[key];
    return value == NSNull.null ? nil : value;
}

NSString *SZFStr(id object, NSString *key) {
    id value = SZFValue(object, key);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSDictionary *SZFDict(id object, NSString *key) {
    id value = SZFValue(object, key);
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

NSArray *SZFArr(id object, NSString *key) {
    id value = SZFValue(object, key);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

BOOL SZFBool(id object, NSString *key) {
    id value = SZFValue(object, key);
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : NO;
}

double SZFNum(id object, NSString *key) {
    id value = SZFValue(object, key);
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

#pragma mark - Colors and type

static NSColor *SZFColorFromRGB(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0 alpha:1];
}

NSColor *SZFriendsColorFromHex(NSString *hex, NSColor *fallback) {
    // Avatar colors come from another person's snapshot fields: accept exactly "#rrggbb", nothing looser.
    if (hex.length != 7 || [hex characterAtIndex:0] != '#') return fallback;
    unsigned value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return fallback;
    return SZFColorFromRGB(value);
}

NSColor *SZFriendsDynamicColor(uint32_t light, uint32_t dark) {
    NSColor *lightColor = SZFColorFromRGB(light), *darkColor = SZFColorFromRGB(dark);
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSAppearanceName match =
            [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
        return [match isEqualToString:NSAppearanceNameDarkAqua] ? darkColor : lightColor;
    }];
}

NSColor *SZFriendsRouteColor(SZFriendsAppearance *appearance, NSString *kind) {
    if ([kind isEqualToString:@"local"]) return appearance.localRouteColor;
    if ([kind isEqualToString:@"online"]) return appearance.onlineRouteColor;
    return appearance.offlineRouteColor;
}

NSFont *SZFriendsSemibold(NSFont *font) {
    return [NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold];
}

#pragma mark - Layout

@implementation SZFriendsFlippedView
- (BOOL)isFlipped {
    return YES;
}
// Frame-based layout: a new size means new frames for the children, whoever changed it.
- (void)setFrameSize:(NSSize)newSize {
    BOOL changed = !NSEqualSizes(newSize, self.frame.size);
    [super setFrameSize:newSize];
    if (changed) self.needsLayout = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self drawChrome];
    if (self.drawContents) self.drawContents(self);
}
- (void)drawChrome {
    if (!self.fillColor && !self.strokeColor) return;
    NSRect rect = self.strokeColor ? NSInsetRect(self.bounds, 0.5, 0.5) : self.bounds;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:self.cornerRadius
                                                         yRadius:self.cornerRadius];
    if (self.fillColor) {
        [self.fillColor setFill];
        [path fill];
    }
    if (self.strokeColor) {
        [self.strokeColor setStroke];
        path.lineWidth = self.dashedStroke ? 1.5 : 1;
        if (self.dashedStroke) {
            CGFloat dash[] = {4, 3};
            [path setLineDash:dash count:2 phase:0];
        }
        [path stroke];
    }
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

@implementation SZFriendsEdgeFade
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSColor *solid = self.color ?: NSColor.clearColor;
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[solid colorWithAlphaComponent:0]
                                                         endingColor:solid];
    // The gradient runs from clear to solid along the angle, so it points at the solid edge.
    CGFloat angle = self.edge == NSMaxXEdge ? 0 : self.edge == NSMinXEdge ? 180 : self.edge == NSMaxYEdge ? 90 : 270;
    [gradient drawInRect:self.bounds angle:angle];
}
@end

NSTextField *SZFriendsLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *field = [NSTextField wrappingLabelWithString:text ?: @""];
    field.font = font;
    field.textColor = color;
    field.selectable = NO;
    field.drawsBackground = NO;
    field.bordered = NO;
    field.cell.lineBreakMode = NSLineBreakByWordWrapping;
    // Labels lay out by frame; leaving autoresizing translation on keeps them out of any constraint system.
    field.translatesAutoresizingMaskIntoConstraints = YES;
    return field;
}

CGFloat SZFriendsFieldHeight(NSTextField *field, CGFloat width) {
    if (field.stringValue.length == 0 && field.attributedStringValue.length == 0) return 0;
    NSSize size = [field.cell cellSizeForBounds:NSMakeRect(0, 0, MAX(width, 1), CGFLOAT_MAX)];
    return ceil(size.height);
}

CGFloat SZFriendsTextWidth(NSString *text, NSFont *font) {
    return text.length ? ceil([text sizeWithAttributes:@{NSFontAttributeName : font}].width) : 0;
}

CGFloat SZFriendsPlace(NSTextField *field, CGFloat x, CGFloat y, CGFloat width) {
    CGFloat height = SZFriendsFieldHeight(field, width);
    field.frame = NSMakeRect(x, y, width, height);
    field.hidden = height == 0;
    return y + height;
}

NSAttributedString *SZFriendsRichText(NSArray *segments, NSFont *font, NSColor *color,
                                      SZFriendsAppearance *appearance) {
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    for (id segment in segments) {
        NSString *string = SZFStr(segment, @"text");
        if (!string.length) continue;
        NSMutableDictionary *attributes =
            [@{NSFontAttributeName : SZFBool(segment, @"emphasis") ? SZFriendsSemibold(font) : font,
               NSForegroundColorAttributeName : color} mutableCopy];
        NSString *url = SZFStr(segment, @"url");
        NSURL *link = url ? [NSURL URLWithString:url] : nil;
        // Only web and mail links become clickable: a friend's message must not open file: or app-scheme URLs.
        NSString *scheme = link.scheme.lowercaseString;
        if (link && ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"] ||
                     [scheme isEqualToString:@"mailto"])) {
            attributes[NSLinkAttributeName] = link;
            attributes[NSForegroundColorAttributeName] = appearance.accentColor;
        }
        if (SZFBool(segment, @"match")) {
            attributes[NSBackgroundColorAttributeName] = [appearance.warningColor colorWithAlphaComponent:0.35];
            attributes[NSFontAttributeName] = SZFriendsSemibold(font);
        }
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:string attributes:attributes]];
    }
    return text;
}
