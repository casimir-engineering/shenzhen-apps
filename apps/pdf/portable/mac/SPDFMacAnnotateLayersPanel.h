#pragma once
// The Layers sidebar (docs/plans/annotate.md § 1 Layers panel, § 3): on the right of the canvas, in the minimap's
// place while Annotate is on (the minimap comes back on Done), shown by the palette's Layers button or Shift-Cmd-L.
//
// Top of the list is front. Each row: thumbnail (spdf_paint_layer_thumbnail), name ("Background", "Page 3" on a PDF,
// "Drawing", "Layer 2", "Rectangle", "Text: Hello", "Picture", "Pen line", "Signature"), an eye (hide/show) and, while
// selected, an opacity slider. A PDF page's Background row shows a lock and has no eye, opacity or delete. The active
// raster layer carries a brush badge. Dragging rows reorders them (depth); selecting an object's row selects that
// object on the canvas. Buttons under the list: New Layer, Duplicate, Merge Down, Delete.
//
// Every change it makes is an operation (layer.add, layer.duplicate, layer.merge_down, layer.delete, layer.set,
// layer.order, layer.activate, object.order) sent through -[SPDFMacFillController applyOperation:tab:completion:]. It
// reads what it shows from doc.state's answer, never from the core directly.
#import <Cocoa/Cocoa.h>

@class SPDFMacFillController, SPDFMacAnnotateSession;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAnnotateLayersPanel : NSView

- (instancetype)initWithController:(SPDFMacFillController*)controller;

// Placed at the right of the page area, in the minimap's place, which the integration hides while it shows.
- (void)attachToContainer:(NSView*)container;
- (void)detach;
@property(nonatomic, readonly) CGFloat preferredWidth;

// Shows what the session's canvas holds: the picture's, or the PDF page the session follows (currentPage).
// Thumbnails are redrawn lazily, after the rows, and only for layers whose content changed.
- (void)reloadFromSession:(nullable SPDFMacAnnotateSession*)session;
// The selection on the canvas changed: highlight those rows.
- (void)selectionDidChange;

@end

NS_ASSUME_NONNULL_END
