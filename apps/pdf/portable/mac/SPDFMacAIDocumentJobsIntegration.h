#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIDocumentJobsIntegration)
- (void)aiRunDocumentJob:(NSString*)kind arguments:(NSDictionary*)arguments progress:(NSProgress*)progress
             completion:(void (^)(NSDictionary*))completion;
- (BOOL)aiUndoDocumentJob:(NSDictionary*)receipt progress:(NSProgress*)progress;
@end
