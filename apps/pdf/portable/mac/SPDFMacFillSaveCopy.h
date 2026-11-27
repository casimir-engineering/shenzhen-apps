#pragma once
// When the save Fill & Sign and Annotate owe a PDF (SPDFMacFillSaving.mm) can't go into its file, the changes are kept
// in a copy in the app's own storage, the person is told, and the copy is what they go on with (SPDFMacFillSaveCopy.mm).
#import "SPDFMacDelegatePrivate.h"

#include "shenzhen_pdf_core.h"

// Installs the core's hook for a save that still fails when its document closes (once; idempotent).
void SPDFFillSaveCopyInstall(void);
// Whether `path` is a copy made because another app changed the original while it was being annotated.
BOOL SPDFFillIsCopyOfChangedFile(NSString* path);

@interface ShenzhenMacDelegate (SPDFMacFillSaveCopy)
// The active document's file changed since it was read: its changes are written to a copy, the tab follows the copy
// and the person is told (on the next main-queue pass). NO when no copy could be made (told too; still owed).
- (BOOL)fillKeepChangesOfChangedFile:(spdf_document*)doc;
@end
