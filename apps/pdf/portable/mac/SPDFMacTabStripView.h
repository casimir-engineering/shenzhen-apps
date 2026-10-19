#import <Cocoa/Cocoa.h>

#import "SPDFMacModels.h"
#import "SPDFMacUIHelpers.h"

@interface SPDFTabStripView : NSView <NSDraggingSource, NSDraggingDestination>
@property(nonatomic, weak) id<SPDFMacUIReader> reader;
@property(nonatomic, copy) NSArray<SPDFDocumentTab*>* tabs;
@property(nonatomic, copy) NSArray<SPDFTabGroup*>* emptyGroups;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic) CGFloat reservedLeadingInset;
@property(nonatomic) CGFloat tabScrollOffset;
@property(nonatomic, copy) void (^tabScrollDidChange)(CGFloat);
- (BOOL)containsTabOrControlAtPoint:(NSPoint)point;
// Tab-activation focus claim, shared by the reader's selection chokepoint:
// moves keyboard focus to documentKeyView so typing right after a tab
// selection searches the document — but only when the current first responder
// is a passive holder (nil, the window itself, the strip, or one of
// parkedResponders, the views the tab-switch machinery itself parks focus on).
// A responder the user focused deliberately — the find, page, or
// sidebar-filter field's editor, the sidebar — is never robbed. Returns YES
// when documentKeyView took first responder.
+ (BOOL)claimFocusOnDocumentKeyView:(NSView*)documentKeyView
                             window:(NSWindow*)window
                           tabStrip:(NSView*)tabStrip
                   parkedResponders:(NSArray<NSResponder*>*)parkedResponders;
@end

@interface SPDFTabStripView (Hover)
- (void)dismissHoverPanel;
@end

@interface SPDFTabStripView (PickerDismissal)
- (BOOL)dismissGroupPickerIfShown;
@end

@interface SPDFTabStripView (GroupCreation)
- (void)revealTabGroup:(SPDFTabGroup*)group;
- (void)promptForGroup:(SPDFTabGroup*)group creating:(BOOL)creating;
@end
