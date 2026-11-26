#pragma once
// A change to a PDF page shows in the next frame, before the file is saved (SPDFMacFillShowFirst.mm).
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacFillShowFirst)
// Before the save: the changed pages in view drawn again from the document in memory (the part in view only when the
// whole page would cost much more).
// areas: a page's changed part (page points, top-left origin), drawn into the picture already shown, when it has one.
- (void)fillRedrawFromMemoryPages:(NSIndexSet*)pages areas:(NSDictionary<NSNumber*, NSValue*>*)areas;
// The window drawn and handed to the screen now, before the save.
- (void)fillCommitDisplay;
// For the save's redraw: the page was drawn whole, or only its part in view, from memory since the last save.
- (BOOL)fillPageShownWhole:(NSUInteger)index;
- (BOOL)fillPageShownInView:(NSUInteger)index;
- (void)fillForgetShownPages:(NSIndexSet*)pages;  // nil: every page
@end
