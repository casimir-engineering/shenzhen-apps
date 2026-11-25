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
// layer.order, layer.activate, object.order, object.merge_down, object.delete) sent through
// -[SPDFMacFillController applyOperation:tab:completion:]. Clicking an object's row sends layer.activate with the
// object's id, which selects that object. It reads what it shows from doc.state's answer, never from the core
// directly (thumbnails aside):
//   {"layers": [{"id", "kind": "background" | "raster" | "object", "name", "visible", "opacity" (0-100), "locked",
//                "object": {"kind": ...}}, ... bottom to top], "active": id, "selection": {"objects": [ids]}}
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

// The controller's panel (made on first use), and showing it: the palette's Layers button, View > Layers
// (Shift-Cmd-L) and -[ShenzhenMacDelegate toggleAnnotateLayers:] all call SPDFAnnotateToggleLayersPanel. Shown or
// not is remembered (SPDFAnnotateSettings.showsLayers); SPDFAnnotateSyncLayersPanel puts it back when Annotate
// shows and takes it away on Done.
FOUNDATION_EXPORT SPDFMacAnnotateLayersPanel* _Nullable SPDFAnnotateLayersPanelFor(SPDFMacFillController* controller,
                                                                                   BOOL create);
FOUNDATION_EXPORT BOOL SPDFAnnotateLayersPanelShown(SPDFMacFillController* _Nullable controller);
FOUNDATION_EXPORT void SPDFAnnotateToggleLayersPanel(SPDFMacFillController* controller);
FOUNDATION_EXPORT void SPDFAnnotateSyncLayersPanel(SPDFMacFillController* controller);

NS_ASSUME_NONNULL_END
