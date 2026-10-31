#pragma once
#import "SPDFMacDelegatePrivate.h"
@class SPDFMacCollectionStore;
// Which documents the assistant's IDs and links can still open, for the chat and for the assistant itself.
//
// A doc: ID is the hash of the exact path the assistant read a document at (SPDFAIDocumentIdentifier). That path
// can stop being an open tab: a saved revision opened from History is read from an editable copy inside Collection,
// and its tab may later close or go back to the source. The file is still there, so a citation of it must still open
// it, and only a document that is really gone may stop being linked. SPDFMacAIDocumentIndex says which IDs open what.

// Collection rows a link may open (source available or a saved copy kept), each with `editablePaths`: its editable
// copies that exist. Reads the Collection manifest: never on the main thread.
NSArray<NSDictionary*>* SPDFMacAILinkableCollectionRows(SPDFMacCollectionStore* store);

@interface ShenzhenMacDelegate (SPDFMacAIDocumentAvailability)
// The assistant was given `identifier` for `path` (SPDFMacAITools records every one, for this window).
- (void)aiNoteDocumentIdentifier:(NSString*)identifier path:(NSString*)path;
// Recently opened files and the files the assistant was given IDs for; not yet checked for existence.
- (NSArray<NSString*>*)aiKnownDocumentPaths;
// The error a tool gives for a document ID that is not an open tab: closed (still opens from a citation) or gone.
- (NSString*)aiClosedDocumentMessage:(NSString*)identifier;
// `result` plus documentsNoLongerAvailable when documents the assistant was given IDs for have been deleted or moved
// since; each is reported once. nil when there is nothing to add.
- (NSDictionary*)aiResultNotingUnavailableDocuments:(NSDictionary*)result;
// Every document a doc: ID can open now, built off the main thread; completion on the main thread.
- (void)aiBuildDocumentIndex:(void (^)(NSDictionary<NSString*, NSDictionary*>* index))completion;
// For the chat while it draws answers: NO only for a doc: link whose document is known to be gone. Until the first
// index is built every link counts as available; `changed` runs when a rebuilt index differs, so answers redraw.
- (BOOL)aiDocumentLinkAvailable:(NSURL*)URL;
- (void)aiSetDocumentIndexChanged:(void (^)(void))changed;
// Documents were deleted for good: source cards drop their cached pages and links are checked again at once. IDs
// already given stay known, so the assistant hears these documents were deleted (aiResultNotingUnavailableDocuments).
- (void)aiDocumentsWereDeleted;
// The cited page's thumbnail for a source card, or nil (not a PDF or image, or not found). Main-thread completion.
- (void)aiSourceThumbnailForLink:(NSURL*)URL page:(NSInteger)page completion:(void (^)(NSImage* image))completion;
@end
