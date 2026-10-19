#pragma once
#import <Cocoa/Cocoa.h>
// The command palette uses the approved reader's compact, single-line result grid.
CGFloat SPDFPaletteResultHeight(NSDictionary* result);
NSView* SPDFPaletteResultView(NSDictionary* result);
NSTableRowView* SPDFPaletteRowView(void);

NSView* SPDFPaletteContentView(NSSearchField* search, NSTableView* table, id target);
