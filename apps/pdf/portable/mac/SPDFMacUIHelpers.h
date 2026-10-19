#import <Cocoa/Cocoa.h>

#import "SPDFMacCursorRegions.h"

@class SPDFDocumentTab;

void spdf_activate_window_for_view(NSView* view);
void spdf_set_menu_item_system_symbol(NSMenuItem* item, NSString* symbolName);
void spdf_apply_system_icons_to_menu(NSMenu* menu);

// Lazily install / tear down the CGEventTap that captures out-of-focus trackpad
// pinch (magnify) gestures. The tap is placed at kCGHIDEventTap with
// kCGEventTapOptionDefault — the only combination that observes low-level
// trackpad gesture events system-wide — which is gated by ACCESSIBILITY (not
// Input Monitoring). The install call is cheap and idempotent; it is invoked
// only when the user opts in via the View menu, so there is no launch-time cost
// and no unsolicited permission prompt. If Accessibility is absent the tap does
// not arm and the feature stays inactive (logged under SPDF_ZOOM_PROFILE);
// the caller uses the result to guide the user to the right Settings pane.
// Teardown releases the CFMachPort / run-loop source at app termination.
typedef NS_ENUM(NSInteger, SPDFMagnifyTapResult) {
    SPDFMagnifyTapResultArmed,        // tap created and confirmed enabled (or already armed)
    SPDFMagnifyTapResultNoPermission, // create failed, Accessibility not granted -> guide the user
    SPDFMagnifyTapResultInert,        // tap created but reported disabled (rare; re-signed dev builds)
    SPDFMagnifyTapResultCreateFailed, // create failed despite trust, or source creation failed
};
SPDFMagnifyTapResult spdf_install_inactive_magnify_tap(void);
void spdf_teardown_inactive_magnify_tap(void);

// Silent check of whether the process currently has Accessibility trust (the
// grant the tap needs). Does not prompt. Used by the opt-in flow.
BOOL spdf_inactive_magnify_tap_authorized(void);

@protocol SPDFMacUIReader <NSObject>
- (BOOL)handlePresentationEvent:(NSEvent*)event;
- (BOOL)handleWindowArrangementShortcutEvent:(NSEvent*)event;
- (BOOL)handleTabStripMouseEvent:(NSEvent*)event;
- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)zoomWithMagnifyEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)zoomWithMagnifyDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint;
- (BOOL)scrollViewShouldTurnWheelIntoPageChange:(NSEvent*)event;
- (void)nextPage:(id)sender;
- (void)previousPage:(id)sender;
- (void)documentScrollPositionChanged;
- (NSInteger)documentViewCurrentPageIndex;
- (BOOL)documentArrowKeyDown:(NSEvent*)event;
- (void)stopKeyboardScrollAnimation;
- (BOOL)documentTypeToSearchKeyDown:(NSEvent*)event;
- (BOOL)documentEscapeKeyDown:(NSEvent*)event;
- (SPDFCursorRegionKind)documentViewCursorRegionAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
- (BOOL)documentViewOpenLinkAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex from:(NSPoint)start to:(NSPoint)end;
- (void)documentViewDidBeginPan;
- (void)documentViewDidFinishPanMotion;
// Scrolls to a hand-drag pan origin, applying the same horizontal centering as
// every other scroll path: a viewport-fit page stays centered (drag cannot push
// it off-center), a wider page pans freely.
- (void)documentViewPanToProposedOrigin:(NSPoint)origin;
- (BOOL)documentViewInPresentationMode;
- (NSArray<NSDictionary*>*)commentAnnotationsForPage:(NSInteger)pageIndex;
- (void)documentViewHoverComment:(NSDictionary*)comment atWindowPoint:(NSPoint)windowPoint;
- (void)documentViewEndHoverComment;
- (NSMenu*)contextMenuForDocumentView:(NSView*)view event:(NSEvent*)event;
- (void)showContextMenuForDocumentView:(NSView*)view event:(NSEvent*)event;
- (void)copySelection:(id)sender;
- (void)closePalette:(id)sender;
- (void)paletteMoveSelection:(NSInteger)delta;
- (void)activatePaletteSelection:(id)sender;
- (BOOL)openFilesFromPasteboard:(NSPasteboard*)pasteboard;
- (SPDFDocumentTab*)tabSnapshotForDragAtIndex:(NSInteger)index;
- (void)insertDraggedTab:(SPDFDocumentTab*)tab atIndex:(NSInteger)index;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)closeTabAtIndex:(NSInteger)index;
- (void)showTabInFolderAtIndex:(NSInteger)index;
- (void)copyTabFileToPasteboardAtIndex:(NSInteger)index;
- (void)copyTabPathToPasteboardAtIndex:(NSInteger)index;
- (void)copyTabTitleToPasteboardAtIndex:(NSInteger)index;
- (void)moveTabFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex;
- (void)detachTabAtIndex:(NSInteger)index;
- (void)newTabRequested:(id)sender;
- (void)clearFindFieldFocus;
- (void)sidebarDividerDraggedByDeltaX:(CGFloat)deltaX;
- (void)sidebarDividerDidFinishDragging;
- (void)minimapDividerDraggedByDeltaX:(CGFloat)deltaX;
- (void)minimapDividerDidFinishDragging;
- (void)minimapViewDidRequestViewportTopFraction:(CGFloat)yFraction;
- (void)minimapViewDidRequestViewportTopFraction:(CGFloat)yFraction documentCenterX:(CGFloat)documentCenterX;
- (void)minimapViewDidRequestViewportTopDocumentY:(CGFloat)documentTopY documentCenterX:(CGFloat)documentCenterX;
- (void)minimapViewDidFinishViewportDrag;
- (void)minimapViewDidRequestCenterAtDocumentPoint:(NSPoint)documentPoint;
- (void)minimapViewDidRequestCenterOnPage:(NSInteger)pageIndex
                          xFractionInPage:(CGFloat)xFraction
                          yFractionInPage:(CGFloat)yFraction;
- (void)minimapViewDidReceiveScrollWheel:(NSEvent*)event;
- (void)minimapViewDidReceiveZoomScrollWheel:(NSEvent*)event documentPoint:(NSPoint)documentPoint;
- (void)minimapViewDidReceiveMagnify:(NSEvent*)event documentPoint:(NSPoint)documentPoint;
- (void)minimapViewDidReceiveMagnifyDelta:(CGFloat)delta documentPoint:(NSPoint)documentPoint;
- (NSArray<NSDictionary*>*)findScrollbarMarkers;
- (NSNumber*)commentIndexForSidebarRow:(NSInteger)row;
- (void)editComment:(id)sender;
- (void)deleteComment:(id)sender;
@optional
- (BOOL)documentFindReturnKeyDown:(NSEvent*)event;
@end

@interface SPDFPaletteSearchField : NSSearchField
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@end

@interface SPDFFindSearchField : NSSearchField
@end

@interface SPDFToolbarStackView : NSStackView
@end

@interface SPDFToolbarDragView : NSView
@end

@interface SPDFToolbarDragLabel : NSTextField
+ (instancetype)labelWithString:(NSString*)stringValue;
@end

@interface SPDFToolbarToggleButton : NSButton
@property(nonatomic) BOOL active;
- (instancetype)initWithTitle:(NSString*)title target:(id)target action:(SEL)action;
@end

@interface SPDFToolbarMenuButton : NSButton
@end

@interface SPDFDropView : NSView <NSDraggingDestination>
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@end

// Painted gutter remains five points; the transparent hit target extends evenly
// into both neighboring panes and owns the identical cursor rectangle.
static const CGFloat SPDFPaneDividerHitWidth = 13;
@interface SPDFPaneDividerView : NSView
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
- (void)draggedByDeltaX:(CGFloat)delta;
- (void)didFinishDragging;
@end
@interface SPDFMinimapDividerView : SPDFPaneDividerView
@end
@interface SPDFSidebarDividerView : SPDFPaneDividerView
@end

@interface SPDFScrollView : NSScrollView
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@end

// Clip view for the document scroll view. When the horizontal lock range is
// finite the scroll origin's x is clamped to [horizontalLockMinX,
// horizontalLockMaxX]: min==max pins a viewport-fit page centered (no horizontal
// panning); min<max confines panning to a page wider than the viewport but
// narrower than the canvas (so you can't scroll off the page into empty canvas);
// NaN leaves horizontal scrolling free. The vertical lock is the same mechanism
// for the y axis: min==max pins a document that fits the viewport vertically
// (nothing to scroll, no elastic wiggle); NaN leaves vertical scrolling free.
// This is the AppKit-native clamp point — constrainBoundsRect: is consulted for
// every scroll, elastic bounce, and programmatic bounds change.
@interface SPDFDocumentClipView : NSClipView
@property(nonatomic) CGFloat horizontalLockMinX;
@property(nonatomic) CGFloat horizontalLockMaxX;
@property(nonatomic) CGFloat verticalLockMinY;
@property(nonatomic) CGFloat verticalLockMaxY;
@end

@interface SPDFWindow : NSWindow
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
- (void)handleChromeMouseDown:(NSEvent*)event;
@end

@interface SPDFShortcutHelpPanel : NSPanel
@end

@interface SPDFPresentationOverlayView : NSView
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@end

@interface SPDFSidebarTableView : NSTableView
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@end

@interface SPDFFindMarkerScroller : NSScroller
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@end
