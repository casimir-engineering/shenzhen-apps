#pragma once
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacOtherAppFiles.h"

// Documents from another app's folder are read from ShenzhenPDF's own copy (SPDFMacOtherAppFilesIntegration.mm).
@interface ShenzhenMacDelegate (SPDFMacOtherAppFiles)
// The paths to open in place of documents handed over from another app's folder: their copies, made now.
- (NSArray<NSString*>*)otherAppReaderPathsForPaths:(NSArray<NSString*>*)paths;
// Moves a tab that points into another app's folder to the copy, touching nothing there. Returns the tab.
- (SPDFDocumentTab*)otherAppMigrateTab:(SPDFDocumentTab*)tab;
// For -loadSelectedTab: YES when the tab shows a message (the copy is being made, or cannot be) instead of a document.
- (BOOL)otherAppShowsMessageForSelectedTab:(SPDFDocumentTab*)tab;
@end
