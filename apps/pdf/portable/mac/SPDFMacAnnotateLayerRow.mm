// A row of the Layers panel (SPDFMacAnnotateLayerRow.h).
#import "SPDFMacAnnotateLayerRow.h"

#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacCollectionStyle.h"

@implementation SPDFAnnotateLayerRow {
    __weak id _target;
    SEL _opacityAction;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect box = self.thumb.frame;  // the checkerboard shows where the thumbnail is transparent
    for (CGFloat y = 0; y < NSHeight(box); y += 6)
        for (CGFloat x = 0; x < NSWidth(box); x += 6) {
            BOOL dark = ((NSInteger)(x / 6) + (NSInteger)(y / 6)) % 2;
            [[NSColor colorWithWhite:dark ? 0.91 : 1 alpha:1] setFill];
            NSRectFill(NSIntersectionRect(box, NSMakeRect(NSMinX(box) + x, NSMinY(box) + y, 6, 6)));
        }
    [[NSColor.labelColor colorWithAlphaComponent:0.2] setStroke];
    NSFrameRect(box);
}

+ (instancetype)rowWithTarget:(id)target eyeAction:(SEL)eyeAction opacityAction:(SEL)opacityAction {
    SPDFAnnotateLayerRow* cell = [[self alloc] initWithFrame:NSZeroRect];
    cell.identifier = @"layer";
    cell.thumb = [NSImageView imageViewWithImage:[NSImage new]];
    cell.thumb.imageScaling = NSImageScaleProportionallyDown;
    cell.name = SPDFCollectionText(@"", 12, NSFontWeightRegular, NO);
    cell.name.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.badge = [NSImageView imageViewWithImage:[NSImage new]];
    cell.badge.contentTintColor = NSColor.secondaryLabelColor;
    cell.eye = [NSButton buttonWithImage:SPDFAnnotateSymbol(@"eye", @"Hide") ?: [NSImage new] target:target
                                  action:eyeAction];
    cell.eye.bordered = NO;
    cell.eye.refusesFirstResponder = YES;
    cell->_target = target;
    cell->_opacityAction = opacityAction;
    cell.percent = [SPDFAnnotateValueField valueFieldWithFontSize:10 tip:@"Opacity: click to type a value"];
    cell.percent.alignment = NSTextAlignmentRight;
    cell.percent.hidden = YES;
    for (NSView* v in @[ cell.thumb, cell.name, cell.badge, cell.eye, cell.percent ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [cell.thumb.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
        [cell.thumb.topAnchor constraintEqualToAnchor:cell.topAnchor constant:4],
        [cell.thumb.widthAnchor constraintEqualToConstant:36], [cell.thumb.heightAnchor constraintEqualToConstant:36],
        [cell.name.leadingAnchor constraintEqualToAnchor:cell.thumb.trailingAnchor constant:8],
        [cell.name.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.badge.leadingAnchor constraintEqualToAnchor:cell.name.trailingAnchor constant:4],
        [cell.badge.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.badge.widthAnchor constraintEqualToConstant:14],
        [cell.eye.leadingAnchor constraintGreaterThanOrEqualToAnchor:cell.badge.trailingAnchor constant:4],
        [cell.eye.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
        [cell.eye.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.eye.widthAnchor constraintEqualToConstant:24],
        [cell.percent.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [cell.percent.widthAnchor constraintEqualToConstant:38],
    ]];
    [cell.name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return cell;
}

// Only a selected row shows a slider, and a slider is costly to make (a few milliseconds each on macOS 26): every
// row had one, and a change that reloads the list made them all again.
- (void)showOpacity:(double)percent visible:(BOOL)visible {
    if (visible && !self.opacity) {
        self.opacity = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:_target action:_opacityAction];
        self.opacity.continuous = NO;  // one change, written when the slider is let go
        self.opacity.controlSize = NSControlSizeSmall;
        self.opacity.toolTip = @"Opacity";
        self.opacity.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.opacity];
        [NSLayoutConstraint activateConstraints:@[
            [self.opacity.leadingAnchor constraintEqualToAnchor:self.name.leadingAnchor],
            [self.opacity.topAnchor constraintEqualToAnchor:self.thumb.bottomAnchor constant:2],
            [self.percent.leadingAnchor constraintEqualToAnchor:self.opacity.trailingAnchor constant:6],
            [self.percent.centerYAnchor constraintEqualToAnchor:self.opacity.centerYAnchor],
        ]];
    }
    self.opacity.hidden = self.percent.hidden = !visible;
    self.opacity.doubleValue = percent;
    // Being typed in: left alone (the editing ends with the value used, shown again then).
    if (!self.percent.editing) self.percent.stringValue = [NSString stringWithFormat:@"%.0f %%", percent];
}

@end

@implementation SPDFAnnotateLayerTable
- (BOOL)validateProposedFirstResponder:(NSResponder*)responder forEvent:(NSEvent*)event {
    return [responder isKindOfClass:[SPDFAnnotateValueField class]] || [super validateProposedFirstResponder:responder forEvent:event];
}
@end

NSImage* SPDFAnnotateThumbnailImage(const spdf_bitmap* b) {
    if (!b->rgba || b->width <= 0 || b->height <= 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(b->rgba, (size_t)b->width, (size_t)b->height, 8, (size_t)b->stride, space,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef image = cg ? CGBitmapContextCreateImage(cg) : NULL;
    NSImage* result = image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(b->width / 2.0, b->height / 2.0)] : nil;
    if (image) CGImageRelease(image);
    if (cg) CGContextRelease(cg);
    CGColorSpaceRelease(space);
    return result;
}
