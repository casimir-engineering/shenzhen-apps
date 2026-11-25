// The Annotate palette's buttons (SPDFMacAnnotatePaletteButton.h).
#import "SPDFMacAnnotatePaletteButton.h"

#import "SPDFMacChromeColors.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacIconGeometry.h"

const CGFloat SPDFPaletteButtonSize = 28;
const CGFloat SPDFPaletteChevronWidth = 14;
const CGFloat SPDFPaletteSpacing = 2;
const CGFloat SPDFPaletteSeparatorWidth = 9;

static const CGFloat kRadius = 6;
static const CGFloat kPadding = 8;     // a titled button's inset on each side
static const CGFloat kIconGap = 5;     // between an icon and the title after it
static const CGFloat kChevronGap = 4;  // between a title and the ▾ after it

static NSImage* SPDFPaletteChevron(NSColor* color) {
    return SPDFChromeSymbol(@"chevron.down", 9, NSFontWeightSemibold, color);
}

@implementation SPDFPaletteButton {
    NSTrackingArea* _tracking;
    BOOL _hovered;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)hovered { return _hovered; }
// A click never changes the state: what is chosen comes from the session (the palette sets it), so a command button
// is never left looking chosen.
- (NSInteger)nextState { return self.state; }
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                     NSTrackingInVisibleRect
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setHoveredState:(BOOL)hovered {
    _hovered = hovered;
    self.needsDisplay = YES;
    self.partner.needsDisplay = YES;  // a split button hovers as one
}
- (void)mouseEntered:(NSEvent*)event { (void)event; [self setHoveredState:YES]; }
- (void)mouseExited:(NSEvent*)event { (void)event; [self setHoveredState:NO]; }
- (void)setState:(NSControlStateValue)state {
    [super setState:state];
    self.needsDisplay = YES;
    self.partner.needsDisplay = YES;
}
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.needsDisplay = YES; }
- (void)setTrailingChevron:(BOOL)chevron { _trailingChevron = chevron; [self invalidateIntrinsicContentSize]; }
- (void)setTitle:(NSString*)title { [super setTitle:title]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setImage:(NSImage*)image { [super setImage:image]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }

- (NSFont*)titleFont { return self.font ?: [NSFont systemFontOfSize:11]; }

- (CGFloat)titleWidth {
    if (!self.title.length) return 0;
    return ceil([self.title sizeWithAttributes:@{NSFontAttributeName : self.titleFont}].width);
}

static CGFloat SPDFPaletteIconWidth(NSImage* image) {
    NSImage* icon = image ? SPDFChromeSymbolImage(image, SPDFToolbarSymbolPointSize, NSFontWeightRegular, nil) : nil;
    return icon ? ceil(icon.size.width) : 0;
}

- (CGFloat)iconWidth { return SPDFPaletteIconWidth(self.image); }

- (CGFloat)contentWidth { return [self contentWidthWithImage:self.image]; }

- (CGFloat)contentWidthWithImage:(NSImage*)image {
    if (!self.title.length) return SPDFPaletteButtonSize;
    CGFloat width = 2 * kPadding + self.titleWidth;
    if (image) width += SPDFPaletteIconWidth(image) + kIconGap;
    if (self.trailingChevron) width += kChevronGap + ceil(SPDFPaletteChevron(nil).size.width);
    return width;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(self.title.length ? self.contentWidth : NSViewNoIntrinsicMetric, SPDFPaletteButtonSize);
}

// The button's shape: a split button's halves round only their outer corners, so together they are one shape.
- (NSBezierPath*)shape {
    NSRect r = self.bounds;
    if (self.segment == SPDFPaletteSegmentAlone)
        return [NSBezierPath bezierPathWithRoundedRect:r xRadius:kRadius yRadius:kRadius];
    BOOL roundLeft = self.segment == SPDFPaletteSegmentMain;
    CGFloat minX = NSMinX(r), maxX = NSMaxX(r), minY = NSMinY(r), maxY = NSMaxY(r), k = MIN(kRadius, NSWidth(r) / 2);
    NSBezierPath* path = [NSBezierPath bezierPath];
    if (roundLeft) {
        [path moveToPoint:NSMakePoint(maxX, minY)];
        [path lineToPoint:NSMakePoint(maxX, maxY)];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(minX, maxY) toPoint:NSMakePoint(minX, minY) radius:k];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(minX, minY) toPoint:NSMakePoint(maxX, minY) radius:k];
    } else {
        [path moveToPoint:NSMakePoint(minX, minY)];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(maxX, minY) toPoint:NSMakePoint(maxX, maxY) radius:k];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(maxX, maxY) toPoint:NSMakePoint(minX, maxY) radius:k];
        [path lineToPoint:NSMakePoint(minX, maxY)];
    }
    [path closePath];
    return path;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    BOOL chosen = self.state == NSControlStateValueOn;
    BOOL tinted = self.segment == SPDFPaletteSegmentMenu && self.partner.state == NSControlStateValueOn;
    BOOL hovered = self.enabled && (_hovered || self.partner.hovered);
    NSString* fill = chosen ? @"text" : self.highlighted ? @"lineStrong" : tinted ? @"lineStrong" : hovered ? @"selected" : nil;
    if (fill) {
        [SPDFCollectionColor(fill) setFill];
        [self.shape fill];
    }
    NSColor* ink = chosen ? SPDFCollectionColor(@"window") : SPDFChromeIconColor(self.enabled);
    NSRect bounds = self.bounds;
    if (!self.title.length) {
        // One icon, centred: a symbol, or the ▾ of a split button.
        NSImage* icon = self.image ? SPDFChromeSymbolImage(self.image, SPDFToolbarSymbolPointSize, NSFontWeightRegular, ink)
                                   : SPDFPaletteChevron(ink);
        SPDFDrawVectorIcon(icon, NSInsetRect(bounds, 3, 3), YES);
        return;
    }
    // Icon, title and ▾ as one block, centred.
    CGFloat x = NSMidX(bounds) - (self.contentWidth - 2 * kPadding) / 2;
    if (self.image) {
        NSImage* icon = SPDFChromeSymbolImage(self.image, SPDFToolbarSymbolPointSize, NSFontWeightRegular, ink);
        CGFloat w = self.iconWidth;
        SPDFDrawVectorIcon(icon, NSMakeRect(x, NSMinY(bounds), w, NSHeight(bounds)), YES);
        x += w + kIconGap;
    }
    NSDictionary* attributes = @{
        NSFontAttributeName : self.titleFont,
        NSForegroundColorAttributeName : !self.enabled ? SPDFChromeIconColor(NO) : chosen ? ink : SPDFCollectionColor(@"text"),
    };
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(x, round(NSMidY(bounds) - size.height / 2)) withAttributes:attributes];
    x += self.titleWidth;
    if (self.trailingChevron) {
        NSImage* chevron = SPDFPaletteChevron(ink);
        SPDFDrawVectorIcon(chevron, NSMakeRect(x + kChevronGap, NSMinY(bounds), ceil(chevron.size.width), NSHeight(bounds)), YES);
    }
}

@end

static SPDFPaletteButton* SPDFPaletteBaseButton(NSString* label, id target, SEL action) {
    SPDFPaletteButton* button = [[SPDFPaletteButton alloc] initWithFrame:NSMakeRect(0, 0, SPDFPaletteButtonSize, SPDFPaletteButtonSize)];
    button.bordered = NO;
    button.title = @"";
    button.font = [NSFont systemFontOfSize:11];
    button.target = target;
    button.action = action;
    button.toolTip = label;
    button.accessibilityLabel = label;
    button.refusesFirstResponder = YES;  // the pages keep the keys: Command-Z, Delete, the tool letters
    button.focusRingType = NSFocusRingTypeNone;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:SPDFPaletteButtonSize].active = YES;
    return button;
}

SPDFPaletteButton* SPDFPaletteIconButton(NSString* symbol, NSString* label, id target, SEL action) {
    SPDFPaletteButton* button = SPDFPaletteBaseButton(label, target, action);
    NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    [image setTemplate:YES];
    button.image = image;
    button.imagePosition = NSImageOnly;
    if (!image) button.title = label;  // a symbol this macOS lacks
    if (image) [button.widthAnchor constraintEqualToConstant:SPDFPaletteButtonSize].active = YES;
    return button;
}

SPDFPaletteButton* SPDFPaletteMenuButton(NSString* label, id target, SEL action) {
    SPDFPaletteButton* button = SPDFPaletteBaseButton(label, target, action);
    [button.widthAnchor constraintEqualToConstant:SPDFPaletteChevronWidth].active = YES;
    return button;
}

SPDFPaletteButton* SPDFPaletteTitleButton(NSString* title, NSString* symbol, NSString* label, id target, SEL action) {
    SPDFPaletteButton* button = SPDFPaletteBaseButton(label, target, action);
    if (symbol.length) {
        NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
        [image setTemplate:YES];
        button.image = image;
    }
    button.title = title;
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

NSStackView* SPDFPaletteSplit(SPDFPaletteButton* main, SPDFPaletteButton* menu) {
    main.segment = SPDFPaletteSegmentMain;
    menu.segment = SPDFPaletteSegmentMenu;
    main.partner = menu;
    menu.partner = main;
    NSStackView* stack = [NSStackView stackViewWithViews:@[ main, menu ]];
    stack.spacing = 0;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.detachesHiddenViews = YES;
    [stack setHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return stack;
}

@interface SPDFPaletteSeparatorView : NSView
@end
@implementation SPDFPaletteSeparatorView
- (BOOL)isFlipped { return YES; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [SPDFCollectionColor(@"lineStrong") setFill];
    NSRectFill(NSMakeRect(floor(NSMidX(self.bounds) - 0.5), round(NSMidY(self.bounds) - 8), 1, 16));
}
@end

NSView* SPDFPaletteSeparator(void) {
    SPDFPaletteSeparatorView* line = [[SPDFPaletteSeparatorView alloc] initWithFrame:NSZeroRect];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [line.widthAnchor constraintEqualToConstant:SPDFPaletteSeparatorWidth].active = YES;
    [line.heightAnchor constraintEqualToConstant:SPDFPaletteButtonSize].active = YES;
    return line;
}

NSLayoutConstraint* SPDFPaletteWidthConstraint(NSView* button) {
    for (NSLayoutConstraint* c in button.constraints)
        if (c.firstItem == button && c.firstAttribute == NSLayoutAttributeWidth && !c.secondItem) return c;
    return nil;
}
