#import "SPDFMacPrintView.h"

#import <PDFKit/PDFKit.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

static const CGFloat kSPDFDefaultPrintDPI = 1200.0;
static const CGFloat kSPDFMinimumPrintRenderZoom = 1.0;
static const CGFloat kSPDFMinimumCustomPrintScale = 0.10;
static const CGFloat kSPDFMaximumCustomPrintScale = 8.00;

NSString* SPDFPrintScalingModeTitle(SPDFPrintScalingMode mode) {
    switch (mode) {
        case SPDFPrintScalingModeActualSize:
            return @"Actual Size (100%)";
        case SPDFPrintScalingModeCustom:
            return @"Custom Scale";
        case SPDFPrintScalingModeFit:
        default:
            return @"Fit to Printable Area";
    }
}

CGFloat SPDFClampPrintCustomScale(CGFloat scale) {
    if (!isfinite(scale) || scale <= 0) return 1.0;
    return MAX(kSPDFMinimumCustomPrintScale, MIN(kSPDFMaximumCustomPrintScale, scale));
}

static CGFloat spdf_print_scale_for_mode(NSSize pageSize, NSRect imageable, SPDFPrintScalingMode mode,
                                         CGFloat customScale) {
    if (pageSize.width <= 0 || pageSize.height <= 0 || NSWidth(imageable) <= 0 || NSHeight(imageable) <= 0) return 1.0;
    if (mode == SPDFPrintScalingModeActualSize) return 1.0;
    if (mode == SPDFPrintScalingModeCustom) return SPDFClampPrintCustomScale(customScale);
    return MIN(NSWidth(imageable) / pageSize.width, NSHeight(imageable) / pageSize.height);
}

static NSRect spdf_print_destination_rect(NSSize pageSize, NSRect imageable, SPDFPrintScalingMode mode,
                                          CGFloat customScale) {
    CGFloat scale = spdf_print_scale_for_mode(pageSize, imageable, mode, customScale);
    NSSize drawSize = NSMakeSize(MAX(1.0, pageSize.width * scale), MAX(1.0, pageSize.height * scale));
    return NSMakeRect(NSMinX(imageable) + (NSWidth(imageable) - drawSize.width) / 2.0,
                      NSMinY(imageable) + (NSHeight(imageable) - drawSize.height) / 2.0, drawSize.width,
                      drawSize.height);
}

@interface SPDFPrintScalingAccessoryController () <NSTextFieldDelegate>
@end

@implementation SPDFPrintScalingAccessoryController {
    NSPopUpButton* _modePopup;
    NSTextField* _customScaleField;
    BOOL _syncingControls;
}

- (instancetype)initWithScalingMode:(SPDFPrintScalingMode)mode customScale:(CGFloat)customScale {
    self = [super init];
    if (!self) return nil;
    _scalingMode = mode;
    _customScale = SPDFClampPrintCustomScale(customScale);

    NSView* contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 86)];
    self.view = contentView;

    NSTextField* modeLabel = [NSTextField labelWithString:@"Scaling"];
    modeLabel.frame = NSMakeRect(0, 54, 80, 24);
    [contentView addSubview:modeLabel];

    _modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(88, 50, 206, 30) pullsDown:NO];
    [_modePopup addItemWithTitle:SPDFPrintScalingModeTitle(SPDFPrintScalingModeFit)];
    [_modePopup addItemWithTitle:SPDFPrintScalingModeTitle(SPDFPrintScalingModeActualSize)];
    [_modePopup addItemWithTitle:SPDFPrintScalingModeTitle(SPDFPrintScalingModeCustom)];
    _modePopup.target = self;
    _modePopup.action = @selector(modeChanged:);
    [contentView addSubview:_modePopup];

    NSTextField* percentLabel = [NSTextField labelWithString:@"Custom"];
    percentLabel.frame = NSMakeRect(0, 16, 80, 24);
    [contentView addSubview:percentLabel];

    _customScaleField = [[NSTextField alloc] initWithFrame:NSMakeRect(88, 14, 72, 26)];
    _customScaleField.alignment = NSTextAlignmentRight;
    _customScaleField.delegate = self;
    _customScaleField.target = self;
    _customScaleField.action = @selector(customScaleChanged:);
    [contentView addSubview:_customScaleField];

    NSTextField* suffix = [NSTextField labelWithString:@"%"];
    suffix.frame = NSMakeRect(168, 16, 30, 24);
    [contentView addSubview:suffix];

    [self syncControls];
    return self;
}

- (NSString*)title {
    return @"Scaling";
}

- (void)modeChanged:(id)sender {
    (void)sender;
    NSInteger index = _modePopup.indexOfSelectedItem;
    if (index == 1)
        self.scalingMode = SPDFPrintScalingModeActualSize;
    else if (index == 2)
        self.scalingMode = SPDFPrintScalingModeCustom;
    else
        self.scalingMode = SPDFPrintScalingModeFit;
}

- (void)customScaleChanged:(id)sender {
    (void)sender;
    self.customScale = SPDFClampPrintCustomScale(_customScaleField.doubleValue / 100.0);
}

- (void)syncControls {
    _syncingControls = YES;
    [_modePopup selectItemAtIndex:_scalingMode == SPDFPrintScalingModeActualSize
                                      ? 1
                                      : (_scalingMode == SPDFPrintScalingModeCustom ? 2 : 0)];
    _customScaleField.enabled = _scalingMode == SPDFPrintScalingModeCustom;
    _customScaleField.doubleValue = round(SPDFClampPrintCustomScale(_customScale) * 100.0);
    _syncingControls = NO;
}

- (void)notifySettingsChanged {
    if (_syncingControls) return;
    if (self.changeHandler) self.changeHandler(_scalingMode, _customScale);
}

- (void)setScalingMode:(SPDFPrintScalingMode)scalingMode {
    scalingMode = (SPDFPrintScalingMode)MAX(0, MIN(2, scalingMode));
    if (_scalingMode == scalingMode) return;
    [self willChangeValueForKey:@"localizedSummaryItems"];
    _scalingMode = scalingMode;
    [self didChangeValueForKey:@"localizedSummaryItems"];
    [self syncControls];
    [self notifySettingsChanged];
}

- (void)setCustomScale:(CGFloat)customScale {
    customScale = SPDFClampPrintCustomScale(customScale);
    if (fabs(_customScale - customScale) < 0.0001) return;
    [self willChangeValueForKey:@"localizedSummaryItems"];
    _customScale = customScale;
    [self didChangeValueForKey:@"localizedSummaryItems"];
    [self syncControls];
    [self notifySettingsChanged];
}

- (void)controlTextDidEndEditing:(NSNotification*)notification {
    if (notification.object == _customScaleField) [self customScaleChanged:_customScaleField];
}

- (NSSet<NSString*>*)keyPathsForValuesAffectingPreview {
    return [NSSet setWithObjects:@"scalingMode", @"customScale", @"representedObject.paperSize",
                                 @"representedObject.orientation", nil];
}

- (NSArray<NSDictionary<NSPrintPanelAccessorySummaryKey, NSString*>*>*)localizedSummaryItems {
    NSString* description = SPDFPrintScalingModeTitle(_scalingMode);
    if (_scalingMode == SPDFPrintScalingModeCustom)
        description =
            [NSString stringWithFormat:@"Custom %.0f%%", round(SPDFClampPrintCustomScale(_customScale) * 100.0)];
    return @[ @{
        NSPrintPanelAccessorySummaryItemNameKey : @"Scaling",
        NSPrintPanelAccessorySummaryItemDescriptionKey : description
    } ];
}

@end

static NSImage* spdf_print_image_from_bitmap(spdf_bitmap* bitmap, CGFloat imageScale, char* err, size_t errLen) {
    if (!bitmap || !bitmap->rgba || bitmap->width <= 0 || bitmap->height <= 0 || bitmap->stride <= 0) {
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Rendered page bitmap is empty.");
        return nil;
    }

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:bitmap->width
                                                                    pixelsHigh:bitmap->height
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:bitmap->stride
                                                                  bitsPerPixel:32];
    if (!rep || !rep.bitmapData) {
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Could not allocate print bitmap.");
        return nil;
    }

    memcpy(rep.bitmapData, bitmap->rgba, (size_t)bitmap->stride * (size_t)bitmap->height);
    imageScale = imageScale > 0 ? imageScale : 1.0;
    NSSize pointSize = NSMakeSize((CGFloat)bitmap->width / imageScale, (CGFloat)bitmap->height / imageScale);
    rep.size = pointSize;

    NSImage* image = [[NSImage alloc] initWithSize:pointSize];
    if (!image) {
        if (err && errLen > 0) snprintf(err, errLen, "%s", "Could not allocate print image.");
        return nil;
    }
    [image addRepresentation:rep];
    return image;
}

@implementation SPDFPDFKitPrintView

- (BOOL)isFlipped {
    return YES;
}

- (void)syncFrameToCurrentPaperSize {
    NSPrintInfo* info = NSPrintOperation.currentOperation.printInfo;
    NSSize paper = info.paperSize;
    if (paper.width <= 0 || paper.height <= 0) return;
    NSInteger pageCount = MAX(1, (NSInteger)self.pdfDocument.pageCount);
    NSSize size = NSMakeSize(paper.width, paper.height * pageCount);
    if (fabs(NSWidth(self.frame) - size.width) > 0.5 || fabs(NSHeight(self.frame) - size.height) > 0.5)
        [self setFrameSize:size];
}

- (BOOL)knowsPageRange:(NSRangePointer)range {
    [self syncFrameToCurrentPaperSize];
    range->location = 1;
    range->length = MAX(0, (NSInteger)self.pdfDocument.pageCount);
    return YES;
}

- (NSRect)rectForPage:(NSInteger)page {
    [self syncFrameToCurrentPaperSize];
    NSPrintInfo* info = NSPrintOperation.currentOperation.printInfo;
    NSSize paper = info.paperSize;
    if (paper.width <= 0 || paper.height <= 0) paper = self.bounds.size;
    return NSMakeRect(0, (page - 1) * paper.height, paper.width, paper.height);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSPrintInfo* info = NSPrintOperation.currentOperation.printInfo;
    NSSize paper = info.paperSize;
    if (paper.width <= 0 || paper.height <= 0) return;
    NSInteger pageNumber = MAX(1, (NSInteger)floor(dirtyRect.origin.y / paper.height) + 1);
    NSInteger pageIndex = pageNumber - 1;
    if (!self.pdfDocument || pageIndex < 0 || pageIndex >= (NSInteger)self.pdfDocument.pageCount) return;

    NSRect pageRect = [self rectForPage:pageNumber];
    [[NSColor whiteColor] setFill];
    NSRectFill(pageRect);

    PDFPage* page = [self.pdfDocument pageAtIndex:(NSUInteger)pageIndex];
    if (!page) return;
    PDFDisplayBox box = kPDFDisplayBoxCropBox;
    NSRect pdfBounds = [page boundsForBox:box];
    if (NSWidth(pdfBounds) <= 0 || NSHeight(pdfBounds) <= 0) {
        box = kPDFDisplayBoxMediaBox;
        pdfBounds = [page boundsForBox:box];
    }
    if (NSWidth(pdfBounds) <= 0 || NSHeight(pdfBounds) <= 0) return;

    NSRect imageable = info.imageablePageBounds;
    imageable.origin.x += pageRect.origin.x;
    imageable.origin.y += pageRect.origin.y;
    NSRect drawRect = spdf_print_destination_rect(pdfBounds.size, imageable, self.scalingMode, self.customScale);

    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(imageable));
    CGContextTranslateCTM(context, NSMinX(drawRect), NSMaxY(drawRect));
    CGContextScaleCTM(context, NSWidth(drawRect) / NSWidth(pdfBounds), -NSHeight(drawRect) / NSHeight(pdfBounds));
    CGContextTranslateCTM(context, -NSMinX(pdfBounds), -NSMinY(pdfBounds));
    [page drawWithBox:box toContext:context];
    CGContextRestoreGState(context);
}

@end

@implementation SPDFPrintView

- (BOOL)isFlipped {
    return YES;
}

- (NSInteger)effectivePageCount {
    if (self.pageCount > 0) return self.pageCount;
    return (NSInteger)self.fallbackPages.count;
}

- (void)syncFrameToCurrentPaperSize {
    NSPrintInfo* info = NSPrintOperation.currentOperation.printInfo;
    NSSize paper = info.paperSize;
    if (paper.width <= 0 || paper.height <= 0) return;
    NSInteger pageCount = MAX(1, [self effectivePageCount]);
    NSSize size = NSMakeSize(paper.width, paper.height * pageCount);
    if (fabs(NSWidth(self.frame) - size.width) > 0.5 || fabs(NSHeight(self.frame) - size.height) > 0.5)
        [self setFrameSize:size];
}

- (BOOL)knowsPageRange:(NSRangePointer)range {
    [self syncFrameToCurrentPaperSize];
    range->location = 1;
    range->length = [self effectivePageCount];
    return YES;
}

- (NSRect)rectForPage:(NSInteger)page {
    [self syncFrameToCurrentPaperSize];
    NSPrintInfo* info = NSPrintOperation.currentOperation.printInfo;
    NSSize paper = info.paperSize;
    if (paper.width <= 0 || paper.height <= 0) paper = self.bounds.size;
    return NSMakeRect(0, (page - 1) * paper.height, paper.width, paper.height);
}

- (NSImage*)highResolutionImageForPageIndex:(NSInteger)pageIndex {
    if (!self.document || pageIndex < 0 || pageIndex >= [self effectivePageCount]) return nil;

    // Deliberately spdf_render_page_rgba, i.e. SPDF_RENDER_DEFAULT: print always
    // gets the document's OWN colors, never the dark reading theme. A PDF's
    // colors are its content, printing our dark paper would waste an enormous
    // amount of toner, and every reader with both features (Okular, zathura,
    // Evince, Skim) treats the color transform as view-only for the same reason.
    CGFloat targetDPI = self.targetDPI > 0 ? self.targetDPI : kSPDFDefaultPrintDPI;
    CGFloat renderZoom = MAX(kSPDFMinimumPrintRenderZoom, targetDPI / 72.0);
    char err[1024];
    while (renderZoom >= kSPDFMinimumPrintRenderZoom) {
        spdf_bitmap bitmap;
        if (spdf_render_page_rgba(self.document, (int)pageIndex, (float)renderZoom, &bitmap, err, sizeof(err))) {
            NSImage* image = spdf_print_image_from_bitmap(&bitmap, renderZoom, err, sizeof(err));
            spdf_free_bitmap(&bitmap);
            if (image) return image;
        }
        renderZoom *= 0.5;
    }
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSPrintInfo* info = NSPrintOperation.currentOperation.printInfo;
    NSSize paper = info.paperSize;
    if (paper.width <= 0 || paper.height <= 0) return;
    NSInteger pageNumber = MAX(1, (NSInteger)floor(dirtyRect.origin.y / paper.height) + 1);
    NSInteger pageIndex = pageNumber - 1;
    if (pageIndex < 0 || pageIndex >= [self effectivePageCount]) return;

    NSRect pageRect = [self rectForPage:pageNumber];
    [[NSColor whiteColor] setFill];
    NSRectFill(pageRect);

    NSImage* image = [self highResolutionImageForPageIndex:pageIndex];
    if (!image && pageIndex < (NSInteger)self.fallbackPages.count) {
        // The fallback is the on-screen cache, which under the dark reading
        // theme holds recolored pixels. Leave the page blank rather than print
        // them: a rescued page is worth less than never baking our colors in.
        SPDFRenderedPage* cached = self.fallbackPages[(NSUInteger)pageIndex];
        if (!cached.imageDarkTheme) image = cached.image;
    }
    if (!image) return;

    NSRect imageable = info.imageablePageBounds;
    imageable.origin.x += pageRect.origin.x;
    imageable.origin.y += pageRect.origin.y;
    NSRect drawRect = spdf_print_destination_rect(image.size, imageable, self.scalingMode, self.customScale);
    [image drawInRect:drawRect
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:YES
                 hints:@{NSImageHintInterpolation : @(NSImageInterpolationHigh)}];
}

@end
