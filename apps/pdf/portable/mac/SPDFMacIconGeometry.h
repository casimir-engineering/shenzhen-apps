#pragma once
#import <Cocoa/Cocoa.h>

// One way to make and draw every chrome icon.
//
// Size comes from the symbol's point size, never from the rectangle it is drawn in: icons drawn at their natural size
// share one stroke weight and one optical size, wide symbols stay wide and tall ones tall. A slot is only the space an
// icon may use; the icon is centred in it and shrunk, proportionally, only when it cannot fit.

// Point size of every icon in a toolbar row (title bar, side panel header, tab bar). One value keeps the magnifying
// glass, the outline list and the chat bubbles at the same optical size and weight.
static const CGFloat SPDFToolbarSymbolPointSize = 13;

// A symbol with one configuration: point size, weight, medium scale and a single colour. Each call to
// -imageWithSymbolConfiguration: replaces the previous configuration, so applying a size and then a colour separately
// silently drops the size; everything goes in at once here. A non-symbol image (a drawing handler) comes back as is.
static inline NSImage* SPDFChromeSymbolImage(NSImage* source, CGFloat pointSize, NSFontWeight weight, NSColor* color) {
    if (!source) return nil;
    NSImageSymbolConfiguration* configuration = [NSImageSymbolConfiguration configurationWithPointSize:pointSize
        weight:weight scale:NSImageSymbolScaleMedium];
    if (color) configuration = [configuration configurationByApplyingConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
    return [source imageWithSymbolConfiguration:configuration] ?: source;
}

static inline NSImage* SPDFChromeSymbol(NSString* name, CGFloat pointSize, NSFontWeight weight, NSColor* color) {
    return SPDFChromeSymbolImage([NSImage imageWithSystemSymbolName:name accessibilityDescription:nil],
                                 pointSize, weight, color);
}

// The rectangle an icon is drawn in: its natural size (scaled down by one factor for both axes only when the slot is
// too small, never up), centred in the slot.
static inline NSRect SPDFIconAspectFitRect(NSImage* image, NSRect slot) {
    NSSize size = image.size;
    if (size.width <= 0 || size.height <= 0 || NSIsEmptyRect(slot)) return NSZeroRect;
    CGFloat scale = MIN(1, MIN(NSWidth(slot)/size.width, NSHeight(slot)/size.height));
    NSSize fitted = NSMakeSize(size.width*scale,size.height*scale);
    return NSMakeRect(NSMidX(slot)-fitted.width/2,NSMidY(slot)-fitted.height/2,
                      fitted.width,fitted.height);
}

// Moves a rectangle so its origin sits on a device pixel of the current context, at 1x and 2x alike, keeping its
// size. A glyph between pixels is drawn blurred.
static inline NSRect SPDFPixelAlignedIconRect(NSRect rect) {
    NSGraphicsContext* context = NSGraphicsContext.currentContext;
    if (!context || NSIsEmptyRect(rect)) return rect;
    CGContextRef cg = context.CGContext;
    CGRect device = CGContextConvertRectToDeviceSpace(cg, NSRectToCGRect(rect));
    CGPoint snapped = CGPointMake(round(device.origin.x), round(device.origin.y));
    CGRect back = CGContextConvertRectToUserSpace(cg, CGRectMake(snapped.x, snapped.y, device.size.width,
                                                                 device.size.height));
    return NSMakeRect(back.origin.x, back.origin.y, NSWidth(rect), NSHeight(rect));
}

// Symbols and drawing-handler images remain vector sources. Never reuse an
// NSImage raster cache at another control size or backing scale.
static inline NSImage* SPDFUncachedVectorIcon(NSImage* image) {
    NSImage* vector = [image copy];
    vector.cacheMode = NSImageCacheNever;
    return vector;
}

// Returns the rectangle drawn, for callers that tint or outline it.
static inline NSRect SPDFDrawVectorIconWithFraction(NSImage* image, NSRect slot, BOOL flipped, CGFloat fraction) {
    NSImage* vector = SPDFUncachedVectorIcon(image);
    NSRect rect = SPDFPixelAlignedIconRect(SPDFIconAspectFitRect(vector,slot));
    [vector drawInRect:rect fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:fraction respectFlipped:flipped hints:nil];
    return rect;
}

static inline NSRect SPDFDrawVectorIcon(NSImage* image, NSRect slot, BOOL flipped) {
    return SPDFDrawVectorIconWithFraction(image, slot, flipped, 1);
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
