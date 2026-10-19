#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (AIMetadataActions)
- (void)aiUpdateMetadata:(NSDictionary*)arguments progress:(NSProgress*)progress completion:(void (^)(NSDictionary*))completion;
- (void)aiSwapMetadataReceipt:(NSDictionary*)receipt progress:(NSProgress*)progress completion:(void (^)(NSDictionary*))completion;
- (void)aiPublishUpdatedMetadata:(NSDictionary*)analysis path:(NSString*)path;
@end
