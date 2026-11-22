#import "SPDFMacFillDrawingOptions.h"

#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillDrawingStyle.h"

typedef NS_ENUM(NSInteger, SPDFFillSwatchKind) { SPDFFillSwatchColor, SPDFFillSwatchWidth, SPDFFillSwatchEraser };

// One round choice: a colour dot, a width sample drawn in the chosen colour, or an eraser size.
@interface SPDFFillSwatch : NSButton
@property(nonatomic) SPDFFillSwatchKind kind;
@property(nonatomic) NSInteger index;
@property(nonatomic) BOOL chosen;
@property(nonatomic) SPDFFillRGB ink;  // width samples: the chosen colour
@end

@implementation SPDFFillSwatch

- (BOOL)acceptsFirstResponder { return NO; }

- (NSSize)intrinsicContentSize {
    return NSMakeSize(self.kind == SPDFFillSwatchWidth ? 30 : 24, 24);
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect bounds = self.bounds;
    NSColor* accent = NSColor.controlAccentColor;
    CGFloat alpha = self.enabled ? 1 : 0.35;
    if (self.kind == SPDFFillSwatchColor) {
        SPDFFillRGB c = [SPDFMacFillDrawingStyle colorAtIndex:self.index];
        NSRect dot = NSInsetRect(NSMakeRect(NSMidX(bounds) - 8, NSMidY(bounds) - 8, 16, 16), 0, 0);
        [[NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:alpha] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        if (self.chosen) {
            NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -3, -3)];
            ring.lineWidth = 2;
            [[accent colorWithAlphaComponent:alpha] setStroke];
            [ring stroke];
        }
        return;
    }
    if (self.chosen) {
        [[accent colorWithAlphaComponent:0.18 * alpha] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 2) xRadius:5 yRadius:5] fill];
    }
    if (self.kind == SPDFFillSwatchWidth) {
        NSBezierPath* line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(NSMinX(bounds) + 7, NSMidY(bounds))];
        [line lineToPoint:NSMakePoint(NSMaxX(bounds) - 7, NSMidY(bounds))];
        line.lineWidth = [SPDFMacFillDrawingStyle widthAtIndex:self.index] * 1.25;
        line.lineCapStyle = NSLineCapStyleRound;
        SPDFFillRGB c = self.ink;
        [[NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:alpha] setStroke];
        [line stroke];
    } else {
        CGFloat side = 6 + 4 * self.index;
        NSBezierPath* circle =
            [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(bounds) - side / 2, NSMidY(bounds) - side / 2, side, side)];
        circle.lineWidth = 1.25;
        [[NSColor.labelColor colorWithAlphaComponent:0.8 * alpha] setStroke];
        [circle stroke];
    }
}

@end

@implementation SPDFMacFillDrawingOptions {
    __weak id<SPDFMacFillDrawingOptionsTarget> _target;
    NSStackView* _row;
    NSArray<SPDFFillSwatch*>* _colors;
    NSArray<SPDFFillSwatch*>* _widths;
    NSArray<SPDFFillSwatch*>* _sizes;
    NSSegmentedControl* _eraserKind;
    NSView* _gap;
    NSButton* _bin;
}

- (instancetype)initWithTarget:(id<SPDFMacFillDrawingOptionsTarget>)target {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _target = target;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self build];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSArray<SPDFFillSwatch*>*)swatches:(SPDFFillSwatchKind)kind count:(NSInteger)count names:(NSString* (^)(NSInteger))name {
    NSMutableArray* swatches = [NSMutableArray array];
    for (NSInteger i = 0; i < count; ++i) {
        SPDFFillSwatch* swatch = [[SPDFFillSwatch alloc] initWithFrame:NSZeroRect];
        swatch.kind = kind;
        swatch.index = i;
        swatch.bordered = NO;
        swatch.title = @"";
        swatch.refusesFirstResponder = YES;
        swatch.target = self;
        swatch.action = @selector(swatchClicked:);
        swatch.toolTip = name(i);
        swatch.accessibilityLabel = name(i);
        swatch.translatesAutoresizingMaskIntoConstraints = NO;
        [swatches addObject:swatch];
    }
    return swatches;
}

- (void)build {
    _colors = [self swatches:SPDFFillSwatchColor count:[SPDFMacFillDrawingStyle colorCount]
                       names:^NSString*(NSInteger i) { return [SPDFMacFillDrawingStyle colorNameAtIndex:i]; }];
    _widths = [self swatches:SPDFFillSwatchWidth count:[SPDFMacFillDrawingStyle widthCount]
                       names:^NSString*(NSInteger i) { return [SPDFMacFillDrawingStyle widthNameAtIndex:i]; }];
    _sizes = [self swatches:SPDFFillSwatchEraser count:[SPDFMacFillDrawingStyle eraserSizeCount]
                      names:^NSString*(NSInteger i) { return [SPDFMacFillDrawingStyle eraserSizeNameAtIndex:i]; }];
    _eraserKind = [NSSegmentedControl segmentedControlWithLabels:@[ @"Whole lines", @"Parts" ]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self
                                                          action:@selector(eraserKindChosen:)];
    [_eraserKind setToolTip:@"Erases every line you touch" forSegment:0];
    [_eraserKind setToolTip:@"Erases only where you rub" forSegment:1];
    _eraserKind.controlSize = NSControlSizeSmall;
    _eraserKind.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _eraserKind.refusesFirstResponder = YES;
    _gap = SPDFCollectionSurface(@"line");
    _gap.translatesAutoresizingMaskIntoConstraints = NO;
    [_gap.widthAnchor constraintEqualToConstant:1].active = YES;
    [_gap.heightAnchor constraintEqualToConstant:16].active = YES;
    NSString* binLabel = @"Remove all pen lines and arrows in this document";
    _bin = SPDFCollectionButton(@"", self, @selector(removeAll:), @"quiet");
    NSImage* trash = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:binLabel];
    [trash setTemplate:YES];
    _bin.image = trash;
    if (!trash) _bin.title = @"Remove All";
    _bin.toolTip = binLabel;
    _bin.accessibilityLabel = binLabel;
    _bin.refusesFirstResponder = YES;
    _bin.translatesAutoresizingMaskIntoConstraints = NO;
    [_bin.heightAnchor constraintEqualToConstant:24].active = YES;
    NSMutableArray* views = [NSMutableArray array];
    [views addObjectsFromArray:_colors];
    [views addObjectsFromArray:_widths];
    [views addObject:_eraserKind];
    [views addObjectsFromArray:_sizes];
    [views addObject:_gap];
    [views addObject:_bin];
    _row = [NSStackView stackViewWithViews:views];
    _row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _row.alignment = NSLayoutAttributeCenterY;
    _row.spacing = 2;
    [_row setCustomSpacing:10 afterView:_colors.lastObject];
    [_row setCustomSpacing:10 afterView:_widths.lastObject];
    [_row setCustomSpacing:8 afterView:_eraserKind];
    [_row setCustomSpacing:8 afterView:_sizes.lastObject];
    [_row setCustomSpacing:6 afterView:_gap];
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_row];
    [NSLayoutConstraint activateConstraints:@[
        [_row.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_row.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_row.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor],
    ]];
}

- (void)showTool:(SPDFFillTool)tool styleable:(BOOL)styleable {
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];
    BOOL eraser = tool == SPDFFillToolEraser;
    BOOL styles = tool == SPDFFillToolPen || tool == SPDFFillToolArrow || tool == SPDFFillToolSelect;
    BOOL usable = tool != SPDFFillToolSelect || styleable;
    for (SPDFFillSwatch* swatch in _colors) {
        swatch.hidden = !styles;
        swatch.enabled = usable;
        swatch.chosen = swatch.index == style.colorIndex;
        swatch.needsDisplay = YES;
    }
    for (SPDFFillSwatch* swatch in _widths) {
        swatch.hidden = !styles;
        swatch.enabled = usable;
        swatch.chosen = swatch.index == style.widthIndex;
        swatch.ink = style.color;
        swatch.needsDisplay = YES;
    }
    _eraserKind.hidden = !eraser;
    _eraserKind.selectedSegment = style.eraserParts ? 1 : 0;
    for (SPDFFillSwatch* swatch in _sizes) {
        swatch.hidden = !eraser || !style.eraserParts;
        swatch.chosen = swatch.index == style.eraserSizeIndex;
        swatch.needsDisplay = YES;
    }
}

- (void)swatchClicked:(SPDFFillSwatch*)sender {
    switch (sender.kind) {
        case SPDFFillSwatchColor: [_target drawingOptionsChoseColor:sender.index]; break;
        case SPDFFillSwatchWidth: [_target drawingOptionsChoseWidth:sender.index]; break;
        case SPDFFillSwatchEraser: [_target drawingOptionsChoseEraserSize:sender.index]; break;
    }
}

- (void)eraserKindChosen:(NSSegmentedControl*)sender {
    [_target drawingOptionsChoseEraserParts:sender.selectedSegment == 1];
}

- (void)removeAll:(id)sender {
    (void)sender;
    [_target drawingOptionsRemoveAll];
}

@end
