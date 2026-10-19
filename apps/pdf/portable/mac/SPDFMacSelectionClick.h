#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, SPDFMacSelectionGranularity) {
    SPDFMacSelectionGranularityRange = 0,
    SPDFMacSelectionGranularityWord = 1,
    SPDFMacSelectionGranularityBlock = 2,
};

// AppKit reports the accumulated click count on each mouse-down. A plain click
// starts the existing range gesture; double/triple clicks are atomic selections
// and must never enter that drag path.
SPDFMacSelectionGranularity spdf_mac_selection_granularity_for_event(NSEvent* event);
BOOL spdf_mac_selection_uses_range_path(SPDFMacSelectionGranularity granularity);

// An in-document link is followed on the FIRST mouse-up, with no wait, because
// the jump is reversible. The second and third clicks of a multi-click gesture
// are word/block selections that belong to where the user actually clicked, so
// they undo that jump before selecting. Only a click that continues the same
// multi-click run (AppKit reports clickCount >= 2) undoes anything; a fresh
// press starts a new run and simply drops the stale snapshot.
BOOL spdf_mac_link_undo_applies_to_click(NSInteger clickCount, BOOL undoAvailable);
