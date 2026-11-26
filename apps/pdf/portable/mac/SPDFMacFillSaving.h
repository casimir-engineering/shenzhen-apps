#pragma once
// When Fill & Sign's and Annotate's changes to a PDF reach its file (SPDFMacFillSaving.mm).
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacFillSaving)
// After a change in the document in memory, already on screen: the file is saved once the changes rest (0.35 s after
// the last one, 1 s after the first at most), then these pages are drawn again at full quality.
- (void)fillScheduleSaveOfPages:(NSIndexSet*)pages;
// The save owed by the active document, written now with its redraw (before the document is left, an agent's request,
// a menu command). YES when it was written or nothing was owed.
- (BOOL)fillWritePendingSave;
// The file at `path` is about to be read (a page rendered on a worker, a search, an export): the owed save is written
// first, so what is read has the change; the redraw follows on the next pass. Returns `path`.
- (NSString*)fillPathAfterPendingSave:(NSString*)path;
// While Fill & Sign or Annotate shows on a PDF: the file's objects are read in short idle steps, so the first save
// doesn't stop to read them all.
- (void)fillPrepareSaveWhenIdle;
@end
