#pragma once
// What the Layers panel lists and what a dropped row asks for (SPDFMacAnnotateLayersPanel.h), from doc.state.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The rows, front first: each layer ({"id", "name", "visible", "opacity", "locked", "count" (its objects), "folded",
// "base", "page" (a PDF's page)}), then, unless its id is in `folded`, its objects front first ({"object": YES,
// "layer": its layer's id, ...}); the base layer last.
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFAnnotateLayerRows(NSDictionary* _Nullable state, NSSet<NSNumber*>* folded);
// The indexes of `from` whose rows aren't in `to`, when `to` is `from` with only those taken out (same rows, same
// order, by id); nil otherwise.
FOUNDATION_EXPORT NSIndexSet* _Nullable SPDFAnnotateRowsLeft(NSArray<NSDictionary*>* from, NSArray<NSDictionary*>* to);
// The operation a row dragged from `from` and dropped above `row` asks for: a layer goes among the layers
// (layer.order), an object into the layer whose row is above the drop point, at that place (object.layer); nil when
// the drop changes nothing or isn't allowed (the base layer, a locked layer).
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFAnnotateLayerDrop(NSArray<NSDictionary*>* rows, NSInteger from, NSInteger row);

NS_ASSUME_NONNULL_END
