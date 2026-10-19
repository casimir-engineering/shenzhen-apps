#import <Cocoa/Cocoa.h>

#import "SPDFMacUIHelpers.h"

// The Markdown paged view's clip view: the shared page-aware lock behaviour of
// SPDFDocumentClipView, plus scroll origins snapped to DEVICE pixels.
//
// The Markdown canvas is live CoreText at the scroll view's magnification, not
// a bitmap like a PDF page. Its clip bounds are in unmagnified document units,
// so one wheel tick or one pan step lands the origin on a fractional device
// pixel (at 115% one point of travel is 1.74 pixels), and every frame then
// rasterizes each glyph at a different sub-pixel phase -- the text "wobbles"
// while the page moves. Snapping the origin to whole device pixels keeps the
// rasterization identical from frame to frame; the page still moves by the
// distance the hand did, to within half a pixel.
@interface SPDFMacMarkdownClipView : SPDFDocumentClipView
@end

// Pure: `origin` in document units snapped to the device-pixel grid at
// `magnification` document units per point and `backingScale` pixels per point.
// Unit-tested; the clip view calls it with its own scroll view's values.
NSPoint spdf_mac_markdown_snap_origin(NSPoint origin, CGFloat magnification, CGFloat backingScale);
