#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIDocumentActions)
- (NSDictionary*)aiCloseDocument:(NSString*)path progress:(NSProgress*)progress;
// Many tabs at once, with one receipt ("close-many") whose Undo puts every one back in its group and position. Tabs
// holding an unsaved pasted image stay open and are listed as kept.
- (NSDictionary*)aiCloseDocuments:(NSArray<NSString*>*)paths progress:(NSProgress*)progress;
- (NSDictionary*)aiOpenCollectionDocumentAtPath:(NSString*)path archived:(BOOL)archived progress:(NSProgress*)progress;
// rename_document: renames the file when it can be (and target isn't "title"); otherwise the document keeps its
// file name and shows the new name in ShenzhenPDF (SPDFDocumentTab.displayName, kept in Collection), and the result
// says so (fileRenamed NO, tellThePerson). Undo restores the previous name while it is unchanged.
- (NSDictionary*)aiRenameDocument:(NSDictionary*)arguments progress:(NSProgress*)progress;
- (BOOL)aiUndoDocumentAction:(NSDictionary*)receipt progress:(NSProgress*)progress;
@end
// close_document's `paths`: document IDs replaced by the open documents' paths in `arguments`, using `known` (ID ->
// path). Returns the refusal to give the assistant, or nil.
NSDictionary* SPDFAIMapDocumentIDs(NSMutableDictionary* arguments, NSDictionary<NSString*, NSString*>* known);
// The name rename_document shows for a document whose file keeps its name: trimmed, without the file's own
// extension, one line of at most 240 characters; nil when there is no such name.
NSString* SPDFAIDisplayNameForRename(NSString* path, NSString* proposed);
