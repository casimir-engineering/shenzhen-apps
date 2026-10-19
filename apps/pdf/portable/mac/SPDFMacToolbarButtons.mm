#import "SPDFMacIconGeometry.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacUIHelpers.h"

// The two custom-drawn buttons of the document toolbar: a labelled switch and a
// three-dot overflow button. Both own their whole appearance, hold no
// application state, and depend on nothing but AppKit -- lifted out of
// SPDFMacUIHelpers.mm, whose size cap asks that further additions go to a
// focused file rather than back onto that mixed pile.

@implementation SPDFToolbarToggleButton

- (instancetype)initWithTitle:(NSString*)title target:(id)target action:(SEL)action {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.title = title;
        self.ignoresMultiClick = NO;
        self.target = target;
        self.action = action;
        self.bordered = NO;
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.focusRingType = NSFocusRingTypeNone;
        [self setButtonType:NSButtonTypeMomentaryChange];
        SPDFConfigureIconButtonRendering(self);
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}

// These actions can hide this button and reveal its counterpart under the
// pointer. Do not enter NSButton's tracking loop across that layout change.
- (void)mouseDown:(NSEvent*)event {
    (void)event;
    [self highlight:NO];
    if (self.enabled) [self sendAction:self.action to:self.target];
    [self highlight:NO];
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}

- (NSSize)intrinsicContentSize { return NSMakeSize(28,28); }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsDisplay=YES; }

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    self.accessibilityValue = active ? @"On" : @"Off";
    [self setNeedsDisplay:YES];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self setNeedsDisplay:YES];
}

- (void)setTitle:(NSString*)title {
    [super setTitle:title];
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSImage* image = [NSImage imageWithSystemSymbolName:[self.title isEqualToString:@"Map"] ? @"sidebar.right" : @"sidebar.left"
                              accessibilityDescription:nil];
    image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
    image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[SPDFChromeIconColor(self.enabled)]]];
    SPDFDrawVectorIcon(image,NSMakeRect(floor((NSWidth(self.bounds)-16)/2),floor((NSHeight(self.bounds)-16)/2),16,16),NO);
}

@end

@implementation SPDFToolbarMenuButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered = NO;
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.focusRingType = NSFocusRingTypeNone;
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    (void)event;
    return YES;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(30.0, 28.0);
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = NSInsetRect(self.bounds, 1.0, 2.0);
    CGFloat alpha = self.enabled ? 1.0 : 0.42;
    NSColor* fill = self.highlighted ? [NSColor.labelColor colorWithAlphaComponent:0.13 * alpha]
                                     : [NSColor.labelColor colorWithAlphaComponent:0.06 * alpha];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:8.0 yRadius:8.0] fill];

    [[NSColor.separatorColor colorWithAlphaComponent:0.30 * alpha] setStroke];
    NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:8.0 yRadius:8.0];
    outline.lineWidth = 1.0;
    [outline stroke];

    [SPDFChromeIconColor(self.enabled) setFill];
    CGFloat dotSize = 3.0;
    CGFloat gap = 3.0;
    CGFloat x = floor(NSMidX(bounds) - dotSize / 2.0);
    CGFloat startY = floor(NSMidY(bounds) - dotSize * 1.5 - gap);
    for (NSInteger i = 0; i < 3; ++i) {
        NSRect dot = NSMakeRect(x, startY + (dotSize + gap) * i, dotSize, dotSize);
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
}

@end

@interface SPDFCenteredZoomCell : NSPopUpButtonCell
@end
@implementation SPDFCenteredZoomCell
- (NSRect)drawTitle:(NSAttributedString*)title withFrame:(NSRect)frame inView:(NSView*)view {
    NSMutableAttributedString* centered=[title mutableCopy];
    NSMutableParagraphStyle* paragraph=[NSMutableParagraphStyle new]; paragraph.alignment=NSTextAlignmentCenter;
    [centered addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0,centered.length)];
    return [super drawTitle:centered withFrame:frame inView:view];
}
@end

void spdf_fit_popup_select_and_size(NSPopUpButton* popup, NSMenuItem* itemToSelect) {
    if (!popup) return;
    if (![popup.cell isKindOfClass:SPDFCenteredZoomCell.class]) {
        NSPopUpButtonCell* old=(NSPopUpButtonCell*)popup.cell;
        SPDFCenteredZoomCell* cell=[[SPDFCenteredZoomCell alloc] initTextCell:@"" pullsDown:NO];
        NSMenuItem* selected=popup.selectedItem;
        cell.menu=old.menu; cell.font=old.font; cell.bordered=old.bordered;
        cell.enabled=old.enabled; cell.target=old.target; cell.action=old.action;
        popup.cell=cell; if(selected) [popup selectItem:selected];
    }
    if (itemToSelect) [popup selectItem:itemToSelect];
    NSFont* font = popup.font ?: [NSFont systemFontOfSize:12];
    popup.alignment = NSTextAlignmentCenter;
    CGFloat longest = 0;
    for (NSMenuItem* item in popup.itemArray)
        longest = MAX(longest, [item.title sizeWithAttributes:@{NSFontAttributeName:font}].width);
    // Equal breathing room around the longest label, plus the native chevrons.
    CGFloat width = ceil(longest) + 24;
    for (NSLayoutConstraint* constraint in popup.constraints)
        if (constraint.firstAttribute == NSLayoutAttributeWidth && constraint.secondItem == nil) {
            constraint.constant = width;
            return;
        }
    [popup.widthAnchor constraintEqualToConstant:width].active = YES;
}
