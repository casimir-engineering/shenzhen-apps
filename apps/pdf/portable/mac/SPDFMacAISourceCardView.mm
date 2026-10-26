#import "SPDFMacAISourceCardView.h"
#import "SPDFMacCollectionStyle.h"

static const CGFloat kCardHeight = 68, kThumbWidth = 38, kThumbHeight = 50;

@implementation SPDFMacAISourceCardView {
    void (^_open)(NSURL*);
    NSTrackingArea* _hoverArea;
    BOOL _hovered, _pressed;
    NSString* _pageLabel;
}
- (instancetype)initWithSource:(NSDictionary*)source open:(void (^)(NSURL*))open {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 300, kCardHeight)])) return nil;
    _link = source[@"link"]; _title = [source[@"title"] copy] ?: @"Document";
    _page = MAX(1, [source[@"page"] integerValue]); _open = [open copy];
    _pageLabel = [NSString stringWithFormat:@"Page %ld", (long)_page];
    self.identifier = @"answerSourceCard";
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self.heightAnchor constraintEqualToConstant:kCardHeight].active = YES;
    self.toolTip = [NSString stringWithFormat:@"Open %@ at page %ld", _title, (long)_page];
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setThumbnail:(NSImage*)thumbnail { _thumbnail = thumbnail; self.needsDisplay = YES; }
- (void)open { if (_open && _link) _open(_link); }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent*)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent*)event { (void)event; _pressed = YES; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent*)event {
    BOOL inside = NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
    _pressed = NO; self.needsDisplay = YES;
    if (inside) [self open];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5) xRadius:8 yRadius:8];
    [SPDFCollectionColor(_pressed ? @"selected" : _hovered ? @"hover" : @"control") setFill]; [shape fill];
    [SPDFCollectionColor(@"line") setStroke]; shape.lineWidth = 1; [shape stroke];
    NSRect thumb = NSMakeRect(12, (kCardHeight - kThumbHeight) / 2, kThumbWidth, kThumbHeight);
    NSImage* image = _thumbnail;
    if (image.size.width > 0 && image.size.height > 0) {
        // The page itself, outlined like a Collection preview, so a white page stays visible on a light card.
        CGFloat scale = MIN(kThumbWidth / image.size.width, kThumbHeight / image.size.height);
        NSRect page = NSMakeRect(NSMidX(thumb) - image.size.width * scale / 2, NSMidY(thumb) - image.size.height * scale / 2,
                                 image.size.width * scale, image.size.height * scale);
        [image drawInRect:page fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
           respectFlipped:YES hints:nil];
        [SPDFCollectionColor(@"line") setStroke];
        [NSBezierPath strokeRect:NSInsetRect(NSIntegralRect(page), .5, .5)];
    } else {
        NSImageSymbolConfiguration* config = [[NSImageSymbolConfiguration configurationWithPointSize:22
            weight:NSFontWeightLight] configurationByApplyingConfiguration:[NSImageSymbolConfiguration
            configurationWithPaletteColors:@[ SPDFCollectionColor(@"secondary") ]]];
        NSImage* symbol = [[NSImage imageWithSystemSymbolName:@"doc.text" accessibilityDescription:nil]
            imageWithSymbolConfiguration:config];
        NSRect box = NSMakeRect(NSMidX(thumb) - symbol.size.width / 2, NSMidY(thumb) - symbol.size.height / 2,
                                symbol.size.width, symbol.size.height);
        [symbol drawInRect:box fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
            respectFlipped:YES hints:nil];
    }
    CGFloat left = NSMaxX(thumb) + 12, width = MAX(20, NSWidth(self.bounds) - left - 34);
    NSMutableParagraphStyle* truncate = [NSMutableParagraphStyle new];
    truncate.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_title drawInRect:NSMakeRect(left, 16, width, 17) withAttributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : SPDFCollectionColor(@"text"), NSParagraphStyleAttributeName : truncate}];
    [_pageLabel drawInRect:NSMakeRect(left, 36, width, 16) withAttributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:11], NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary"),
        NSParagraphStyleAttributeName : truncate}];
    NSImageSymbolConfiguration* arrowStyle = [[NSImageSymbolConfiguration configurationWithPointSize:11
        weight:NSFontWeightMedium] configurationByApplyingConfiguration:[NSImageSymbolConfiguration
        configurationWithPaletteColors:@[ SPDFCollectionColor(@"secondary") ]]];
    NSImage* arrow = [[NSImage imageWithSystemSymbolName:@"arrow.up.forward" accessibilityDescription:nil]
        imageWithSymbolConfiguration:arrowStyle];
    [arrow drawInRect:NSMakeRect(NSWidth(self.bounds) - 24, (kCardHeight - arrow.size.height) / 2, arrow.size.width,
                                 arrow.size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
             fraction:1 respectFlipped:YES hints:nil];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString*)accessibilityLabel { return [NSString stringWithFormat:@"Open %@, page %ld", _title, (long)_page]; }
- (BOOL)accessibilityPerformPress { [self open]; return YES; }
@end
