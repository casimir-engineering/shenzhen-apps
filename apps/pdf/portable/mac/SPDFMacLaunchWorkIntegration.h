#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacLaunchWorkPolicy.h"

@interface ShenzhenMacDelegate (SPDFMacLaunchWorkIntegration)
- (void)spdf_scheduleIdleNearbyPageRendersForGeneration:(NSUInteger)generation preferredPage:(NSInteger)preferredPage;
- (void)spdf_scheduleIdlePostFirstPaintWorkForGeneration:(NSUInteger)generation
                                                    path:(NSString*)path
                                     savedFindMatchIndex:(NSInteger)savedFindMatchIndex
                                           restoreSearch:(BOOL)restoreSearch
                                     preferredRenderPage:(NSInteger)preferredRenderPage;
- (void)runLaunchWarmStage:(SPDFMacLaunchWarmStage)stage
                generation:(NSUInteger)generation
                   context:(NSDictionary*)context;
@end
