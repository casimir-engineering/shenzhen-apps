#pragma once
// "Move to Trash and Remove from Collection…" (the tab menu, the page's menu and the Collection list): the person's
// files go to the Trash, where the Finder can put them back, and everything ShenzhenPDF kept about them goes for good
// (Collection entry, History copies, Edited Copies, previews, indexes, viewing dates). Shared by the reader and the
// Collection window's process; the reader does the work (SPDFMacPermanentDeleteIntegration.mm), because only it can
// close the documents' tabs first.
//
// Targets: what one request removes, as plist values so they can travel to other windows' processes.
//   documents      Collection rows (snapshots) whose entry, saved versions, editable History copies and previews go
//   files          each chosen tab's file outside the Collection, and each row's original while it is still that
//                  document's file (SPDFCollectionOriginalAvailable): to the Trash, or unlinked when it is
//                  ShenzhenPDF's own copy (SPDFPermanentDeleteTrashes)
//   names          one display name per chosen document, for the confirmation
//   matchPaths     tabs at these paths close, in every window
//   matchPrefixes  and tabs inside these Collection folders (that document's History copies and saved versions)
//   documentIDs    and tabs that show these Collection documents
#import <Cocoa/Cocoa.h>
@class SPDFMacCollectionStore;

NS_ASSUME_NONNULL_BEGIN

// Why a file cannot be moved, as the end of "“Datasheet.pdf” …", or nil when it can (or is already gone). A volume
// without a Trash only shows when the move fails (SPDFPermanentDeleteFailure).
NSString* _Nullable SPDFPermanentDeleteBlockReason(NSString* path);
// NO for a file in ShenzhenPDF's own state folder (an Edited Copy): the app's copy, removed rather than trashed.
BOOL SPDFPermanentDeleteTrashes(NSString* file);
// `trashed`: how many of the files go to the Trash; none (only Collection entries go) changes the wording.
NSString* SPDFPermanentDeleteTitle(NSArray<NSString*>* names, NSUInteger trashed);
NSString* SPDFPermanentDeleteMessage(NSUInteger count, NSUInteger trashed);
// The confirmation: Move to Trash on the right, Cancel the default, so Return cancels.
NSAlert* SPDFPermanentDeleteConfirmation(NSArray<NSString*>* names, NSArray<NSString*>* files);
// Nil when every file can be moved; otherwise the alert that says which cannot and that nothing was removed.
NSAlert* _Nullable SPDFPermanentDeleteRefusal(NSArray<NSString*>* files);
// After the work: what was not removed (SPDFPermanentDeletePerform's failures) and that it stays where it was.
NSAlert* SPDFPermanentDeleteFailure(NSArray<NSString*>* failures);
// Refusal or confirmation as a sheet on `window`; `confirmed` runs only after Move to Trash.
void SPDFPermanentDeleteAsk(NSWindow* window, NSArray<NSString*>* names, NSArray<NSString*>* files,
                            void (^confirmed)(void));

// Paths: chosen tabs' files (a source, an Edited Copy, a History copy or a saved version inside the Collection).
// documentIDs: Collection rows chosen in the Collection window. Reads the Collection index, never creates it.
NSDictionary* SPDFPermanentDeleteTargets(SPDFMacCollectionStore* store, NSArray<NSString*>* paths,
                                         NSArray<NSString*>* documentIDs);
BOOL SPDFPermanentDeleteMatchesTab(NSDictionary* targets, NSString* _Nullable path,
                                   NSString* _Nullable collectionDocumentID);
// The Collection list's cached page pictures of `document` (SPDFCollectionThumbnailDiskKey) as file names in the
// thumbnail folder, for every page up to `pages` at 1x-3x; the original's only while it is still there.
NSSet<NSString*>* SPDFPermanentDeleteThumbnailNames(NSDictionary* document, NSInteger pages);
// Moves the files to the Trash, then forgets the Collection rows whose files went, then their cached thumbnails. A
// file that cannot be moved keeps its row. Not on the main thread. Returns {removed: the targets' match keys for what went
// (documentIDs, matchPaths, matchPrefixes), failures: ["“Datasheet.pdf” is read-only", ...] for the person}.
NSDictionary* SPDFPermanentDeletePerform(NSDictionary* targets, SPDFMacCollectionStore* store,
                                         NSURL* _Nullable thumbnailDirectory);

NS_ASSUME_NONNULL_END
