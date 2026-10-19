#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIReaderControls)
- (NSDictionary*)aiReaderControls;
// Only explicit operations below are accepted. Private before/after receipt
// dictionaries never leave the local action journal.
- (NSDictionary*)aiApplyReaderControl:(NSDictionary*)arguments progress:(NSProgress*)progress;
- (BOOL)aiUndoReaderControl:(NSDictionary*)receipt progress:(NSProgress*)progress;
@end
