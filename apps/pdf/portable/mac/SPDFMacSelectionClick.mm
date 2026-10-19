#import "SPDFMacSelectionClick.h"

SPDFMacSelectionGranularity spdf_mac_selection_granularity_for_event(NSEvent* event) {
    NSInteger clickCount = event.clickCount;
    if (clickCount >= 3) return SPDFMacSelectionGranularityBlock;
    if (clickCount == 2) return SPDFMacSelectionGranularityWord;
    return SPDFMacSelectionGranularityRange;
}

BOOL spdf_mac_selection_uses_range_path(SPDFMacSelectionGranularity granularity) {
    return granularity == SPDFMacSelectionGranularityRange;
}

BOOL spdf_mac_link_undo_applies_to_click(NSInteger clickCount, BOOL undoAvailable) {
    return undoAvailable && clickCount >= 2;
}
