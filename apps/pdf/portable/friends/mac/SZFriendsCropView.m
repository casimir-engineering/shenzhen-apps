// SZFriendsCropView: place a photo under the circle before it becomes your picture.
//
// Only the crop square travels (set_picture crop, in source pixels); the helper decodes, crops and re-encodes the
// photo itself, so this view never produces image data (avatars/SZFriendsAvatars.h, picture pipeline).

#import "mac/SZFriendsDetailsPage.h"

#import <ImageIO/ImageIO.h>

static const CGFloat SZFCropSide = 200;

@implementation SZFriendsCropView {
    SZFriendsContext *_context;
    NSImage *_image;
    CGFloat _pixelWidth;
    CGFloat _pixelHeight;
    CGFloat _zoom;
    CGFloat _originX; // top-left of the visible square, in source pixels, y down
    CGFloat _originY;
    NSTextField *_title;
    NSSlider *_slider;
    NSPoint _dragStart;
    CGFloat _dragOriginX;
    CGFloat _dragOriginY;
}

- (instancetype)initWithContext:(SZFriendsContext *)context imagePath:(NSString *)path {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 360)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    self.fillColor = appearance.backgroundColor;
    // Pixel size from the file's metadata, so the crop square is in the units the helper decodes.
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (source) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        _pixelWidth = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        _pixelHeight = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        CFRelease(source);
    }
    if (_pixelWidth > 0 && _pixelHeight > 0) _image = [[NSImage alloc] initWithContentsOfFile:path];
    _zoom = 1;
    [self centre];
    _title = SZFriendsLabel([context string:@"crop_title"], SZFriendsSemibold(appearance.bodyFont),
                            appearance.primaryTextColor);
    _title.alignment = NSTextAlignmentCenter;
    [self addSubview:_title];
    _slider = [NSSlider sliderWithValue:1 minValue:1 maxValue:4 target:self action:@selector(zoomChanged:)];
    [self addSubview:_slider];
    __weak SZFriendsCropView *weakSelf = self;
    _cancelButton = [SZFriendsButton buttonWithTitle:[context string:@"cancel"] style:SZFriendsButtonStyleSecondary
                                          appearance:appearance];
    _cancelButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsCropView *view = weakSelf;
        if (view.onCancel) view.onCancel();
    };
    _useButton = [SZFriendsButton buttonWithTitle:[context string:@"crop_use"] style:SZFriendsButtonStylePrimary
                                       appearance:appearance];
    _useButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsCropView *view = weakSelf;
        if (view.onUse) view.onUse([view cropSquare]);
    };
    [self addSubview:_cancelButton];
    [self addSubview:_useButton];
    return self;
}

- (BOOL)hasImage {
    return _image != nil;
}

- (CGFloat)visibleSide {
    return MIN(_pixelWidth, _pixelHeight) / _zoom;
}

- (void)centre {
    CGFloat side = [self visibleSide];
    _originX = (_pixelWidth - side) / 2;
    _originY = (_pixelHeight - side) / 2;
}

- (void)clamp {
    CGFloat side = [self visibleSide];
    _originX = MAX(0, MIN(_pixelWidth - side, _originX));
    _originY = MAX(0, MIN(_pixelHeight - side, _originY));
}

- (NSDictionary<NSString *, NSNumber *> *)cropSquare {
    return @{@"x" : @((NSInteger)floor(_originX)), @"y" : @((NSInteger)floor(_originY)),
             @"side" : @((NSInteger)floor([self visibleSide]))};
}

- (void)zoomChanged:(NSSlider *)slider {
    CGFloat side = [self visibleSide];
    CGFloat centerX = _originX + side / 2, centerY = _originY + side / 2;
    _zoom = MAX(1, slider.doubleValue);
    side = [self visibleSide];
    _originX = centerX - side / 2;
    _originY = centerY - side / 2;
    [self clamp];
    self.needsDisplay = YES;
}

- (NSRect)viewport {
    return NSMakeRect(floor((NSWidth(self.bounds) - SZFCropSide) / 2), 44, SZFCropSide, SZFCropSide);
}

- (void)mouseDown:(NSEvent *)event {
    _dragStart = [self convertPoint:event.locationInWindow fromView:nil];
    _dragOriginX = _originX;
    _dragOriginY = _originY;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat pixelsPerPoint = [self visibleSide] / SZFCropSide;
    _originX = _dragOriginX - (point.x - _dragStart.x) * pixelsPerPoint;
    _originY = _dragOriginY - (point.y - _dragStart.y) * pixelsPerPoint;
    [self clamp];
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _title.frame = NSMakeRect(16, 14, width - 32, 18);
    NSRect viewport = [self viewport];
    _slider.frame = NSMakeRect(NSMinX(viewport), NSMaxY(viewport) + 12, SZFCropSide, 20);
    CGFloat buttonsY = NSMaxY(viewport) + 46;
    CGFloat useWidth = MAX(96, [_useButton fittingWidth]), cancelWidth = MAX(80, [_cancelButton fittingWidth]);
    _useButton.frame = NSMakeRect(NSMaxX(viewport) - useWidth, buttonsY, useWidth, 28);
    _cancelButton.frame = NSMakeRect(NSMinX(_useButton.frame) - 8 - cancelWidth, buttonsY, cancelWidth, 28);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect viewport = [self viewport];
    [_context.appearance.fieldBackgroundColor setFill];
    NSRectFill(viewport);
    if (_image) {
        CGFloat side = [self visibleSide];
        CGFloat pointsPerPixel = _image.size.width / _pixelWidth;
        // NSImage source rects are bottom-up in the image's points; the crop square is top-down in pixels.
        NSRect source = NSMakeRect(_originX * pointsPerPixel, (_pixelHeight - _originY - side) * pointsPerPixel,
                                   side * pointsPerPixel, side * pointsPerPixel);
        [_image drawInRect:viewport fromRect:source operation:NSCompositingOperationSourceOver fraction:1
            respectFlipped:YES hints:nil];
    }
    NSBezierPath *dim = [NSBezierPath bezierPathWithRect:viewport];
    [dim appendBezierPathWithOvalInRect:viewport];
    dim.windingRule = NSWindingRuleEvenOdd;
    [[NSColor colorWithWhite:0 alpha:0.45] setFill];
    [dim fill];
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(viewport, 0.5, 0.5)];
    [[NSColor colorWithWhite:1 alpha:0.85] setStroke];
    [ring stroke];
}

@end
