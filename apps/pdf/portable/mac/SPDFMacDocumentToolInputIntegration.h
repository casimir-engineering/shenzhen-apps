#pragma once
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacDocumentToolInput.h"

@interface ShenzhenMacDelegate (SPDFMacDocumentToolInput)
- (BOOL)beginImageOCRWithLanguage:(NSString*)language displayName:(NSString*)displayName;
- (BOOL)beginNativeDocumentTranslation;
@end
