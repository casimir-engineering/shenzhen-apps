#import "SPDFMacCursorRegions.h"

#include <math.h>

const CGFloat kSPDFLinkClickDragThreshold = 3.0;

SPDFCursorRegionKind spdf_cursor_region_at_point(NSPoint pagePoint, NSArray<NSValue*>* linkRects,
                                                 NSArray<NSValue*>* textRects, CGFloat linkPadding) {
    for (NSValue* value in linkRects) {
        if (NSPointInRect(pagePoint, NSInsetRect(value.rectValue, -linkPadding, -linkPadding)))
            return SPDFCursorRegionLink;
    }
    for (NSValue* value in textRects) {
        if (NSPointInRect(pagePoint, value.rectValue)) return SPDFCursorRegionText;
    }
    return SPDFCursorRegionNone;
}

SPDFLinkClickGesture spdf_link_click_gesture_begin(NSPoint pressViewPoint) {
    SPDFLinkClickGesture gesture;
    gesture.pressPoint = pressViewPoint;
    gesture.active = YES;
    gesture.draggedBeyondThreshold = NO;
    gesture.selectionCreated = NO;
    return gesture;
}

void spdf_link_click_gesture_drag(SPDFLinkClickGesture* gesture, NSPoint viewPoint, BOOL selectionNonEmpty) {
    if (!gesture || !gesture->active) return;
    CGFloat dx = viewPoint.x - gesture->pressPoint.x;
    CGFloat dy = viewPoint.y - gesture->pressPoint.y;
    if (hypot(dx, dy) > kSPDFLinkClickDragThreshold) gesture->draggedBeyondThreshold = YES;
    if (selectionNonEmpty) gesture->selectionCreated = YES;
}

BOOL spdf_link_click_gesture_activates_on_release(const SPDFLinkClickGesture* gesture) {
    if (!gesture || !gesture->active) return NO;
    return !gesture->draggedBeyondThreshold && !gesture->selectionCreated;
}
