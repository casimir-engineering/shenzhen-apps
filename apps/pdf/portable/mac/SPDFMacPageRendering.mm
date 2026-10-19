#import "SPDFMacPageRendering.h"

#import "SPDFMacModels.h"
#import "SPDFMacSupport.h"

#include <math.h>

static const NSUInteger kLiveZoomStaleFullPageDrawByteLimit = (NSUInteger)24 * 1024 * 1024;

CGFloat spdf_mac_effective_backing_scale(CGFloat configuredScale, NSWindow* window) {
    CGFloat scale = configuredScale;
    if (scale <= 0) scale = window.backingScaleFactor;
    if (scale <= 0) scale = NSScreen.mainScreen.backingScaleFactor;
    return scale > 0 ? scale : 1.0;
}

CGFloat spdf_mac_pixel_snapped_length(CGFloat length, CGFloat backingScale) {
    return ceil(length * backingScale - 0.001) / backingScale;
}

CGFloat spdf_mac_pixel_snapped_origin(CGFloat origin, CGFloat backingScale) {
    return floor(origin * backingScale + 0.001) / backingScale;
}

NSSize spdf_mac_view_size_for_page(SPDFRenderedPage* page, CGFloat zoom, CGFloat backingScale) {
    if (page.image && page.imagePointWidth > 0 && page.imagePointHeight > 0 &&
        fabs(page.imageZoom - zoom) < 0.0001)
        return NSMakeSize(page.imagePointWidth, page.imagePointHeight);
    return NSMakeSize(spdf_mac_pixel_snapped_length(page.pageWidth * zoom, backingScale),
                      spdf_mac_pixel_snapped_length(page.pageHeight * zoom, backingScale));
}

NSRect spdf_mac_page_rect_to_view_rect(NSRect rect, NSRect pageRect, SPDFRenderedPage* page) {
    CGFloat scaleX = NSWidth(pageRect) / MAX(1.0, page.pageWidth);
    CGFloat scaleY = NSHeight(pageRect) / MAX(1.0, page.pageHeight);
    rect.origin.x = pageRect.origin.x + rect.origin.x * scaleX;
    rect.origin.y = pageRect.origin.y + rect.origin.y * scaleY;
    rect.size.width *= scaleX;
    rect.size.height *= scaleY;
    return rect;
}

const CGFloat kSPDFPageTopScrollLeadIn = 12.0;

CGFloat spdf_mac_link_destination_scroll_origin_y(NSRect pageRect, CGFloat destinationPageY, CGFloat zoom) {
    CGFloat scale = zoom > 0.0 ? zoom : 1.0;
    CGFloat offset = destinationPageY > 0.0 ? destinationPageY * scale : 0.0;
    // Clamped at the document top, and never above the target page's own top:
    // a destination with no offset must land exactly where "go to page N" lands.
    return MAX(0.0, NSMinY(pageRect) + offset - kSPDFPageTopScrollLeadIn);
}

NSPoint spdf_mac_view_point_to_page_point(NSPoint point, NSRect pageRect, SPDFRenderedPage* page) {
    CGFloat scaleX = NSWidth(pageRect) / MAX(1.0, page.pageWidth);
    CGFloat scaleY = NSHeight(pageRect) / MAX(1.0, page.pageHeight);
    return NSMakePoint((point.x - pageRect.origin.x) / MAX(0.001, scaleX),
                       (point.y - pageRect.origin.y) / MAX(0.001, scaleY));
}

BOOL spdf_mac_page_subrect_covers_full_page(NSRect pageSubrect, SPDFRenderedPage* page) {
    if (NSIsEmptyRect(pageSubrect) || page.pageWidth <= 0.0 || page.pageHeight <= 0.0) return NO;
    return fabs(NSMinX(pageSubrect)) <= 0.01 && fabs(NSMinY(pageSubrect)) <= 0.01 &&
           fabs(NSWidth(pageSubrect) - page.pageWidth) <= 0.01 &&
           fabs(NSHeight(pageSubrect) - page.pageHeight) <= 0.01;
}

static NSUInteger spdf_mac_estimated_full_page_image_byte_cost(SPDFRenderedPage* page, CGFloat backingScale) {
    if (!page.image || page.imagePointWidth <= 0.0 || page.imagePointHeight <= 0.0) return 0;
    CGFloat scale = page.imageScale > 0.0 ? page.imageScale : backingScale;
    double pixels = ceil(page.imagePointWidth * scale) * ceil(page.imagePointHeight * scale);
    if (!isfinite(pixels) || pixels <= 0.0) return 0;
    double bytes = pixels * 4.0;
    if (bytes > (double)NSUIntegerMax) return NSUIntegerMax;
    return (NSUInteger)bytes;
}

BOOL spdf_mac_should_draw_stale_full_page_image(SPDFRenderedPage* page, CGFloat zoom, CGFloat backingScale) {
    if (!page.image) return NO;
    if (fabs(page.imageZoom - zoom) <= 0.001) return YES;
    return spdf_mac_estimated_full_page_image_byte_cost(page, backingScale) <=
           kLiveZoomStaleFullPageDrawByteLimit;
}

BOOL spdf_mac_draw_page_image(NSImage* image,
                              NSRect pageSubrect,
                              NSRect pageRect,
                              NSRect dirtyRect,
                              SPDFRenderedPage* page,
                              NSImageInterpolation interpolation) {
    if (!image || NSIsEmptyRect(pageSubrect)) return NO;
    NSRect imageRect = spdf_mac_page_rect_to_view_rect(pageSubrect, pageRect, page);
    if (NSIsEmptyRect(imageRect)) return NO;
    NSRect drawRect = NSIntersectionRect(imageRect, dirtyRect);
    if (NSIsEmptyRect(drawRect)) return NO;

    NSGraphicsContext* context = NSGraphicsContext.currentContext;
    NSImageInterpolation oldInterpolation = context.imageInterpolation;
    context.imageInterpolation = interpolation;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(drawRect);
    double profileStart = spdf_zoom_profile_enabled() ? spdf_zoom_profile_now_ms() : 0.0;
    [image drawInRect:imageRect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:@{NSImageHintInterpolation : @(interpolation)}];
    if (spdf_zoom_profile_enabled()) {
        double elapsed = spdf_zoom_profile_now_ms() - profileStart;
        if (elapsed > 2.0)
            spdf_zoom_profile_log(@"drawPageImage page=%ld img=%p size=%.0fx%.0f imageRect=%.0fx%.0f draw=%.0fx%.0f %.2fms",
                                  (long)page.pageIndex, image, image.size.width, image.size.height,
                                  NSWidth(imageRect), NSHeight(imageRect), NSWidth(drawRect), NSHeight(drawRect),
                                  elapsed);
    }
    [NSGraphicsContext restoreGraphicsState];
    context.imageInterpolation = oldInterpolation;
    return YES;
}
