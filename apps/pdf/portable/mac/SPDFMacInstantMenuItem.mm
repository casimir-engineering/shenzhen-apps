#import "SPDFMacInstantMenuItem.h"

#import <CoreText/CoreText.h>

// Context-menu metrics on macOS 26, as AppKit lays out its own item views (NSContextMenuItemView): a 24-point row; images
// drawn as 13-point small symbols in a column 16 points in, as wide as the menu's widest image; the title 4 points
// after that column; the key in an 8-point column ending 8 points before the row's end, its modifiers as 12-point small
// symbols just before it; the highlight a capsule inset 5 points on each side.
static const CGFloat kRowHeight = 24, kImageX = 16, kTitleGap = 4, kTrailing = 8, kKeyColumn = 8, kModifierGap = 2,
                     kModifierSpacing = 1, kModifierPointSize = 12, kHighlightInset = 5, kHighlightRadius = 12, kTextHeight = 16;

NSRect SPDFMacInstantMenuItemHighlightRect(NSRect bounds) {
    return NSMakeRect(NSMinX(bounds) + kHighlightInset, NSMinY(bounds), MAX(0, NSWidth(bounds) - 2 * kHighlightInset),
                      NSHeight(bounds));
}

// An item's image as the menu shows it.
static NSImage* MenuImage(NSImage* image) {
    if (!image) return nil;
    NSImageSymbolConfiguration* small = [NSImageSymbolConfiguration configurationWithPointSize:13
                                                                                         weight:NSFontWeightRegular
                                                                                          scale:NSImageSymbolScaleSmall];
    return [image imageWithSymbolConfiguration:small] ?: image;
}

// Draws `image` in `rect`, a template one in `color` as an image view tints it (the colour's alpha applied once).
static void DrawImage(NSImage* image, NSRect rect, NSColor* color) {
    CGFloat alpha = 1;
    if (image.isTemplate) {
        NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: color;
        alpha = rgb.alphaComponent;
        NSColor* opaque = [rgb colorWithAlphaComponent:1];
        NSImage* source = image;
        image = [NSImage imageWithSize:source.size
                               flipped:NO
                        drawingHandler:^BOOL(NSRect bounds) {
                          [source drawInRect:bounds];
                          [opaque set];
                          NSRectFillUsingOperation(bounds, NSCompositingOperationSourceAtop);
                          return YES;
                        }];
    }
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha respectFlipped:YES
                hints:nil];
}

static NSArray<NSString*>* ModifierSymbols(NSEventModifierFlags mask) {
    NSMutableArray* symbols = [NSMutableArray array];
    if (mask & NSEventModifierFlagControl) [symbols addObject:@"control"];
    if (mask & NSEventModifierFlagOption) [symbols addObject:@"option"];
    if (mask & NSEventModifierFlagShift) [symbols addObject:@"shift"];
    if (mask & NSEventModifierFlagCommand) [symbols addObject:@"command"];
    return symbols;
}

@interface SPDFMacInstantMenuItemView : NSView
@end

@implementation SPDFMacInstantMenuItemView {
    NSTrackingArea* _hover;
@public
    __weak NSMenuItem* _item;
}

- (BOOL)isFlipped {
    return YES;
}

- (NSMenuItem*)item {
    return self.enclosingMenuItem ?: _item;
}

- (BOOL)isHighlighted {
    NSMenuItem* item = self.item;
    return item.isHighlighted && item.isEnabled;
}

- (CGFloat)imageColumnWidth {
    CGFloat width = 0;
    for (NSMenuItem* other in self.item.menu.itemArray)
        if (!other.hidden && other.image) width = MAX(width, ceil(MenuImage(other.image).size.width));
    return width;
}

- (BOOL)allowsVibrancy {
    return YES;
}

- (NSTextFieldCell*)cellWithText:(NSString*)text color:(NSColor*)color alignment:(NSTextAlignment)alignment {
    NSTextFieldCell* cell = [[NSTextFieldCell alloc] initTextCell:text];
    cell.font = [NSFont menuFontOfSize:0];
    cell.textColor = color;
    cell.alignment = alignment;
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.bezeled = NO;
    cell.drawsBackground = NO;
    cell.editable = NO;
    return cell;
}

- (NSArray<NSImage*>*)modifierImages {
    NSMutableArray* images = [NSMutableArray array];
    NSImageSymbolConfiguration* size = [NSImageSymbolConfiguration configurationWithPointSize:kModifierPointSize
                                                                                        weight:NSFontWeightRegular
                                                                                         scale:NSImageSymbolScaleSmall];
    for (NSString* name in ModifierSymbols(self.item.keyEquivalentModifierMask)) {
        NSImage* image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:size];
        if (image) [images addObject:image];
    }
    return images;
}

// The width the menu should make room for: image column, title, a gap, the key equivalent.
- (CGFloat)preferredWidth {
    NSMenuItem* item = self.item;
    CGFloat column = [self imageColumnWidth];
    CGFloat title = [item.title sizeWithAttributes:@{NSFontAttributeName : [NSFont menuFontOfSize:0]}].width;
    CGFloat key = 0;
    if (item.keyEquivalent.length) {
        key = 16 + kModifierGap + 24;
        for (NSImage* image in [self modifierImages]) key += image.size.width + kModifierSpacing;
    }
    return ceil(kImageX + (column ? column + kTitleGap : 0) + title + 8 + key + kTrailing);
}

- (void)viewWillMoveToWindow:(NSWindow*)window {
    [super viewWillMoveToWindow:window];
    if (window && self.item) {
        NSSize size = NSMakeSize(MAX(NSWidth(self.frame), [self preferredWidth]), kRowHeight);
        if (!NSEqualSizes(size, self.frame.size)) [self setFrameSize:size];
    }
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSMenuItem* item = self.item;
    if (!item) return;
    BOOL highlighted = self.isHighlighted;
    if (highlighted) {
        [NSColor.controlAccentColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:SPDFMacInstantMenuItemHighlightRect(self.bounds) xRadius:kHighlightRadius
                                         yRadius:kHighlightRadius] fill];
    }
    // The colours AppKit's item views end up with: the title at full strength (secondary when disabled), the image in
    // the label colour (tertiary when disabled), the key equivalent secondary; all in the selected-item colour on the
    // highlight.
    NSColor* selected = NSColor.selectedMenuItemTextColor;
    NSColor* text = highlighted ? selected : item.isEnabled ? NSColor.textColor : NSColor.secondaryLabelColor;
    NSColor* symbol = highlighted ? selected : item.isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    NSColor* key = highlighted ? selected : NSColor.secondaryLabelColor;
    CGFloat height = NSHeight(self.bounds), width = NSWidth(self.bounds);
    CGFloat textY = floor((height - kTextHeight) / 2);
    CGFloat column = [self imageColumnWidth];
    NSImage* image = MenuImage(item.image);
    if (image) {
        NSSize size = NSMakeSize(ceil(image.size.width), ceil(image.size.height));
        DrawImage(image, NSMakeRect(kImageX, (height - size.height) / 2, size.width, size.height), symbol);
    }
    CGFloat titleX = kImageX + (column > 0 ? column + kTitleGap : 0);
    CGFloat titleEnd = width - kTrailing;
    if (item.keyEquivalent.length) {
        // The key, right-aligned in its column, then its modifiers right to left.
        CGFloat keyRight = width - kTrailing;
        NSString* letter = item.keyEquivalent.uppercaseString;
        NSTextFieldCell* cell = [self cellWithText:letter color:key alignment:NSTextAlignmentRight];
        NSFont* keyFont = CFBridgingRelease(CTFontCreateUIFontForLanguage(kCTFontUIFontMenuItemCmdKey, 0, NULL));
        if (keyFont) cell.font = keyFont;
        CGFloat letterWidth = MAX(kKeyColumn, ceil(cell.cellSize.width));
        [cell drawWithFrame:NSMakeRect(keyRight - letterWidth, textY, letterWidth, kTextHeight) inView:self];
        // The cell keeps 2 points of padding on each side of the letter.
        CGFloat right = keyRight - letterWidth + 2 - kModifierGap;
        for (NSImage* modifier in [self modifierImages].reverseObjectEnumerator) {
            NSSize size = modifier.size;
            DrawImage(modifier, NSMakeRect(right - size.width, (height - size.height) / 2, size.width, size.height), key);
            right -= size.width + kModifierSpacing;
        }
        titleEnd = right - 8;
    }
    NSTextFieldCell* title = [self cellWithText:item.title color:text alignment:NSTextAlignmentNatural];
    [title drawWithFrame:NSMakeRect(titleX, textY, MAX(0, titleEnd - titleX), kTextHeight) inView:self];
}

#pragma mark Choosing

// Native items are chosen when the button comes up: so is this one, without the blink and the fade. The menu closes
// first; the action follows once the menu's tracking has ended (the next pass of the default run loop mode, well
// inside the same frame), where a native item's action would be sent too, so focus and the menu's delegate see the
// usual order.
- (void)choose {
    NSMenuItem* item = self.item;
    if (!item.isEnabled || !item.action) return;
    NSMenu* root = item.menu;
    while (root.supermenu) root = root.supermenu;
    [root cancelTrackingWithoutAnimation];
    SEL action = item.action;
    id target = item.target;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
      [NSApp sendAction:action to:target from:item];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)mouseDown:(NSEvent*)event {
    (void)event;
}

- (void)mouseUp:(NSEvent*)event {
    (void)event;
    [self choose];
}

- (void)rightMouseUp:(NSEvent*)event {
    (void)event;
    [self choose];
}

#pragma mark Highlight while the pointer moves

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hover) [self removeTrackingArea:_hover];
    _hover = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                          options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                  NSTrackingInVisibleRect
                                            owner:self
                                         userInfo:nil];
    [self addTrackingArea:_hover];
}

- (void)mouseEntered:(NSEvent*)event {
    (void)event;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event {
    (void)event;
    self.needsDisplay = YES;
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityMenuItemRole;
}

- (NSString*)accessibilityLabel {
    return self.item.title;
}

- (BOOL)isAccessibilityEnabled {
    return self.item.isEnabled;
}

- (BOOL)accessibilityPerformPress {
    [self choose];
    return YES;
}

@end

BOOL SPDFMacMakeMenuItemInstant(NSMenuItem* item) {
    if (@available(macOS 26.0, *)) {
        if (!item || item.isSeparatorItem || item.submenu) return NO;
        SPDFMacInstantMenuItemView* view = [[SPDFMacInstantMenuItemView alloc] initWithFrame:NSMakeRect(0, 0, 200, kRowHeight)];
        view.autoresizingMask = NSViewWidthSizable;
        view->_item = item;
        item.view = view;
        return YES;
    }
    return NO;
}
