#pragma once
#import "SPDFMacDelegatePrivate.h"
// Optional main-thread publication gate, used only by reversible AI citations.
@interface ShenzhenMacDelegate (SPDFMacFindExecution)
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal
    publicationAllowed:(BOOL (^)(void))publicationAllowed;
// Stops the running PDF/EPUB/text search's workers.
- (void)cancelProgressiveFind;
@end
@interface ShenzhenMacDelegate (SPDFMacMarkdownFindPublication)
- (void)startMarkdownFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal
    publicationAllowed:(BOOL (^)(void))publicationAllowed;
- (void)startMarkdownFindForQuery:(NSString*)query preferredIndex:(NSInteger)index reveal:(BOOL)reveal
    publicationAllowed:(BOOL (^)(void))publicationAllowed;
@end
