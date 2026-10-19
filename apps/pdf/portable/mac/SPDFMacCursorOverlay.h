#pragma once
#import <Cocoa/Cocoa.h>

@protocol SPDFCursorOverlay <NSObject>
- (NSCursor*)spdf_cursorForTrackingOverlay;
@end

// Tracking areas under sibling overlays still receive exits and asynchronous
// cursor refreshes. Honor the topmost hit before the canvas paints its cursor.
static inline BOOL SPDFApplyCursorOverlay(NSView* canvas, NSPoint windowPoint) {
    NSView* content = canvas.window.contentView;
    if (!content) return NO;
    NSView* reference = content.superview ?: content;
    NSView* hit = [content hitTest:[reference convertPoint:windowPoint fromView:nil]];
    if (![hit respondsToSelector:@selector(spdf_cursorForTrackingOverlay)]) return NO;
    NSCursor* cursor = [(id<SPDFCursorOverlay>)hit spdf_cursorForTrackingOverlay];
    if (!cursor) return NO;
    [cursor set]; return YES;
}
