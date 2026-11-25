// The status bar at the bottom of the page area while Annotate is on (docs/plans/annotate.md § 1 Status bar): pointer
// position, selection or object size, canvas or page size (px on pictures, pt on PDFs, with the page number), Fit,
// the zoom percentage menu and the zoom slider. View > Status Bar shows or hides it (SPDFAnnotateSettings).
#import "SPDFMacAnnotateOperations.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacFillController.h"

static char kSPDFAnnotateStatusBarKey;
static const CGFloat kBarHeight = 24;

@interface SPDFAnnotateStatusBarView : NSVisualEffectView
@property(nonatomic, weak) SPDFMacFillController* controller;
@property(nonatomic, weak) SPDFMacAnnotateSession* session;
@property(nonatomic, strong) NSTextField* pointer;
@property(nonatomic, strong) NSTextField* selection;
@property(nonatomic, strong) NSTextField* size;
@property(nonatomic, strong) NSButton* fit;
@property(nonatomic, strong) NSPopUpButton* zoom;
@property(nonatomic, strong) NSSlider* slider;
@property(nonatomic, strong) NSImageView* pointerGlyph;
@property(nonatomic, strong) NSImageView* selectionGlyph;
@end

static NSTextField* Label(NSString* tooltip) {
    NSTextField* label = [NSTextField labelWithString:@""];
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.textColor = NSColor.secondaryLabelColor;
    label.toolTip = tooltip;
    label.lineBreakMode = NSLineBreakByClipping;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

static NSImageView* Glyph(NSString* symbol) {
    NSImageView* view = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol
                                                                    accessibilityDescription:nil]];
    view.contentTintColor = NSColor.secondaryLabelColor;
    view.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular];
    return view;
}

@implementation SPDFAnnotateStatusBarView

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 600, kBarHeight)])) return nil;
    _controller = controller;
    self.material = NSVisualEffectMaterialHeaderView;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _pointer = Label(@"Pointer position");
    _selection = Label(@"Selection size");
    _size = Label(@"Canvas size");
    _fit = [NSButton buttonWithTitle:@"Fit" target:self action:@selector(fitPressed:)];
    _fit.bezelStyle = NSBezelStyleInline;
    _fit.controlSize = NSControlSizeSmall;
    _fit.toolTip = @"Fit to window";
    _zoom = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _zoom.controlSize = NSControlSizeSmall;
    _zoom.font = [NSFont systemFontOfSize:11];
    _zoom.bordered = NO;
    for (NSNumber* level in @[@0.125, @0.25, @0.5, @1, @2, @4, @8]) {
        [_zoom addItemWithTitle:[NSString stringWithFormat:@"%g%%", level.doubleValue * 100]];
        _zoom.lastItem.representedObject = level;
    }
    _zoom.target = self;
    _zoom.action = @selector(zoomChosen:);
    _zoom.toolTip = @"Zoom";
    _slider = [NSSlider sliderWithValue:0 minValue:log2(0.125) maxValue:log2(8) target:self
                                 action:@selector(sliderMoved:)];
    _slider.controlSize = NSControlSizeSmall;
    _slider.toolTip = @"Zoom";
    [_slider.widthAnchor constraintEqualToConstant:110].active = YES;
    _pointerGlyph = Glyph(@"cursorarrow");
    _selectionGlyph = Glyph(@"selection.pin.in.out");
    NSStackView* left = [NSStackView stackViewWithViews:@[_pointerGlyph, _pointer, _selectionGlyph, _selection,
                                                          Glyph(@"rectangle.dashed"), _size]];
    left.spacing = 5;
    [left setCustomSpacing:16 afterView:_pointer];
    [left setCustomSpacing:16 afterView:_selection];
    NSStackView* right = [NSStackView stackViewWithViews:@[_fit, _zoom, _slider]];
    right.spacing = 8;
    NSStackView* row = [NSStackView stackViewWithViews:@[left, [NSView new], right]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.distribution = NSStackViewDistributionFill;
    row.edgeInsets = NSEdgeInsetsMake(0, 10, 0, 10);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:self.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    NSBox* line = [[NSBox alloc] initWithFrame:NSMakeRect(0, kBarHeight - 1, 600, 1)];
    line.boxType = NSBoxSeparator;
    line.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:line];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:SPDFAnnotateCanvasPointerDidMoveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:SPDFAnnotateSessionDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (ShenzhenMacDelegate*)reader {
    id host = self.controller.host;
    return [host isKindOfClass:ShenzhenMacDelegate.class] ? host : nil;
}

- (void)fitPressed:(id)sender {
    (void)sender;
    [[self reader] annotateZoomTo:@"fit" atCanvasPoint:nil];
}

- (void)zoomChosen:(id)sender {
    (void)sender;
    [[self reader] annotateZoomTo:self.zoom.selectedItem.representedObject atCanvasPoint:nil];
}

- (void)sliderMoved:(id)sender {
    (void)sender;
    [[self reader] annotateZoomTo:@(exp2(self.slider.doubleValue)) atCanvasPoint:nil];
}

- (void)refresh {
    if (self.hidden || !self.session) return;
    SPDFMacAnnotateCanvasView* view = self.controller.annotateCanvasView;
    BOOL pdf = self.session.kind == SPDFAnnotateDocumentPDF;
    NSString* unit = pdf ? @"pt" : @"px";
    self.pointer.stringValue = view.hasPointer
        ? [NSString stringWithFormat:@"%.0f, %.0f %@", floor(view.pointerPoint.x), floor(view.pointerPoint.y), unit]
        : @"";
    NSSize selected = [view selectionSize];
    self.selection.stringValue = selected.width > 0
        ? [NSString stringWithFormat:@"%.0f × %.0f %@", selected.width, selected.height, unit] : @"";
    // A field with nothing to say is not shown, nor its picture.
    self.pointerGlyph.hidden = self.pointer.hidden = !self.pointer.stringValue.length;
    self.selectionGlyph.hidden = self.selection.hidden = !self.selection.stringValue.length;
    NSInteger page = pdf ? MAX(0, view.hasPointer && view.pointerPage >= 0 ? view.pointerPage : self.session.currentPage)
                         : -1;
    spdf_paint_doc* doc = [self.session canvasForPage:page document:NULL create:NO];
    int width = 0, height = 0;
    spdf_paint_size(doc, &width, &height);
    NSSize live = view.liveResizeSize;
    if (live.width > 0) width = (int)live.width, height = (int)live.height;
    self.size.stringValue = !doc ? @""
        : pdf ? [NSString stringWithFormat:@"Page %ld · %d × %d pt", (long)page + 1, width, height]
              : [NSString stringWithFormat:@"%d × %d px", width, height];
    CGFloat level = [view zoomLevel];
    NSString* title = [NSString stringWithFormat:@"%.0f%%", level * 100];
    NSInteger match = -1;
    for (NSMenuItem* item in self.zoom.itemArray)
        if (fabs([item.representedObject doubleValue] - level) < 0.005) match = [self.zoom indexOfItem:item];
    if (match >= 0) {
        [self.zoom selectItemAtIndex:match];
    } else {
        [self.zoom selectItem:nil];
        [self.zoom setTitle:title];
    }
    self.slider.doubleValue = log2(MAX(0.125, MIN(8, level)));
}

@end

void SPDFAnnotateUpdateStatusBar(SPDFMacFillController* controller, SPDFMacAnnotateSession* session) {
    SPDFAnnotateStatusBarView* bar = objc_getAssociatedObject(controller, &kSPDFAnnotateStatusBarKey);
    BOOL show = session && SPDFAnnotateSettings.shared.showsStatusBar;
    if (!show) {
        bar.hidden = YES;
        bar.session = nil;
        return;
    }
    NSScrollView* scrollView = [controller.host fillScrollView];
    NSView* container = scrollView.superview;
    if (!container) return;
    if (!bar) {
        bar = [[SPDFAnnotateStatusBarView alloc] initWithController:controller];
        objc_setAssociatedObject(controller, &kSPDFAnnotateStatusBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (bar.superview != container) {
        [bar removeFromSuperview];
        [container addSubview:bar positioned:NSWindowAbove relativeTo:nil];
    }
    // Over the bottom of the page area, the scroll view's width: the pages scroll under it.
    NSRect frame = scrollView.frame;
    bar.frame = NSMakeRect(NSMinX(frame), container.isFlipped ? NSMaxY(frame) - kBarHeight : NSMinY(frame),
                           NSWidth(frame), kBarHeight);
    bar.autoresizingMask = NSViewWidthSizable | (container.isFlipped ? NSViewMinYMargin : NSViewMaxYMargin);
    bar.session = session;
    bar.hidden = NO;
    [bar refresh];
}
