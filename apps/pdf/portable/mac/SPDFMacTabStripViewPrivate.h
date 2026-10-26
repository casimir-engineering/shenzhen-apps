#import "SPDFMacTabStripView.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacTabStripGeometry.h"
#import "SPDFMacTabStripStyle.h"

static const CGFloat kTabGap = 4.0;
static const CGFloat kTabMinVisibleWidth = 96.0;
static const CGFloat kTabMaxWidth = 200.0;
static const CGFloat kTabControlWidth = 32.0;
// Read-only indicator dot. Shared by the draw and tooltip-rect sites so the
// hover hit-area stays aligned with the drawn dot if either is tweaked.
static const CGFloat kReadOnlyDotDiameter = 7.0;
// 50% less horizontal space around the read-only dot than before (was 12 / 5).
static const CGFloat kReadOnlyDotLeftInset = 6.0;
static const CGFloat kReadOnlyDotTitleGap = 2.5;
// Upper bound on simultaneously visible tabs, for stack-allocated geometry
// arrays. Visible tabs are >= kTabMinVisibleWidth wide, so even a 5K-wide
// strip shows far fewer than this.
static const NSInteger kMaxVisibleTabGeometry = 64;
static NSPasteboardType const SPDFTabDragPasteboardType = @"com.intuition.shenzhenpdf.tab";

@interface SPDFTabStripView () {
    NSTrackingArea* _trackingArea;
    NSPanel* _hoverPanel;
    NSPopover* _groupPicker;
    NSTextField* _hoverLabel;
    NSVisualEffectView* _hoverBubble;
    // The page thumbnail under a document tab's title; built on first use.
    NSVisualEffectView* _hoverCard;
    NSView* _hoverThumbnail;
    NSInteger _hoverTabIndex;
    // The group whose title tab shows the hover label; nil while a document's
    // label (or none) is shown.
    SPDFTabGroup* _hoverGroup;
    NSInteger _draggedTabIndex;
    NSInteger _dragSessionTabIndex;
    NSPoint _dragStartPoint;
    BOOL _draggingTab;
    BOOL _detachedTabDrag;
    BOOL _mouseDownInsideTab;
    NSInteger _dragSourceTabIndex;
    NSInteger _dragTargetTabIndex;
    CGFloat _dragPointerOffsetX;
    CGFloat _dragCurrentX;
    NSPoint _lastHoverPoint;
    BOOL _hasLastHoverPoint;
    BOOL _suppressingWindowMovementForTabGesture;
    BOOL _previousWindowMovableForTabGesture;
    NSInteger _middleClickTabIndex;
    NSString* _middleClickTabPath;
    // Insertion slot (see SPDFMacTabStripGeometry.h) for the yellow drop
    // indicator shown while a detached tab hovers over this strip; -1 hidden.
    NSInteger _dropIndicatorSlot;
    // Set by -performDragOperation: when a drop from this strip's own dragging
    // session was handled as an in-process move (continuous same-window
    // gesture), so the source-side session-ended callback neither closes nor
    // detaches the tab.
    BOOL _sameWindowTabDropHandled;
    SPDFTabGroup* _pressedGroup;
    SPDFTabGroup* _dragSessionGroup;
    NSInteger _groupDropTabIndex;
    CGFloat _groupDropBoundaryX;
    SPDFTabGroup* _groupDropGroup;
    NSString* _groupPreviewColor;
    NSTimeInterval _groupHoverBegan;
    NSInteger _groupHoverIndex;
    NSArray<NSString*>* _displayTitles;
    NSMutableDictionary<NSNumber*,NSNumber*>* _preferredTabWidths;
    NSArray<NSNumber*>* _ungroupedVisibleIndexes;
    CGFloat _ungroupedLayoutWidth;
    CGFloat _tabScrollOffset;
    CGFloat _tabContentWidth;
    NSRect _tabPinnedViewport;
    BOOL _revealSelectedTab;
    SPDFTabGroup* _pressedGroupAction;
    id _groupLayout;
    NSRect _groupLayoutBounds;
    CGFloat _groupLayoutInset;
    NSArray<NSAccessibilityElement*>* _accessibilityChildrenSnapshot;
}
@end

@interface SPDFTabStripView (Internal)
- (instancetype)initWithFrame:(NSRect)frameRect;
- (void)dealloc;
- (void)viewWillMoveToWindow:(NSWindow*)newWindow;
- (BOOL)acceptsFirstMouse:(NSEvent*)event;
- (BOOL)mouseDownCanMoveWindow;
- (void)suppressWindowMovementForTabGesture;
- (void)restoreWindowMovementForTabGesture;
- (void)setHidden:(BOOL)hidden;
- (CGFloat)tabWidth;
- (CGFloat)preferredWidthForTabAtIndex:(NSInteger)index;
- (NSString*)fullTitleForTabAtIndex:(NSInteger)index;
- (CGFloat)leftInset;
- (NSRect)plusRect;
- (NSRect)overflowRectAssumingVisible;
- (CGFloat)tabAreaRightWithOverflow:(BOOL)overflow;
- (CGFloat)tabAreaWidthWithOverflow:(BOOL)overflow;
- (NSInteger)selectedIndexForLayout;
- (NSInteger)visibleTabCapacityWithOverflow:(BOOL)overflow;
- (BOOL)hasOverflowTabs;
- (NSArray<NSNumber*>*)visibleTabIndexes;
- (NSArray<NSNumber*>*)hiddenTabIndexes;
- (NSRect)overflowRect;
- (NSRect)rectForTabAtIndex:(NSInteger)index;
- (NSRect)interactionRectForTabRect:(NSRect)tabRect;
- (NSInteger)tabIndexAtPoint:(NSPoint)point;
- (NSString*)titleForTabAtIndex:(NSInteger)index;
- (void)updateTrackingAreas;
- (void)rebuildReadOnlyTooltips;
- (NSString*)view:(NSView*)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void*)userData;
- (void)dismissHoverPanel;
- (void)updateHoverForPoint:(NSPoint)point;
- (void)showHoverPanelForTabAtIndex:(NSInteger)index;
- (void)showHoverPanelForGroup:(SPDFTabGroup*)group;
- (BOOL)showHoverPanelWithTitle:(NSString*)title belowRect:(NSRect)rect;
- (BOOL)showHoverPanelWithTitle:(NSString*)title belowRect:(NSRect)rect
                        preview:(id)preview fadeIn:(BOOL)fadeIn;
- (void)hoverPreviewReady:(id)preview forTab:(SPDFDocumentTab*)tab;
- (void)updateHoverForEvent:(NSEvent*)event;
- (void)setTabs:(NSArray<SPDFDocumentTab*>*)tabs;
- (void)setSelectedIndex:(NSInteger)selectedIndex;
- (NSRect)closeCircleRectForTabRect:(NSRect)tabRect;
- (NSRect)readOnlyDotRectForTabRect:(NSRect)tabRect diameter:(CGFloat)diameter leftInset:(CGFloat)leftInset;
- (void)beginTabTrackingAtIndex:(NSInteger)index point:(NSPoint)point tabRect:(NSRect)tabRect;
- (void)resetTabDragTracking;
- (NSInteger)dragDestinationIndexForPoint:(NSPoint)point;
- (NSInteger)collectVisibleTabGeometryMinXs:(CGFloat*)minXs
                                      midXs:(CGFloat*)midXs
                                      maxXs:(CGFloat*)maxXs
                               arrayIndexes:(NSInteger*)arrayIndexes;
- (NSInteger)dropIndexForPoint:(NSPoint)point;
- (void)updateDropIndicatorForPoint:(NSPoint)point;
- (void)clearDropIndicator;
- (BOOL)containsTabOrControlAtPoint:(NSPoint)point;
- (BOOL)isVisuallyReorderingTabs;
- (NSRect)visualRectForTabAtIndex:(NSInteger)index;
- (void)drawTabAtIndex:(NSInteger)index
                inRect:(NSRect)tabRect
            attributes:(NSDictionary*)attrs
         dimAttributes:(NSDictionary*)dimAttrs;
- (void)drawRect:(NSRect)dirtyRect;
- (NSView*)groupPickerContentView;
- (void)showGroupPicker;
- (void)showGroupDocuments:(SPDFTabGroup*)group event:(NSEvent*)event;
- (void)showOverflowMenuWithEvent:(NSEvent*)event;
- (void)showOverflowMenuForAccessibility;
- (void)showContextMenuForTabAtIndex:(NSInteger)index;
- (void)showContextMenuForGroup:(SPDFTabGroup*)group;
- (NSMenu*)newTabOrGroupMenu;
- (void)showNewTabOrGroupMenu;
- (NSMenu*)overflowMenu;
- (void)browseGroupFromMenu:(NSMenuItem*)sender;
- (void)overflowTabMenuItemSelected:(NSMenuItem*)sender;
- (void)tabContextShowInFolder:(NSMenuItem*)sender;
- (void)tabContextCopyFile:(NSMenuItem*)sender;
- (void)tabContextCopyPath:(NSMenuItem*)sender;
- (void)tabContextCopyTitle:(NSMenuItem*)sender;
- (void)startTabDragSessionWithEvent:(NSEvent*)event;
- (NSDragOperation)draggingSession:(NSDraggingSession*)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context;
- (BOOL)tabDragSessionEndedByCancellation;
- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation;
- (BOOL)isSameWindowTabDragFromSender:(id<NSDraggingInfo>)sender;
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender;
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender;
- (void)draggingExited:(id<NSDraggingInfo>)sender;
- (void)draggingEnded:(id<NSDraggingInfo>)sender;
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender;
- (void)mouseDown:(NSEvent*)event;
- (void)rightMouseDown:(NSEvent*)event;
- (void)mouseDragged:(NSEvent*)event;
- (void)mouseUp:(NSEvent*)event;
- (void)otherMouseDown:(NSEvent*)event;
- (void)otherMouseUp:(NSEvent*)event;
- (void)mouseMoved:(NSEvent*)event;
- (void)mouseEntered:(NSEvent*)event;
- (void)mouseExited:(NSEvent*)event;
- (void)keyDown:(NSEvent*)event;
+ (BOOL)claimFocusOnDocumentKeyView:(NSView*)documentKeyView
                             window:(NSWindow*)window
                           tabStrip:(NSView*)tabStrip
                   parkedResponders:(NSArray<NSResponder*>*)parkedResponders;
- (id<SPDFTabGroupReader>)groupReader;
- (NSMenu*)contextMenuForGroup:(SPDFTabGroup*)group;
- (BOOL)newGroupGoesBeforeTargetAtIndex:(NSInteger)index;
- (NSRect)tabViewportRect;
- (NSRect)tabScrollIndicatorRectOnLeft:(BOOL)left;
- (NSInteger)tabScrollHiddenCountOnLeft:(BOOL)left;
- (void)scrollTabStripBy:(CGFloat)delta;
- (BOOL)handleTabScrollMouseDown:(NSEvent*)event;
- (BOOL)isPointOnHiddenTabsIndicator:(NSPoint)point;
- (NSMenu*)hiddenTabsMenuOnLeft:(BOOL)left;
- (void)showHiddenTabsOnLeft:(BOOL)left;
- (void)fadeTabScrollEdges;
- (NSRect)groupHideRect:(NSRect)header;
- (BOOL)hasTabGroups;
- (NSArray<SPDFTabGroup*>*)orderedTabGroups;
- (NSArray*)groupLayouts;
- (NSInteger)groupInsertionIndexForPoint:(NSPoint)point;
- (CGFloat)groupInsertionBoundaryForPoint:(NSPoint)point;
- (NSInteger)tabGroupGapInsertionIndexForPoint:(NSPoint)point boundary:(CGFloat*)boundary;
- (SPDFTabGroup*)tabDropGroupAtPoint:(NSPoint)point;
- (NSRect)groupedRectForTabAtIndex:(NSInteger)index;
- (NSArray<NSNumber*>*)groupedVisibleTabIndexes;
- (BOOL)groupedHasOverflow;
- (SPDFTabGroup*)groupAtPoint:(NSPoint)point headerOnly:(BOOL)headerOnly;
- (BOOL)handleGroupMouseDown:(NSEvent*)event;
- (BOOL)handleGroupMouseDragged:(NSEvent*)event;
- (BOOL)handleGroupMouseUp:(NSEvent*)event;
- (BOOL)handleGroupRightMouseDown:(NSEvent*)event;
- (void)drawTabGroups;
- (void)drawGroupDropPreview;
- (void)updateGroupDropForPoint:(NSPoint)point sourceIndex:(NSInteger)source;
- (BOOL)performGroupDropWithTab:(SPDFDocumentTab*)tab sourceIndex:(NSInteger)source atPoint:(NSPoint)point;
- (void)tabContextNewGroup:(NSMenuItem*)sender;
- (void)createNamedGroupForTabAtIndex:(NSInteger)index withTabAtIndex:(NSInteger)other color:(NSString*)color beforeTargetGroup:(BOOL)before;
- (void)promptForGroup:(SPDFTabGroup*)group creating:(BOOL)creating;
- (NSMenu*)moveToGroupMenuForTabAtIndex:(NSInteger)index;
- (void)tabContextMoveToGroup:(NSMenuItem*)sender;
- (void)startGroupDragSessionWithEvent:(NSEvent*)event;
@end
