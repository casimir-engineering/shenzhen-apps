#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIDocumentActions)
- (NSDictionary*)aiCloseDocument:(NSString*)path progress:(NSProgress*)progress;
- (NSDictionary*)aiOpenCollectionDocumentAtPath:(NSString*)path archived:(BOOL)archived progress:(NSProgress*)progress;
- (NSDictionary*)aiRenameDocument:(NSDictionary*)arguments progress:(NSProgress*)progress;
- (BOOL)aiUndoDocumentAction:(NSDictionary*)receipt progress:(NSProgress*)progress;
@end
