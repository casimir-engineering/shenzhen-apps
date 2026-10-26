#pragma once

#import <Cocoa/Cocoa.h>

@class SPDFDocumentTab;

NS_ASSUME_NONNULL_BEGIN

// The page thumbnail a document tab shows under its full-title label on hover,
// like a browser's tab preview: the tab's current page as it was last seen,
// in its own orientation. The tab strip only sees these protocols; the cache
// and the renderers live with the reader (SPDFMacTabHoverPreviewIntegration.mm)
// so the strip and its tests link none of it.
@protocol SPDFTabHoverPreview <NSObject>
@property(nonatomic, readonly) CGImageRef image;
// Size to draw it at, in points; the image has backing-scale pixels.
@property(nonatomic, readonly) NSSize pointSize;
@property(nonatomic, readonly) NSInteger pageIndex;
@end

@protocol SPDFTabHoverPreviewSource <NSObject>
// On hover. Returns the thumbnail when it can be shown with the title in the
// same frame: prepared earlier, or made now from page pixels already in memory.
// Otherwise nil, and `ready` runs once on the main thread when one is made.
- (nullable id<SPDFTabHoverPreview>)tabHoverPreviewForTab:(SPDFDocumentTab*)tab
                                              backingScale:(CGFloat)scale
                                                     ready:(void (^)(id<SPDFTabHoverPreview> preview))ready;
// The pointer entered the tab bar: prepare every tab's thumbnail now.
- (void)tabHoverPreviewsWillBeNeeded;
@end

NS_ASSUME_NONNULL_END
