#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacImageSave)
- (BOOL)saveActiveImageAs;
- (BOOL)waitForPendingImageSave:(void (^)(BOOL))completion;
- (void)saveImageTab:(SPDFDocumentTab*)tab completion:(void (^)(BOOL))completion;
- (void)completeImageSaveFromPath:(NSString*)source tab:(SPDFDocumentTab*)tab
                    destination:(NSString*)destination asPDF:(BOOL)asPDF;
@end
