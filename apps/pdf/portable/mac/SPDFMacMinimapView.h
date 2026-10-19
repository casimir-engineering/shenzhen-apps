#import <Cocoa/Cocoa.h>

#import "SPDFMacModels.h"
#import "SPDFMacUIHelpers.h"
#import "markdown/SPDFMarkdownDecorations.h"

@interface SPDFMinimapView : NSView
@property(nonatomic, copy) NSArray<SPDFRenderedPage*>* pages;
@property(nonatomic, copy) NSArray<NSValue*>* documentPageRects;
@property(nonatomic) NSRect documentVisibleRect;
@property(nonatomic) CGFloat documentWidth;
@property(nonatomic) CGFloat documentHeight;
@property(nonatomic) CGFloat documentScale;
@property(nonatomic) NSInteger currentPageIndex;
@property(nonatomic) BOOL liveViewportOnly;
// Reading-theme palette for the strip: the gutter behind the sheets, each
// sheet's paper, and (in dark, which draws no shadow) its 1px border. Part of
// the cached strip's key, so changing it rebuilds the baked-in paper/borders.
@property(nonatomic) SPDFMarkdownThemeVariant themeVariant;
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
- (NSArray<NSNumber*>*)visiblePageIndexes;
// Pages within the visible strip expanded by `screens` strip-heights on each
// side — used to prerender thumbnails above and below the viewport.
- (NSArray<NSNumber*>*)visiblePageIndexesWithPaddingScreens:(CGFloat)screens;
// Page-content zoom at which a thumbnail should be rendered so it is crisp at
// the page's displayed width in the strip (which is width-capped at 2.5x the
// median page). Returns 0 if the strip has no usable width yet.
- (CGFloat)thumbnailRenderZoomForPage:(SPDFRenderedPage*)page;
// Called when a page's minimap thumbnail finishes rendering: patches just that
// page into the cached strip (cheap) rather than forcing a full-strip rebuild.
- (void)noteThumbnailLoadedForPageIndex:(NSInteger)pageIndex;
// The same for a reader whose page objects are replaced as they render (PDF):
// `page` is the live object holding the thumbnail. It takes the slot of the
// object the `pages` snapshot holds when the geometry matches, so the strip
// draws the thumbnail without a full `pages` reassignment.
- (void)noteThumbnailLoadedForPage:(SPDFRenderedPage*)page;
@end
