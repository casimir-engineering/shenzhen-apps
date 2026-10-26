#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIDocumentActions)
- (NSDictionary*)aiCloseDocument:(NSString*)path progress:(NSProgress*)progress;
// Many tabs at once, with one receipt ("close-many") whose Undo puts every one back in its group and position. Tabs
// holding an unsaved pasted image stay open and are listed as kept.
- (NSDictionary*)aiCloseDocuments:(NSArray<NSString*>*)paths progress:(NSProgress*)progress;
- (NSDictionary*)aiOpenCollectionDocumentAtPath:(NSString*)path archived:(BOOL)archived progress:(NSProgress*)progress;
- (NSDictionary*)aiRenameDocument:(NSDictionary*)arguments progress:(NSProgress*)progress;
- (BOOL)aiUndoDocumentAction:(NSDictionary*)receipt progress:(NSProgress*)progress;
@end
// close_document's `paths`: document IDs replaced by the open documents' paths in `arguments`, using `known` (ID ->
// path). Returns the refusal to give the assistant, or nil.
NSDictionary* SPDFAIMapDocumentIDs(NSMutableDictionary* arguments, NSDictionary<NSString*, NSString*>* known);
