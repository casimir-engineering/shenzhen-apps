#pragma once
// What the Layers panel's files share: SPDFMacAnnotateLayersPanel.mm (rows, buttons) and +Thumbnails.mm.
#import "SPDFMacAnnotateLayersPanel.h"

#import "SPDFMacFillController+Annotate.h"

@class SPDFAnnotateLayerRow;

// Posted (object: the controller) by the canvas view each time a stroke being drawn shows new pixels.
FOUNDATION_EXPORT NSNotificationName const SPDFAnnotateLiveStrokeNotification;

@interface SPDFMacAnnotateLayersPanel () <NSTableViewDataSource, NSTableViewDelegate> {
    __weak SPDFMacFillController* _controller;
    __weak SPDFMacAnnotateSession* _session;
    NSTableView* _table;
    NSScrollView* _scroll;
    NSArray<NSDictionary*>* _rows;  // front first: layers, each followed by its objects unless folded
    NSMutableSet<NSNumber*>* _folded;  // layers whose objects are hidden from the list
    NSMutableDictionary<NSNumber*, NSImage*>* _thumbs;
    uint64_t _thumbGeneration;
    spdf_paint_doc* _thumbDoc;  // generations count per document: another tab's can be the same number
    NSNumber* _activeId;
    NSButton* _add;
    NSButton* _duplicate;
    NSButton* _merge;
    NSButton* _delete;
    NSLayoutConstraint* _height;
    NSLayoutConstraint* _top;
    BOOL _inSlot;  // in the minimap's place (the palette is not above it)
    BOOL _syncing;
    CFTimeInterval _liveThumbAt;  // when the live thumbnail was last drawn (+Thumbnails.mm)
    BOOL _liveThumbPending;
}
- (void)configure:(SPDFAnnotateLayerRow*)cell row:(NSInteger)row;
// +Thumbnails.mm
- (spdf_paint_doc*)canvas;
- (void)scheduleThumbnails;
- (void)liveStrokeChanged:(NSNotification*)note;
@end
