#pragma once
#import <Cocoa/Cocoa.h>

@protocol SPDFCursorOverlay <NSObject>
@optional
- (NSCursor*)spdf_cursorForTrackingOverlay;
// The cursor at this point (window coordinates), for an overlay whose cursor depends on what is under the pointer.
- (NSCursor*)spdf_cursorForTrackingOverlayAt:(NSPoint)windowPoint;
@end

// Tracking areas under sibling overlays still receive exits and asynchronous
// cursor refreshes. Honor the topmost hit before the canvas paints its cursor.
static inline BOOL SPDFApplyCursorOverlay(NSView* canvas, NSPoint windowPoint) {
    NSView* content = canvas.window.contentView;
    if (!content) return NO;
    NSView* reference = content.superview ?: content;
    NSView* hit = [content hitTest:[reference convertPoint:windowPoint fromView:nil]];
    NSCursor* cursor = nil;
    if ([hit respondsToSelector:@selector(spdf_cursorForTrackingOverlayAt:)])
        cursor = [(id<SPDFCursorOverlay>)hit spdf_cursorForTrackingOverlayAt:windowPoint];
    else if ([hit respondsToSelector:@selector(spdf_cursorForTrackingOverlay)])
        cursor = [(id<SPDFCursorOverlay>)hit spdf_cursorForTrackingOverlay];
    if (!cursor) return NO;
    [cursor set]; return YES;
}
