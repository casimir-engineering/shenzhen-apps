#pragma once
#import <Cocoa/Cocoa.h>

// Fit the natural symbol proportions inside its existing visual slot. Hit
// targets and layout stay independent of the painted glyph's aspect ratio.
static inline NSRect SPDFIconAspectFitRect(NSImage* image, NSRect slot) {
    NSSize size = image.size;
    if (size.width <= 0 || size.height <= 0 || NSIsEmptyRect(slot)) return NSZeroRect;
    CGFloat scale = MIN(NSWidth(slot)/size.width, NSHeight(slot)/size.height);
    NSSize fitted = NSMakeSize(size.width*scale,size.height*scale);
    return NSMakeRect(NSMidX(slot)-fitted.width/2,NSMidY(slot)-fitted.height/2,
                      fitted.width,fitted.height);
}

// Symbols and drawing-handler images remain vector sources. Never reuse an
// NSImage raster cache at another control size or backing scale.
static inline NSImage* SPDFUncachedVectorIcon(NSImage* image) {
    NSImage* vector = [image copy];
    vector.cacheMode = NSImageCacheNever;
    return vector;
}

static inline void SPDFDrawVectorIcon(NSImage* image, NSRect slot, BOOL flipped) {
    NSImage* vector = SPDFUncachedVectorIcon(image);
    [vector drawInRect:SPDFIconAspectFitRect(vector,slot) fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:flipped hints:nil];
}

static inline void SPDFConfigureIconViewRendering(NSView* view) {
    view.layerContentsRedrawPolicy=NSViewLayerContentsRedrawDuringViewResize;
    view.layerContentsPlacement=NSViewLayerContentsPlacementCenter;
}

// NSButton's updateLayer default redraws only after setNeedsDisplay. Auto Layout
// can resize its cached cell image first, stretching the glyph until hover marks
// it dirty. Redraw at the final control size instead of resampling that bitmap.
static inline void SPDFConfigureIconButtonRendering(NSButton* button) {
    SPDFConfigureIconViewRendering(button);
    button.imageScaling=NSImageScaleProportionallyDown;
}
