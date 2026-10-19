#pragma once
#import "SPDFMacImageSaveIntegration.h"
@interface ShenzhenMacDelegate (SPDFMacUnsavedImageClose)
- (BOOL)deferClosingUnsavedImageAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)recent;
- (BOOL)deferUnsavedImageTermination;
- (BOOL)deferClosingImageTabs:(NSArray<SPDFDocumentTab*>*)tabs action:(void (^)(void))action;
- (void)approveClosingImageTabs:(NSArray<SPDFDocumentTab*>*)tabs completion:(void (^)(BOOL))completion;
- (NSModalResponse)promptToCloseUnsavedImage:(SPDFDocumentTab*)tab;
@end
