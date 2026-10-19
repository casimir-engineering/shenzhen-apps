#import <Cocoa/Cocoa.h>

@class SPDFRenderedPage;

CGFloat spdf_mac_effective_backing_scale(CGFloat configuredScale, NSWindow* window);
CGFloat spdf_mac_pixel_snapped_length(CGFloat length, CGFloat backingScale);
CGFloat spdf_mac_pixel_snapped_origin(CGFloat origin, CGFloat backingScale);
NSSize spdf_mac_view_size_for_page(SPDFRenderedPage* page, CGFloat zoom, CGFloat backingScale);

NSRect spdf_mac_page_rect_to_view_rect(NSRect rect, NSRect pageRect, SPDFRenderedPage* page);
NSPoint spdf_mac_view_point_to_page_point(NSPoint point, NSRect pageRect, SPDFRenderedPage* page);

// Every top-aligned scroll in the app leaves this much of the gutter above the
// page so the paper edge is visible rather than flush against the toolbar.
extern const CGFloat kSPDFPageTopScrollLeadIn;

// Document-view scroll origin Y that puts a link destination at the TOP of the
// viewport. `destinationPageY` is the destination's offset from the target
// page's TOP edge in page points (what spdf_link_at_point reports); pass 0 for
// a link that names only a page. `pageRect` is that page's laid-out rect in the
// flipped document view, so the result depends on the TARGET page's geometry
// alone - centering the destination instead used to leave half a viewport of
// the preceding page above it.
CGFloat spdf_mac_link_destination_scroll_origin_y(NSRect pageRect, CGFloat destinationPageY, CGFloat zoom);
BOOL spdf_mac_page_subrect_covers_full_page(NSRect pageSubrect, SPDFRenderedPage* page);
BOOL spdf_mac_should_draw_stale_full_page_image(SPDFRenderedPage* page, CGFloat zoom, CGFloat backingScale);

BOOL spdf_mac_draw_page_image(NSImage* image,
                              NSRect pageSubrect,
                              NSRect pageRect,
                              NSRect dirtyRect,
                              SPDFRenderedPage* page,
                              NSImageInterpolation interpolation);
