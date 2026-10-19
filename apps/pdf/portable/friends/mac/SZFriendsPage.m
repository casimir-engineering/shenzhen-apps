// The page base class, the header bar every view below the list shares, and the avatar view.

#import "mac/SZFriendsPage.h"

#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsHelperFiles.h"

#import "avatars/SZFriendsAvatars.h"

const CGFloat SZFriendsHeaderHeight = 48;

@implementation SZFriendsPage

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, context.appearance.dropdownWidth, 560)])) return nil;
    _context = context;
    self.fillColor = context.appearance.backgroundColor;
    return self;
}

- (SZFriendsDropdownView)kind {
    return SZFriendsDropdownViewList;
}

- (void)pageWillAppear {
    _onScreen = YES;
}

- (void)pageDidDisappear {
    _onScreen = NO;
}

- (void)applySnapshot:(NSDictionary *)data {
    (void)data;
}

- (BOOL)dismissInnermostPicker {
    return NO;
}

- (NSView *)preferredFirstResponder {
    return nil;
}

@end

#pragma mark - Header

// The centered title: the name in the header font, a chevron pointing right when it opens details (it navigates;
// a chevron down promises a menu, as the reader's own popups use it), and the route line under it. One button, so
// the whole title area is a single hit target.
@interface SZFriendsHeaderTitleButton : SZFriendsButton
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, strong) NSColor *subtitleColor;
@property(nonatomic) BOOL showsChevron;
@property(nonatomic, copy) NSDictionary *route;      // the route line's icon and its tooltip
@property(nonatomic, readonly) NSRect routeIconRect; // as last drawn; NSZeroRect without one
@end

// The route icon before the route line, as rows show it: 11 pt, 4 pt from the words.
static const CGFloat SZFHeaderRouteIcon = 11, SZFHeaderRouteGap = 4;

@implementation SZFriendsHeaderTitleButton

- (CGFloat)routeIconWidth {
    return self.subtitle.length && SZFriendsRouteGlyph(self.route) ? SZFHeaderRouteIcon + SZFHeaderRouteGap : 0;
}

- (CGFloat)fittingWidth {
    NSDictionary *titleAttributes = @{NSFontAttributeName : self.theme.headerFont};
    NSDictionary *subtitleAttributes = @{NSFontAttributeName : self.theme.captionFont};
    CGFloat title = [self.title sizeWithAttributes:titleAttributes].width + (self.showsChevron ? 14 : 0);
    CGFloat subtitle = self.subtitle.length ? [self.subtitle sizeWithAttributes:subtitleAttributes].width : 0;
    return ceil(MAX(title, subtitle + [self routeIconWidth])) + 16;
}

- (void)layout {
    [super layout];
    [self removeAllToolTips];
    if (SZFStr(self.route, @"label").length && [self routeIconWidth] > 0)
        [self addToolTipRect:NSMakeRect(0, NSMidY(self.bounds), NSWidth(self.bounds), NSHeight(self.bounds) / 2)
                       owner:self userData:NULL];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view, (void)tag, (void)point, (void)data;
    return SZFStr(self.route, @"label") ?: @"";
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsAppearance *appearance = self.theme;
    if (self.enabled && (self.hovered || self.cell.isHighlighted)) {
        NSColor *fill = appearance.hoverColor;
        if (self.cell.isHighlighted) fill = [fill blendedColorWithFraction:0.15 ofColor:NSColor.grayColor];
        [fill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *titleAttributes = @{NSFontAttributeName : appearance.headerFont,
                                      NSForegroundColorAttributeName : appearance.primaryTextColor,
                                      NSParagraphStyleAttributeName : paragraph};
    NSColor *subtitleColor = self.subtitleColor ?: appearance.secondaryTextColor;
    NSDictionary *subtitleAttributes = @{NSFontAttributeName : appearance.captionFont,
                                         NSForegroundColorAttributeName : subtitleColor,
                                         NSParagraphStyleAttributeName : paragraph};
    CGFloat titleHeight = ceil([@"Ag" sizeWithAttributes:titleAttributes].height);
    CGFloat subtitleHeight = self.subtitle.length ? ceil([@"Ag" sizeWithAttributes:subtitleAttributes].height) : 0;
    CGFloat y = floor((NSHeight(self.bounds) - titleHeight - subtitleHeight) / 2);
    CGFloat chevron = self.showsChevron ? 14 : 0;
    CGFloat titleWidth = MIN(ceil([self.title sizeWithAttributes:titleAttributes].width),
                             NSWidth(self.bounds) - 16 - chevron);
    CGFloat x = floor((NSWidth(self.bounds) - titleWidth - chevron) / 2);
    [self.title drawWithRect:NSMakeRect(x, y, titleWidth, titleHeight) options:NSStringDrawingUsesLineFragmentOrigin
                  attributes:titleAttributes];
    if (self.showsChevron)
        SZFriendsDrawChevronRight(NSMakeRect(x + titleWidth + 4, y + floor((titleHeight - 10) / 2), 10, 10),
                                  appearance.secondaryTextColor);
    _routeIconRect = NSZeroRect;
    if (!self.subtitle.length) return;
    // The icon and the words centred together; the words truncate first when the name leaves them little room.
    CGFloat icon = [self routeIconWidth];
    CGFloat lineWidth = MIN(ceil([self.subtitle sizeWithAttributes:subtitleAttributes].width) + icon,
                            NSWidth(self.bounds) - 16);
    CGFloat lineX = floor((NSWidth(self.bounds) - lineWidth) / 2);
    if (icon > 0) {
        _routeIconRect = NSMakeRect(lineX, y + titleHeight + floor((subtitleHeight - SZFHeaderRouteIcon) / 2),
                                    SZFHeaderRouteIcon, SZFHeaderRouteIcon);
        SZFriendsDrawRouteIcon(SZFriendsRouteGlyph(self.route), _routeIconRect, subtitleColor);
    }
    NSMutableParagraphStyle *line = [paragraph mutableCopy];
    line.alignment = icon > 0 ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    NSMutableDictionary *lineAttributes = [subtitleAttributes mutableCopy];
    lineAttributes[NSParagraphStyleAttributeName] = line;
    [self.subtitle drawWithRect:NSMakeRect(lineX + icon, y + titleHeight, lineWidth - icon, subtitleHeight)
                        options:NSStringDrawingUsesLineFragmentOrigin
                     attributes:lineAttributes];
}

@end

@implementation SZFriendsHeaderView {
    SZFriendsAppearance *_appearance;
    SZFriendsHeaderTitleButton *_title;
}

- (instancetype)initWithAppearance:(SZFriendsAppearance *)appearance {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, appearance.dropdownWidth, SZFriendsHeaderHeight)])) return nil;
    _appearance = appearance;
    _backButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleIcon appearance:appearance];
    _backButton.icon = ^(NSRect rect, NSColor *color) { SZFriendsDrawBackArrow(rect, color); };
    // The chrome is 30 x 28 like the mockups; the frame adds room above and to the right for the waiting count,
    // so the badge is part of the one hit area instead of a dead zone over the button's corner.
    _backButton.chromeInsets = NSEdgeInsetsMake(6, 0, 0, 10);
    [self addSubview:_backButton];
    _title = [SZFriendsHeaderTitleButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain appearance:appearance];
    _titleButton = _title;
    [self addSubview:_title];
    return self;
}

- (void)setTitle:(NSString *)title
              subtitle:(NSString *)subtitle
         subtitleColor:(NSColor *)subtitleColor
             clickable:(BOOL)clickable
    accessibilityLabel:(NSString *)accessibilityLabel {
    _title.title = title ?: @"";
    _title.subtitle = subtitle ?: @"";
    _title.subtitleColor = subtitleColor;
    _title.showsChevron = clickable;
    _title.enabled = clickable;
    _title.accessibilityLabel = accessibilityLabel ?: title;
    [self setNeedsLayout:YES];
    _title.needsDisplay = YES;
}

- (void)setRoute:(NSDictionary *)route {
    _title.route = route;
    [self setNeedsLayout:YES];
    _title.needsLayout = YES;
    _title.needsDisplay = YES;
}

- (NSRect)routeIconRect {
    return [self convertRect:_title.routeIconRect fromView:_title];
}

- (void)setBack:(NSDictionary *)back fallbackLabel:(NSString *)label {
    NSString *badge = SZFStr(back, @"badge_label");
    _backButton.badgeLabel = SZFNum(back, @"badge_count") > 0 ? badge : nil;
    _backButton.accessibilityLabel = SZFStr(back, @"accessibility_label") ?: label;
    _backButton.toolTip = label.length ? label : nil;
}

- (void)layout {
    [super layout];
    _backButton.frame = NSMakeRect(8, 4, 40, 34);
    // Centered on the dropdown, never on the space left of the back arrow, as the mockups draw it.
    CGFloat side = 56;
    CGFloat width = MIN(NSWidth(self.bounds) - 2 * side, [_title fittingWidth]);
    _title.frame = NSMakeRect(floor((NSWidth(self.bounds) - width) / 2), 5, width, SZFriendsHeaderHeight - 10);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [_appearance.separatorColor setFill];
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1));
}

@end

#pragma mark - Avatar

static NSString *SZFAvatarManifestPath;
static SZFriendsAnimalSet *SZFAvatarSet;
static BOOL SZFAvatarSetLoaded;

static SZFriendsAnimalSet *SZFAvatarAnimalSet(void) {
    if (!SZFAvatarSetLoaded) {
        SZFAvatarSetLoaded = YES;
        if (SZFAvatarManifestPath)
            SZFAvatarSet = [SZFriendsAnimalSet setWithManifestAtPath:SZFAvatarManifestPath error:nil];
        else
            SZFAvatarSet = [SZFriendsAnimalSet bundledSet];
    }
    return SZFAvatarSet;
}

SZFriendsAnimalSet *SZFriendsCurrentAnimalSet(void) {
    return SZFAvatarAnimalSet();
}

static NSCache<NSString *, NSImage *> *SZFAvatarImages(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    return cache;
}

static NSImage *SZFAvatarCachedImage(NSString *path) {
    NSImage *image = [SZFAvatarImages() objectForKey:path];
    if (image) return image;
    image = [[NSImage alloc] initWithContentsOfFile:path];
    if (image) [SZFAvatarImages() setObject:image forKey:path];
    return image;
}

// The animal from this app's own copy of the set, or the helper's re-encoded photo; nil means "draw initials":
// an index newer than this set, a missing file, a photo still loading, or a placeholder avatar. A photo is read only
// from the helper's pictures/ and decoded off the main thread (SZFriendsHelperFiles.h); `view` redraws once it is.
static NSImage *SZFAvatarImage(NSDictionary *avatar, NSView *view) {
    NSString *kind = SZFStr(avatar, @"kind");
    if ([kind isEqualToString:@"animal"]) {
        SZFriendsAnimalSet *set = SZFAvatarAnimalSet();
        NSInteger index = (NSInteger)SZFNum(avatar, @"index");
        NSString *path = set && [set containsIndex:index] ? [set pdfPathAtIndex:index] : nil;
        return path ? SZFAvatarCachedImage(path) : nil;
    }
    if ([kind isEqualToString:@"image"]) {
        NSString *path = SZFStr(avatar, @"path");
        return path.length ? SZFriendsAvatarPhoto(path, view) : nil;
    }
    return nil;
}

void SZFriendsDrawAvatar(NSDictionary *avatar, NSRect rect) {
    SZFriendsDrawAvatarInView(avatar, rect, nil);
}

void SZFriendsDrawAvatarInView(NSDictionary *avatar, NSRect rect, NSView *view) {
    if (!avatar) return;
    CGFloat side = MIN(NSWidth(rect), NSHeight(rect));
    NSRect circle = NSMakeRect(NSMinX(rect) + floor((NSWidth(rect) - side) / 2),
                               NSMinY(rect) + floor((NSHeight(rect) - side) / 2), side, side);
    NSColor *color = SZFriendsColorFromHex(SZFStr(avatar, @"color"), [NSColor colorWithWhite:0.45 alpha:1]);
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithOvalInRect:circle] addClip];
    [color setFill];
    NSRectFill(circle);
    NSImage *image = SZFAvatarImage(avatar, view);
    if (image) {
        // Aspect fill: an animal PDF is square already; a photo is re-encoded square by the helper.
        NSSize size = image.size;
        CGFloat scale = size.width > 0 && size.height > 0 ? MAX(side / size.width, side / size.height) : 1;
        NSRect target = NSMakeRect(NSMidX(circle) - size.width * scale / 2, NSMidY(circle) - size.height * scale / 2,
                                   size.width * scale, size.height * scale);
        [image drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
           respectFlipped:YES hints:nil];
    } else {
        NSString *initials = SZFStr(avatar, @"initials") ?: @"";
        NSDictionary *attributes = @{NSFontAttributeName : [NSFont systemFontOfSize:floor(side * 0.38)
                                                                             weight:NSFontWeightSemibold],
                                     NSForegroundColorAttributeName : NSColor.whiteColor};
        NSSize textSize = [initials sizeWithAttributes:attributes];
        [initials drawAtPoint:NSMakePoint(NSMidX(circle) - textSize.width / 2, NSMidY(circle) - textSize.height / 2)
               withAttributes:attributes];
    }
    [NSGraphicsContext restoreGraphicsState];
}

void SZFriendsForwardEscape(NSView *from) {
    for (NSView *view = from; view; view = view.superview) {
        if ([view conformsToProtocol:@protocol(SZFriendsEscapeHandling)]) {
            [(id<SZFriendsEscapeHandling>)view friendsHandleEscape];
            return;
        }
    }
}

@implementation SZFriendsAvatarView

+ (void)setAnimalManifestPath:(NSString *)path {
    SZFAvatarManifestPath = [path copy];
    SZFAvatarSetLoaded = NO;
    SZFAvatarSet = nil;
    [SZFAvatarImages() removeAllObjects];
    SZFriendsForgetAvatarPhotos();
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setAvatar:(NSDictionary *)avatar {
    _avatar = [avatar copy];
    self.needsDisplay = YES;
}

// A view of the picture only; the row or header beside it carries the accessible name.
- (BOOL)isAccessibilityElement {
    return NO;
}

- (NSString *)drawnKind {
    return SZFAvatarImage(self.avatar, self) ? SZFStr(self.avatar, @"kind") : @"placeholder";
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SZFriendsDrawAvatarInView(self.avatar, self.bounds, self);
}

@end
