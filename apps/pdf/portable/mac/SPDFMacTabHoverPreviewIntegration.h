#pragma once

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacTabHoverPreview.h"

@class SPDFTabPreviewCache;

// The reader's side of the tab hover thumbnails (SPDFMacTabHoverPreview.h).
@interface ShenzhenMacDelegate (TabHoverPreview) <SPDFTabHoverPreviewSource>
// A page settled, a jump landed or a tab was opened or switched to: the
// thumbnails are remade 0.4 s later, off the main thread. Before the first
// hover (or 5 s after the first call) this only schedules that point.
- (void)spdf_noteTabHoverPreviewSourcesChanged;
// The thumbnails held now; nil until the first hover or the idle start.
- (SPDFTabPreviewCache*)spdf_tabPreviewCache;
@end
