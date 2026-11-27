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

static NSButton* SPDFLayerRowButton(NSString* symbol, NSString* label, id target, SEL action) {
    NSButton* button = [NSButton buttonWithImage:SPDFAnnotateSymbol(symbol, label) ?: [NSImage new] target:target action:action];
    button.bordered = NO;
    button.refusesFirstResponder = YES;
    button.toolTip = label;
    return button;
}

+ (instancetype)rowWithTarget:(id)target object:(BOOL)object eyeAction:(SEL)eyeAction lockAction:(SEL)lockAction
                 discloseAction:(SEL)discloseAction opacityAction:(SEL)opacityAction {
    SPDFAnnotateLayerRow* cell = [[self alloc] initWithFrame:NSZeroRect];
    cell.identifier = object ? @"object" : @"layer";
    cell.thumb = [NSImageView imageViewWithImage:[NSImage new]];
    cell.thumb.imageScaling = NSImageScaleProportionallyDown;
    cell.name = [SPDFAnnotateNameField labelWithString:@""];
    cell.name.font = [NSFont systemFontOfSize:object ? 11 : 12];
    cell.name.textColor = SPDFCollectionColor(@"text");
    cell.name.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detail = SPDFCollectionText(@"", 10, NSFontWeightRegular, YES);
    cell.detail.maximumNumberOfLines = 1;
    cell.detail.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.badge = [NSImageView imageViewWithImage:[NSImage new]];
    cell.badge.contentTintColor = NSColor.secondaryLabelColor;
    cell.badge.wantsLayer = YES;  // a round chip on the thumbnail's corner
    cell.badge.layer.cornerRadius = 7;
    cell.badge.layer.backgroundColor = SPDFCollectionColor(@"popover").CGColor;
    cell.disclosure = SPDFLayerRowButton(@"chevron.down", @"Hide its objects", target, discloseAction);
    cell.lock = SPDFLayerRowButton(@"lock.open", @"Lock", target, lockAction);
    cell.eye = SPDFLayerRowButton(@"eye", @"Hide", target, eyeAction);
    cell->_target = target;
    cell->_opacityAction = opacityAction;
    cell.percent = [SPDFAnnotateValueField valueFieldWithFontSize:10 tip:@"Opacity: click to type a value"];
    cell.percent.alignment = NSTextAlignmentRight;
    cell.percent.hidden = YES;
    for (NSView* v in @[ cell.thumb, cell.name, cell.detail, cell.badge, cell.disclosure, cell.lock, cell.eye, cell.percent ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:v];
    }
    CGFloat side = object ? 24 : 36;
    cell.disclosure.hidden = cell.detail.hidden = cell.lock.hidden = object;
    [NSLayoutConstraint activateConstraints:@[
        [cell.disclosure.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
        [cell.disclosure.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.disclosure.widthAnchor constraintEqualToConstant:16],
        [cell.thumb.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:object ? 34 : 20],
        [cell.thumb.topAnchor constraintEqualToAnchor:cell.topAnchor constant:object ? 3 : 4],
        [cell.thumb.widthAnchor constraintEqualToConstant:side], [cell.thumb.heightAnchor constraintEqualToConstant:side],
        [cell.name.leadingAnchor constraintEqualToAnchor:cell.thumb.trailingAnchor constant:8],
        [cell.name.trailingAnchor constraintLessThanOrEqualToAnchor:cell.lock.leadingAnchor constant:-4],
        object ? [cell.name.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor]
               : [cell.name.bottomAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor constant:1],
        [cell.detail.leadingAnchor constraintEqualToAnchor:cell.name.leadingAnchor],
        [cell.detail.topAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor constant:1],
        [cell.detail.trailingAnchor constraintLessThanOrEqualToAnchor:cell.lock.leadingAnchor constant:-2],
        // The brush (drawing goes here) or a lock, on the thumbnail's corner.
        [cell.badge.trailingAnchor constraintEqualToAnchor:cell.thumb.trailingAnchor constant:4],
        [cell.badge.bottomAnchor constraintEqualToAnchor:cell.thumb.bottomAnchor constant:4],
        [cell.badge.widthAnchor constraintEqualToConstant:14], [cell.badge.heightAnchor constraintEqualToConstant:14],
        [cell.lock.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        cell.lockWidth = [cell.lock.widthAnchor constraintEqualToConstant:object ? 0 : 22],
        [cell.eye.leadingAnchor constraintEqualToAnchor:cell.lock.trailingAnchor constant:2],
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
    if ([responder isKindOfClass:[SPDFAnnotateNameField class]]) return [(SPDFAnnotateNameField*)responder isEditable];
    return [responder isKindOfClass:[SPDFAnnotateValueField class]] || [super validateProposedFirstResponder:responder forEvent:event];
}
@end

@interface SPDFAnnotateNameField () <NSTextFieldDelegate>
@property(nonatomic) BOOL cancelled;
@property(nonatomic, copy) NSString* before;
@end

@implementation SPDFAnnotateNameField

- (void)beginRenaming {
    if (!self.window) return;
    self.before = self.stringValue;
    self.cancelled = NO;
    self.editable = YES;
    self.delegate = self;
    if ([self.window makeFirstResponder:self]) [self.currentEditor selectAll:nil];
    else self.editable = NO;
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control; (void)textView;
    if (command == @selector(cancelOperation:)) self.cancelled = YES;
    if (command != @selector(cancelOperation:) && command != @selector(insertNewline:)) return NO;
    NSView* keys = self.keysView ? self.keysView() : nil;
    [self.window makeFirstResponder:keys.window == self.window ? keys : nil];
    return YES;
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
    (void)note;
    NSString* typed = [self.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL use = !self.cancelled && typed.length && ![typed isEqual:self.before];
    self.editable = NO;
    if (!use) self.stringValue = self.before ?: @"";
    else if (self.renamed) self.renamed(typed);
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
