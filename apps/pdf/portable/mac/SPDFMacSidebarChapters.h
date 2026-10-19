#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// The chapter list's nesting: the disclosure triangles, the expand/collapse
// button beside the filter field, and the per-document memory of what is
// collapsed.
// The hierarchy itself is derived in SPDFMacSidebarOutline.{h,mm}; this half
// owns the AppKit side and where the state is kept.
@interface ShenzhenMacDelegate (SPDFMacSidebarChapters)

// The sidebar's row view. Owned here because the row now carries a disclosure
// triangle and an indent that tracks the heading's depth, neither of which the
// coordinator should have to know about.
- (NSTableCellView*)sidebarCellForTableView:(NSTableView*)tableView;
- (void)styleSidebarCell:(NSTableCellView*)cell item:(NSDictionary*)item;
- (NSString*)sidebarOutlineSummary;

// Hide the rows under a collapsed chapter, then reload. Replaces a bare
// -reloadData at the end of both sidebar builders.
- (void)applyChapterNestingAndReload;

// The one expand / collapse all button, on the filter field's row.
- (void)installChapterOutlineControls;
- (void)toggleAllChapters:(nullable id)sender;
- (void)expandAllChapters:(nullable id)sender;
- (void)collapseAllChapters:(nullable id)sender;

@end

// Implemented by the coordinator; declared here because it keeps them private
// to its own translation unit.
@interface ShenzhenMacDelegate (SPDFMacSidebarChaptersHost)
- (void)rebuildSidebar;
@end
