#pragma once
#import "SPDFMacDelegatePrivate.h"

// The reader's side of SPDFMacCollectionPermanentDelete.h: the menu item, the questions, and the work, which closes
// the documents' tabs in this window and tells the other windows (each its own process) to close theirs.
@interface ShenzhenMacDelegate (SPDFMacPermanentDelete)
// "Remove from Disk and Collection…" at the end of a tab's or the page's menu, for the document at `path`.
- (void)addPermanentDeleteItemToMenu:(NSMenu*)menu path:(NSString*)path;
// The item's action: representedObject is the document's path (the selected tab's when there is none).
- (void)removeFromDiskAndCollection:(id)sender;
// After the person confirmed (here or in the Collection window): deletes the files, forgets them in Collection, then
// closes their tabs and forgets them everywhere else. `completion` (main thread) gets what was not deleted, for
// SPDFPermanentDeleteFailure; without one, this window shows it.
- (void)permanentlyDeletePaths:(NSArray<NSString*>*)paths documentIDs:(NSArray<NSString*>*)documentIDs
                    completion:(void (^)(NSArray<NSString*>* failures))completion;
// After the first paint, beside listenForDocumentsOpenedInOtherWindows.
- (void)listenForPermanentDeletesInOtherWindows;
@end
