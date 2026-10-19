#import "SPDFMacIconGeometry.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacCollectionStyle.h"
static NSColor* Hex(unsigned value) {
    return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0 green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:1];
}
NSColor* SPDFCollectionColor(NSString* token) {
    NSDictionary* palette = @{@"titlebar":@[@0xe8e8eb,@0x202125],@"window":@[@0xffffff,@0x292b2e],@"sidebar":@[@0xf6f6f5,@0x232426],
        @"pane":@[@0xf6f6f5,@0x232426],@"text":@[@0x26282b,@0xeceef1],@"secondary":@[@0x61666d,@0xb3b7be],
        @"line":@[@0xdddfdf,@0x414448],@"control":@[@0xf6f6f5,@0x232426],@"selected":@[@0xdbe5f0,@0x374b61],
        @"accent":@[@0x286398,@0xa1c9ed],@"hover":@[@0xe8ebed,@0x393d42],@"highlight":@[@0xffe59a,@0x685521]};
    NSArray* pair = palette[token] ?: palette[@"text"];
    return [NSColor colorWithName:[@"Collection." stringByAppendingString:token] dynamicProvider:^NSColor*(NSAppearance* appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        return Hex([pair[dark ? 1 : 0] unsignedIntValue]);
    }];
}
@interface SPDFCollectionSurfaceView : NSView
@property(nonatomic) NSString* token;
@end
@implementation SPDFCollectionSurfaceView
- (BOOL)wantsDefaultClipping { return YES; }
- (void)drawRect:(NSRect)dirty { (void)dirty; [SPDFCollectionColor(self.token) setFill]; NSRectFill(self.bounds); }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end
@interface SPDFCollectionFlatButton : NSButton
@property(nonatomic) NSString* kind;
@property(nonatomic) BOOL hovered;
@property(nonatomic) NSTrackingArea* hoverTracking;
@end
@implementation SPDFCollectionFlatButton
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if (self.hoverTracking) [self removeTrackingArea:self.hoverTracking];
    self.hoverTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTracking];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event { (void)event; self.hovered = NO; self.needsDisplay = YES; }
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0,0,0,0); }
- (NSSize)intrinsicContentSize {
    CGFloat width = [self.title sizeWithAttributes:@{NSFontAttributeName:self.font ?: [NSFont systemFontOfSize:13]}].width;
    return NSMakeSize(ceil(width)+18+(self.image ? 24 : 0),30);
}
- (void)setState:(NSControlStateValue)state { [super setState:state]; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty; BOOL quiet = ![self.kind isEqual:@"normal"];
    BOOL selected = self.state == NSControlStateValueOn || self.highlighted;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    if (!quiet || selected || self.hovered) { [SPDFCollectionColor(selected ? @"selected" : self.hovered ? @"hover" : @"control") setFill]; [shape fill]; }

    NSRect titleRect = NSInsetRect(self.bounds,9,3);
    if (self.image) {
        NSRect icon = NSMakeRect(NSMinX(titleRect),floor(NSMidY(self.bounds)-7.5),15,15);
        NSImage* symbol = self.image;
        if (@available(macOS 12.0,*)) symbol = [symbol imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPaletteColors:@[SPDFChromeIconColor(self.enabled)]]] ?: symbol;
        SPDFDrawVectorIcon(symbol,icon,YES);
        titleRect.origin.x += 24; titleRect.size.width -= 24;
    }
    NSMutableAttributedString* title = [self.attributedTitle mutableCopy];
    NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = [self.kind isEqual:@"nav"] ? NSTextAlignmentLeft : self.alignment;
    paragraph.lineBreakMode = self.cell.wraps ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    paragraph.lineSpacing = self.cell.wraps ? 3 : 0;
    if ([self.kind isEqual:@"match"]) {
        paragraph.headIndent = 45;
        paragraph.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:45 options:@{}]];
        [title addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0,title.length)];
    } else {
        [title addAttributes:@{NSFontAttributeName:self.font ?: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName:(self.enabled ? SPDFCollectionColor([self.kind isEqual:@"link"] ? @"accent" : @"text") : SPDFChromeIconColor(NO)),
            NSParagraphStyleAttributeName:paragraph} range:NSMakeRange(0,title.length)];
    }
    NSRect measured = [title boundingRectWithSize:titleRect.size options:NSStringDrawingUsesLineFragmentOrigin];
    if (!self.cell.wraps) { titleRect.origin.y = floor(NSMidY(self.bounds)-measured.size.height/2); titleRect.size.height = measured.size.height; }
    [title drawWithRect:titleRect options:NSStringDrawingUsesLineFragmentOrigin];
    if (self.window.firstResponder == self) { [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState]; }
}
@end
@interface SPDFCollectionFlatPopUp : NSPopUpButton
@end
@implementation SPDFCollectionFlatPopUp
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0,0,0,0); }
- (NSSize)intrinsicContentSize {
    CGFloat width = 0;
    NSArray* titles = self.pullsDown && self.numberOfItems ? @[[self itemTitleAtIndex:0]] : self.itemTitles;
    for (NSString* title in titles) width = MAX(width,[title sizeWithAttributes:@{NSFontAttributeName:self.font ?: [NSFont systemFontOfSize:13]}].width);
    return NSMakeSize(ceil(width)+34,26);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty; NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    [SPDFCollectionColor(@"control") setFill]; [shape fill]; [SPDFCollectionColor(@"line") setStroke]; [shape stroke];
    NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new]; paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary* attributes = @{NSFontAttributeName:self.font ?: [NSFont systemFontOfSize:13],NSForegroundColorAttributeName:SPDFCollectionColor(@"text"),NSParagraphStyleAttributeName:paragraph};
    [self.title drawInRect:NSMakeRect(9,floor((NSHeight(self.bounds)-16)/2),NSWidth(self.bounds)-32,18) withAttributes:attributes];
    NSImage* image = [NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil];
    if (@available(macOS 12.0,*)) image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[SPDFCollectionColor(@"text")]]] ?: image;
    SPDFDrawVectorIcon(image,NSMakeRect(NSWidth(self.bounds)-20,floor(NSMidY(self.bounds)-5),10,10),YES);
    if (self.window.firstResponder == self) { [NSGraphicsContext saveGraphicsState]; NSSetFocusRingStyle(NSFocusRingOnly); [shape fill]; [NSGraphicsContext restoreGraphicsState]; }
}
@end
static NSBezierPath* SearchShape(NSRect bounds) {
    return [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds,.5,.5) xRadius:6 yRadius:6];
}
@interface SPDFCollectionSearchCell : NSSearchFieldCell
@property(nonatomic) BOOL editingRectPrepared;
@end
@implementation SPDFCollectionSearchCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    NSBezierPath* shape = SearchShape(frame);
    [SPDFCollectionColor(@"pane") setFill]; [shape fill];
    [SPDFCollectionColor(@"line") setStroke]; [shape stroke];
    [super drawWithFrame:frame inView:view];
}
- (NSRect)focusRingMaskBoundsForFrame:(NSRect)frame inView:(NSView*)view { (void)view; return frame; }
- (void)drawFocusRingMaskWithFrame:(NSRect)frame inView:(NSView*)view { (void)view; [SearchShape(frame) fill]; }
// Borderless search chrome needs the same inset for static text and the AppKit field editor.
// The inherited editing methods otherwise use the entire 31-point control bounds.
- (void)selectWithFrame:(NSRect)frame inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate
                  start:(NSInteger)start length:(NSInteger)length {
    BOOL prepared = self.editingRectPrepared; self.editingRectPrepared = YES;
    [super selectWithFrame:prepared ? frame : [self searchTextRectForBounds:frame] inView:view
        editor:editor delegate:delegate start:start length:length];
    self.editingRectPrepared = prepared;
}
- (void)editWithFrame:(NSRect)frame inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate event:(NSEvent*)event {
    BOOL prepared = self.editingRectPrepared; self.editingRectPrepared = YES;
    [super editWithFrame:prepared ? frame : [self searchTextRectForBounds:frame] inView:view
        editor:editor delegate:delegate event:event];
    self.editingRectPrepared = prepared;
}
- (NSRect)searchTextRectForBounds:(NSRect)bounds {
    CGFloat height = ceil((self.font ?: [NSFont systemFontOfSize:13]).ascender - (self.font ?: [NSFont systemFontOfSize:13]).descender + 2);
    return NSMakeRect(NSMinX(bounds)+29,floor(NSMidY(bounds)-height/2),MAX(0,NSWidth(bounds)-54),height);
}
- (NSRect)drawingRectForBounds:(NSRect)bounds { return [self searchTextRectForBounds:bounds]; }
- (NSRect)titleRectForBounds:(NSRect)bounds { return [self searchTextRectForBounds:bounds]; }
- (NSRect)searchButtonRectForBounds:(NSRect)bounds {
    return NSMakeRect(NSMinX(bounds)+9,floor(NSMidY(bounds)-7.5),15,15);
}
- (NSRect)cancelButtonRectForBounds:(NSRect)bounds {
    return NSMakeRect(NSMaxX(bounds)-24,floor(NSMidY(bounds)-7.5),15,15);
}
@end
@interface SPDFCollectionFlatSearch : NSSearchField
@end
@implementation SPDFCollectionFlatSearch
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [SearchShape(self.bounds) fill]; }
- (NSEdgeInsets)alignmentRectInsets { return NSEdgeInsetsMake(0,0,0,0); }

@end
NSButton* SPDFCollectionButton(NSString* title,id target,SEL action,NSString* kind) {
    SPDFCollectionFlatButton* button = [[SPDFCollectionFlatButton alloc] init]; button.kind = kind;
    button.title = title; button.target = target; button.action = action; button.bordered = NO;
    button.font = [NSFont systemFontOfSize:[kind isEqual:@"nav"] ? 12 : 11]; button.alignment = NSTextAlignmentCenter;
    // AppKit defaults to wrapping, which pins a single label to the top inset.
    // Contextual match buttons opt into multiline wrapping after construction.
    button.cell.wraps = NO;
    button.focusRingType = NSFocusRingTypeExterior; return button;
}
NSPopUpButton* SPDFCollectionPopUp(void) {
    SPDFCollectionFlatPopUp* button = [SPDFCollectionFlatPopUp new]; button.bordered = NO;
    button.font = [NSFont systemFontOfSize:13]; [button.heightAnchor constraintEqualToConstant:26].active = YES; return button;
}
void SPDFCollectionConfigureSearchField(NSSearchField* field) {
    NSString* text = field.stringValue, *placeholder = field.placeholderString;
    // Never copy an attached NSSearchFieldCell: AppKit copies its KVO ownership.
    field.cell = [[SPDFCollectionSearchCell alloc] initTextCell:text ?: @""];
    field.placeholderString = placeholder; field.bordered = NO; field.bezeled = NO;
    field.editable = YES; field.selectable = YES; field.cell.usesSingleLineMode = YES; field.cell.scrollable = YES;
    field.drawsBackground = NO; field.font = [NSFont systemFontOfSize:13]; field.textColor = SPDFCollectionColor(@"text");
}
NSSearchField* SPDFCollectionSearchField(void) {
    SPDFCollectionFlatSearch* field = [SPDFCollectionFlatSearch new]; SPDFCollectionConfigureSearchField(field); return field;
}
NSTextField* SPDFCollectionText(NSString* text,CGFloat size,NSFontWeight weight,BOOL secondary) {
    NSTextField* field = [NSTextField wrappingLabelWithString:text]; field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = SPDFCollectionColor(secondary ? @"secondary" : @"text"); return field;
}
NSView* SPDFCollectionSurface(NSString* token) { SPDFCollectionSurfaceView* view = [SPDFCollectionSurfaceView new]; view.token = token; return view; }
NSView* SPDFCollectionDivider(void) { NSView* line = SPDFCollectionSurface(@"line"); [line.heightAnchor constraintEqualToConstant:1].active = YES; return line; }

BOOL SPDFCollectionVersionIsLatest(NSDictionary* document, NSDictionary* version) {
    NSString* latest = document[@"latestVersionID"] ?: [document[@"versions"] lastObject][@"id"];
    return [version[@"id"] length] && [version[@"id"] isEqual:latest];
}
@interface SPDFCollectionLatestBadgeView : NSView
@end
@implementation SPDFCollectionLatestBadgeView
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.identifier = @"CollectionLatestBadge";
    NSTextField* title = SPDFCollectionText(@"Latest",11,NSFontWeightSemibold,NO);
    title.textColor = SPDFCollectionColor(@"accent"); title.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:title];
    [NSLayoutConstraint activateConstraints:@[[title.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]]];
    [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return self;
}
- (NSSize)intrinsicContentSize { NSTextField* title=(id)self.subviews.firstObject; return NSMakeSize(MAX(49,ceil(title.intrinsicContentSize.width)+16),20); }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString*)accessibilityRole { return NSAccessibilityStaticTextRole; }
- (NSString*)accessibilityLabel { return [(NSTextField*)self.subviews.firstObject stringValue]; }
- (NSArray*)accessibilityChildren { return @[]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:10 yRadius:10];
    [SPDFCollectionColor(@"pane") setFill]; [shape fill];
    [[SPDFCollectionColor(@"accent") colorWithAlphaComponent:.5] setStroke]; [shape stroke];
}
@end
NSView* SPDFCollectionLatestBadge(void) { return [SPDFCollectionLatestBadgeView new]; }

NSView* SPDFCollectionLatestCopyBadge(void) {
    NSView* badge=SPDFCollectionLatestBadge();
    [(NSTextField*)badge.subviews.firstObject setStringValue:@"Latest copy"];
    [badge invalidateIntrinsicContentSize]; return badge;
}
