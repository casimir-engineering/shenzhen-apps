#import "SPDFMacTabStripGeometry.h"

#include <math.h>

NSInteger spdf_tab_strip_drop_slot_for_x(CGFloat x, const CGFloat* visibleTabMidXs, NSInteger visibleCount) {
    if (visibleCount <= 0 || !visibleTabMidXs) return 0;
    for (NSInteger slot = 0; slot < visibleCount; ++slot) {
        if (x < visibleTabMidXs[slot]) return slot;
    }
    return visibleCount;
}

CGFloat spdf_tab_strip_drop_indicator_center_x(NSInteger slot,
                                               const CGFloat* visibleTabMinXs,
                                               const CGFloat* visibleTabMaxXs,
                                               NSInteger visibleCount,
                                               CGFloat tabGap) {
    if (visibleCount <= 0 || slot < 0 || slot > visibleCount || !visibleTabMinXs || !visibleTabMaxXs) return NAN;
    if (slot == 0) return visibleTabMinXs[0] - tabGap / 2.0;
    if (slot == visibleCount) return visibleTabMaxXs[visibleCount - 1] + tabGap / 2.0;
    return (visibleTabMaxXs[slot - 1] + visibleTabMinXs[slot]) / 2.0;
}

NSInteger spdf_tab_strip_same_window_move_index(NSInteger insertionIndex, NSInteger sourceIndex, NSInteger tabCount) {
    if (tabCount <= 0 || sourceIndex < 0 || sourceIndex >= tabCount) return sourceIndex;
    NSInteger clamped = MAX((NSInteger)0, MIN(insertionIndex, tabCount));
    NSInteger target = clamped > sourceIndex ? clamped - 1 : clamped;
    return MAX((NSInteger)0, MIN(target, tabCount - 1));
}

NSRect spdf_tab_strip_control_interaction_rect(NSRect rect) {
    return NSIsEmptyRect(rect) ? NSZeroRect : NSInsetRect(rect, -3.0, -4.0);
}
