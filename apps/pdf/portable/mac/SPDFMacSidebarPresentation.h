#import <Cocoa/Cocoa.h>

// Pure view construction: no document reads, search work or persistent state.
NSTableRowView* SPDFSidebarRowView(void);
CGFloat SPDFSidebarFindRowHeight(NSDictionary* item);
NSTableCellView* SPDFSidebarFindCell(NSTableView* table, NSDictionary* item, NSArray<NSValue*>* matches);

// Returns YES only when geometry changed; callers can remeasure wrapped comments.
BOOL SPDFSidebarFitTableToViewport(NSTableView* table);
