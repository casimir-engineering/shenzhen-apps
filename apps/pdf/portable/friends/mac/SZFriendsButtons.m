// SZFriendsButton: one button class for every Friends action, drawn by style so the whole frame is the hit area.

#import "mac/SZFriendsUI.h"

SZFriendsButtonStyle SZFriendsButtonStyleNamed(NSString *style) {
    if ([style isEqualToString:@"primary"]) return SZFriendsButtonStylePrimary;
    if ([style isEqualToString:@"link"]) return SZFriendsButtonStyleLink;
    if ([style isEqualToString:@"destructive"]) return SZFriendsButtonStyleDestructive;
    return SZFriendsButtonStyleSecondary;
}

@implementation SZFriendsButton {
    NSTrackingArea *_hoverArea;
    id _pressedSubject; // pressSubject when the mouse went down, NSNull for nil; nil outside a mouse press
}

+ (instancetype)buttonWithTitle:(NSString *)title style:(SZFriendsButtonStyle)style
                     appearance:(SZFriendsAppearance *)appearance {
    SZFriendsButton *button = [[self alloc] initWithFrame:NSMakeRect(0, 0, 80, 28)];
    button.theme = appearance;
    button.style = style;
    button.title = title ?: @"";
    return button;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.bordered = NO;
    self.buttonType = NSButtonTypeMomentaryChange;
    self.target = self;
    self.action = @selector(pressed:);
    self.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.alignment = NSTextAlignmentCenter;
    self.focusRingType = NSFocusRingTypeDefault;
    _iconSize = NSMakeSize(15, 15);
    _theme = [SZFriendsAppearance new];
    return self;
}

- (void)pressed:(id)sender {
    (void)sender;
    // A mouse press counts only for whom it began on (pressSubject).
    id subject = self.pressSubject ? self.pressSubject() : nil;
    if (_pressedSubject && ![_pressedSubject isEqual:subject ?: NSNull.null]) return;
    if (self.onPress) self.onPress(self);
}

// NSButton tracks the press inside -mouseDown: and sends the action at release, before it returns; snapshots keep
// arriving meanwhile, since the tracking loop runs the main queue.
- (void)mouseDown:(NSEvent *)event {
    _pressedSubject = self.pressSubject ? self.pressSubject() ?: NSNull.null : nil;
    [super mouseDown:event];
    _pressedSubject = nil;
}

- (BOOL)isFlipped {
    return YES;
}

// The tokens are the colours meant: inside the popover's material a borderless button is drawn with vibrancy, which
// blended the selected tab's white fill into the track behind it, so the selected tab could not be seen in light
// mode (the owner's report of 2026-10-20).
- (BOOL)allowsVibrancy {
    return NO;
}

// Popovers stay open while another app is active (semi-transient), and the person may hover from Finder mid-drag.
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    self.hovered = YES;
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    self.hovered = NO;
}

- (void)setHovered:(BOOL)hovered {
    _hovered = hovered;
    self.needsDisplay = YES;
}

- (void)setSelectedLook:(BOOL)selectedLook {
    _selectedLook = selectedLook;
    self.needsDisplay = YES;
}

- (void)setBadgeLabel:(NSString *)badgeLabel {
    _badgeLabel = [badgeLabel copy];
    self.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

// Secondary-looking buttons: a filled, outlined bezel at rest.
- (BOOL)isBordered {
    return self.style == SZFriendsButtonStyleSecondary || self.style == SZFriendsButtonStyleDestructiveBordered;
}

- (CGFloat)horizontalPadding {
    if (self.style == SZFriendsButtonStyleLink || self.style == SZFriendsButtonStyleDestructive) return 2;
    if (self.style == SZFriendsButtonStylePlain) return 8;
    return 12;
}

- (NSDictionary *)titleAttributes {
    NSColor *color = self.theme.primaryTextColor;
    if (self.style == SZFriendsButtonStylePrimary)
        color = self.enabled ? self.theme.primaryButtonTextColor
                             : [self.theme.primaryButtonTextColor colorWithAlphaComponent:0.75];
    if (self.style == SZFriendsButtonStyleLink) color = self.theme.accentColor;
    if (self.style == SZFriendsButtonStyleDestructive || self.style == SZFriendsButtonStyleDestructiveBordered)
        color = self.theme.destructiveColor;
    if (!self.enabled && self.style != SZFriendsButtonStylePrimary) color = self.theme.secondaryTextColor;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    paragraph.alignment = self.alignment;
    return @{NSFontAttributeName : self.font, NSForegroundColorAttributeName : color,
             NSParagraphStyleAttributeName : paragraph};
}

- (CGFloat)fittingWidth {
    CGFloat width = ceil([self.title sizeWithAttributes:[self titleAttributes]].width);
    if (self.icon) width += self.iconSize.width + (self.title.length ? 6 : 0);
    return width + 2 * [self horizontalPadding];
}

- (NSColor *)iconColor {
    if (self.style == SZFriendsButtonStylePrimary) return self.theme.primaryButtonTextColor;
    if (self.style == SZFriendsButtonStyleLink) return self.theme.accentColor;
    if (!self.enabled) return self.theme.secondaryTextColor;
    if (self.style == SZFriendsButtonStyleDestructive || self.style == SZFriendsButtonStyleDestructiveBordered)
        return self.theme.destructiveColor;
    return self.style == SZFriendsButtonStylePlain && !self.title.length ? self.theme.secondaryTextColor
                                                                         : self.theme.primaryTextColor;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    BOOL pressed = self.cell.isHighlighted;
    NSEdgeInsets insets = self.chromeInsets;
    NSRect bounds = NSMakeRect(insets.left, insets.top, NSWidth(self.bounds) - insets.left - insets.right,
                               NSHeight(self.bounds) - insets.top - insets.bottom);
    CGFloat radius = MIN(appearance.cornerRadius, NSHeight(bounds) / 2);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:radius
                                                          yRadius:radius];
    NSColor *fill = nil;
    // A disabled primary button fades as a whole; grey text on full blue read as broken, not unavailable.
    if (self.style == SZFriendsButtonStylePrimary)
        fill = self.enabled ? appearance.primaryButtonColor
                            : [appearance.primaryButtonColor colorWithAlphaComponent:0.4];
    else if ([self isBordered]) fill = appearance.controlColor;
    // Plain and icon buttons (rows, the back arrow, Copy) are flat like the host's panel icon buttons: they fill
    // only under the pointer or while pressed, with the host's hover colour, never the selection colour.
    else if (self.enabled && (self.hovered || pressed)) fill = appearance.hoverColor;
    if (self.selectedLook) fill = self.selectedFillColor ?: appearance.selectionColor;
    if (fill) {
        [(pressed ? [fill blendedColorWithFraction:0.15 ofColor:NSColor.grayColor] : fill) setFill];
        [shape fill];
    }
    if ([self isBordered] || (self.selectedLook && self.selectedStrokeColor)) {
        [(self.selectedLook && self.selectedStrokeColor ? self.selectedStrokeColor : appearance.controlBorderColor)
            setStroke];
        [shape stroke];
    }

    NSDictionary *attributes = [self titleAttributes];
    NSSize titleSize = self.title.length ? [self.title sizeWithAttributes:attributes] : NSZeroSize;
    CGFloat padding = [self horizontalPadding];
    CGFloat iconWidth = self.icon ? self.iconSize.width : 0;
    CGFloat gap = self.icon && self.title.length ? 6 : 0;
    CGFloat contentWidth = MIN(NSWidth(bounds) - 2 * padding, iconWidth + gap + ceil(titleSize.width));
    CGFloat x = NSMinX(bounds) +
                (self.alignment == NSTextAlignmentLeft ? padding : floor((NSWidth(bounds) - contentWidth) / 2));
    CGFloat titleWidth = MAX(0, contentWidth - iconWidth - gap);
    if (self.icon) {
        CGFloat iconX = self.iconTrailing ? x + titleWidth + gap : x;
        NSRect iconRect = NSMakeRect(iconX, NSMinY(bounds) + floor((NSHeight(bounds) - self.iconSize.height) / 2),
                                     self.iconSize.width, self.iconSize.height);
        self.icon(iconRect, [self iconColor]);
        if (!self.iconTrailing) x += iconWidth + gap;
    }
    if (self.title.length) {
        CGFloat underline = self.hovered && self.style == SZFriendsButtonStyleLink ? 1 : 0;
        NSMutableDictionary *drawn = [attributes mutableCopy];
        if (underline) drawn[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
        NSRect titleRect = NSMakeRect(x, NSMinY(bounds) + floor((NSHeight(bounds) - titleSize.height) / 2),
                                      titleWidth, ceil(titleSize.height));
        [self.title drawWithRect:titleRect options:NSStringDrawingUsesLineFragmentOrigin attributes:drawn];
    }
    if (self.badgeLabel.length) {
        NSFont *badgeFont = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
        NSRect badge = SZFriendsBadgeRect(self.badgeLabel, NSMakePoint(NSMaxX(self.bounds), 0), badgeFont);
        SZFriendsDrawBadge(self.badgeLabel, badge, badgeFont, appearance);
    }
    if (self.window.firstResponder == self && self.window.isKeyWindow) {
        [NSGraphicsContext saveGraphicsState];
        NSSetFocusRingStyle(NSFocusRingOnly);
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }
}

@end
