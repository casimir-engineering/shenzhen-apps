#pragma once
// "Remove from Disk and Collection…" (the tab menu, the page's menu and the Collection list): the person's documents
// leave the Mac for good, with everything ShenzhenPDF kept about them. Shared by the reader and the Collection
// window's process; the reader does the work (SPDFMacPermanentDeleteIntegration.mm), because only it can close the
// documents' tabs first.
//
// Targets: what one request removes, as plist values so they can travel to other windows' processes.
//   documents      Collection rows (snapshots) whose entry, saved versions, editable History copies and previews go
//   files          files on disk deleted outright (never the Trash): each chosen tab's file outside the Collection,
//                  and each row's original while it is still that document's file (SPDFCollectionOriginalAvailable)
//   names          one display name per chosen document, for the confirmation
//   matchPaths     tabs at these paths close, in every window
//   matchPrefixes  and tabs inside these Collection folders (that document's History copies and saved versions)
//   documentIDs    and tabs that show these Collection documents
#import <Cocoa/Cocoa.h>
@class SPDFMacCollectionStore;

NS_ASSUME_NONNULL_BEGIN

// Why a file cannot be deleted, as the end of "“Datasheet.pdf” …", or nil when it can (or is already gone).
NSString* _Nullable SPDFPermanentDeleteBlockReason(NSString* path);
NSString* SPDFPermanentDeleteTitle(NSArray<NSString*>* names);
NSString* SPDFPermanentDeleteMessage(NSUInteger count);
// The confirmation: Delete Permanently on the right, Cancel the default, so Return cancels.
NSAlert* SPDFPermanentDeleteConfirmation(NSArray<NSString*>* names);
// Nil when every file can be deleted; otherwise the alert that says which cannot and that nothing was removed.
NSAlert* _Nullable SPDFPermanentDeleteRefusal(NSArray<NSString*>* files);
// After the work: what was not deleted (SPDFPermanentDeletePerform's failures) and that it stays where it was.
NSAlert* SPDFPermanentDeleteFailure(NSArray<NSString*>* failures);
// Refusal or confirmation as a sheet on `window`; `confirmed` runs only after Delete Permanently.
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
// Deletes the files, then forgets the Collection rows whose files went, then their cached thumbnails. A file that
// cannot be deleted keeps its row. Not on the main thread. Returns {removed: the targets' match keys for what went
// (documentIDs, matchPaths, matchPrefixes), failures: ["“Datasheet.pdf” is read-only", ...] for the person}.
NSDictionary* SPDFPermanentDeletePerform(NSDictionary* targets, SPDFMacCollectionStore* store,
                                         NSURL* _Nullable thumbnailDirectory);

NS_ASSUME_NONNULL_END
